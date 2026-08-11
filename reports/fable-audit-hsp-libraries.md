# Fable audit — HSP libraries batch (2026-06-18)

Combined static audit of five small HSP-owned npm packages. Playbook steps
0–2 + 6–7 only; steps 3–5 (Datadog/AWS/cost) are **N/A for npm libraries**
(no deployed service, no Datadog presence, no AWS footprint) and skipped with
this note. Per the task brief, each library additionally gets a **consumer
reality check**, **API surface drift**, and **publish health** pass.

Targets (all under `/Users/balazsgabor/Documents/workspace/kasa/`):
`code-api-types`, `file-utils`, `lambda-utils`, `url-shortener-api-client`,
`css-debugger`.

---

## TL;DR

Two of these are genuinely load-bearing for the lock cluster
(`code-api-types`: 13 consumers; `lambda-utils`: live `processSQSRecords`
path used across sync workers), one has a real consumer-facing dormant bug
(`file-utils`), and two are candidates for the chopping block
(`url-shortener-api-client`: **zero consumers anywhere**;
`css-debugger`: a one-bus-factor internal tool that ships a physical
door-unlock method and gates real lock-job mutations only in the UI).

**Single most important finding:** `file-utils`'
`MicrosoftGraphMongoCredentialStore` writes its token cache to the wrong
Mongo shape (`$set: { token, expiresAt }` at top level) while reading it back
from `doc.data.*` — and the consumer `Setting` schema only defines
`{ project, data }`, so Mongoose strict mode **silently strips the write**.
The DB token cache is a no-op in prod (guest-api CAA generation +
financial-service invoices); only the per-process in-memory cache works, so
every Lambda cold start re-requests a Microsoft Graph token. Consumers
already half-noticed (`as unknown as` cast + "typing is incorrect in file
utils" comment).

**Runner-up (security):** `css-debugger` ships `SmartthingsSyncApiClient.unlock()`
(a real physical door unlock) and gates `runJob`/`cancelJob` lock mutations
with a render-only `Can` component — both depend entirely on server-side
authz to be safe. `runJob` is the same surface implicated in the 2026-06-01
mass-delete incident.

No committed secrets and no evidence of active compromise in any of the five.
No cloud cost to estimate (libraries).

---

## Scope & method (preflight — Step 0)

`git fetch` failed for all five repos in the scheduled run (no SSH/credential
agent available) — tolerated per playbook; audited **local** working state,
so `origin/*` comparisons below are against possibly-stale local refs.

| Repo | Branch audited | HEAD | Commit date | Clean? | Notes |
|---|---|---|---|---|---|
| code-api-types | `fix/HSP-3710-seam-codeId-resolve` | 6f612a4 | 2026-05-27 | clean | 3 commits ahead of local `origin/master`; delta = 1 added field (`codeId` on Seam union) + CHANGELOG. Audited in place; effectively master+1. |
| file-utils | `master` | d23cc76 | 2026-02-16 | `.DS_Store` only | in place |
| lambda-utils | `master` | 7d6a57c | 2025-10-30 | clean | in place; last touched 7+ months ago |
| url-shortener-api-client | `master` | 3de2e79 | 2025-11-03 | clean | in place |
| css-debugger | `master` | 2703adb | 2026-05-27 | clean working tree | 4 commits ahead of local `origin/master`; audited in place, noted |

No worktrees created (deltas from master were trivial or local-only and the
checkouts were clean). No branch switches, pulls, or stashes — user checkouts
untouched.

Static dimensions (Step 2) run as a mix of inline reads (the four small libs)
and two parallel verification subagents (css-debugger full audit;
code-api-types drift vs css-api + code-setting-service). Bug/security findings
were re-checked against the actual code before shipping.

---

## Cross-library summary

| Library | npm name | Ver | Workspace consumers | Verdict |
|---|---|---|---|---|
| code-api-types | `@kasadev/code-api-types` | 7.11.0 | **13** (css-api/client, code-setting-service, device-service, guest-api, kontrol, kasa-mcp, remotelock-sync, smartthings-sync, salto-sync, salto-device-event-listener, callbox-automation, sensor-service, portfolio-manager-service/client) | Keep; reconcile drift |
| file-utils | `@kasadev/file-utils` | 5.2.0 | 3 (guest-api, financial-service, financial-api/service) | Keep; fix Mongo store bug |
| lambda-utils | `@kasadev/lambda-utils` | 1.1.1 | ~11 via `processSQSRecords` (segment-sync, automessages, breezeway-sync, code-setting-service, price-api, remotelock-sync, smartthings-sync, sensor-service, kustomer-sync, reservation-risk-service, kasa-website-controller) | Keep; drop dead deprecated fn; dedupe vs `@kasadev/utils` |
| url-shortener-api-client | `@kasadev/url-shortener-api-client` | 1.0.2 | **0** | Archive or justify |
| css-debugger | `css-debugger` (private) | 1.0.0 | n/a (app, not a lib) | Keep; harden mutations/secrets posture |

---

## 1. code-api-types — `@kasadev/code-api-types` v7.11.0

**Role.** Pure type-definitions package for the lock-code ("CSS" / Code
Setting Service) API cluster. `src/types.ts` re-exports `src/apis/*.ts`
(codeSettingService, smartthingsSync, remotelockSync, deviceService,
callboxAutomation, riskScoreService, salto) + `common.ts`. Ships compiled
`dist`; build is plain `tsc`.

**Consumer reality check.** Load-bearing — 13 workspace consumers (see table).
This is the type backbone for the lock cluster; treat changes as
contract-breaking.

**Findings (verified against both type def and consumer):**

| # | Sev | Area | Finding | Evidence | Recommendation |
|---|---|---|---|---|---|
| C1 | **high** | Error-code drift | Modern **css-api returns different numeric error codes than the published type declares**, and never imports `CssErrorCodes`. `GetCssCodesCommandResponse` declares access-not-found as `ACCESS_NOT_FOUND = 103001` (legacy code-setting-service honors it), but css-api returns **`104003`** for the same condition and invents a parallel 103101–106 / 103200–208 / 104xxx space absent from the enum. The published response unions no longer describe css-api's actual responses. | type `code-api-types/src/apis/codeSettingServiceApi.ts:13,63`; legacy match `code-setting-service/functions/api/getCodes.ts:92,102`; css-api drift `css-api/service/src/infra/errors.ts:85-188` | Reconcile css-api's `infra/errors.ts` back onto `CssErrorCodes`, OR stop advertising these response unions as the css-api contract and version the type to reflect the codes css-api actually emits. Root cause: two services, two independent error-code registries, one shared published type. |
| C2 | **high** | Command shape drift | **`ResolveDeviceDetailsCommandSeam` is missing `accessGrantId`** that css-api actively reads — so css-api's client monkey-patches the published type with a local `AddSeamExtras<T>` wrapper to bolt it on. Classic "published type is stale" smell. | type `codeSettingServiceApi.ts:122-128` (no `accessGrantId`); consumer reads `css-api/service/src/processes/app/router/devices/devices.controller.ts:53-58`, validator `devices.validators.ts:20`; patch `css-api/client/src/types/GetDeviceDetailsRequest.ts:3-5` | Add `accessGrantId?: string` to the Seam member and publish; drop `AddSeamExtras` in css-api-client (and the redundant `codeId` it re-adds). |
| C3 | med | Dead surface | **Entire `riskScoreService.ts` API is unused** by every workspace consumer (8 exported symbols, 0 external refs — the real risk-score path lives in `reservation-risk-service`/`sns-events`, which don't import this package). Self-collision: `INTERNAL_SERVER_ERROR` and `NOT_FOUND` are **both `106002`**. | `code-api-types/src/apis/riskScoreService.ts:4-7,12-36` | Delete `riskScoreService.ts` from the package (and its `types.ts:6` re-export). If kept, fix the duplicate `106002`. |
| C4 | med | Name/type mismatch | **`CodeProperties.seamDeviceLocation?: SeamDeviceType[]`** — name says "location", type is a device *type*. Confirmed real: the source `unit.seam.locks[].seamDeviceLocation` is typed `string` and **populated from `device.deviceType`**. css-api can't reuse this field — it re-declares its own `SeamAccessCode` and guards every read with `isSeamDeviceType`. | type `codeSettingServiceApi.ts:34`; population `code-setting-service/functions/internal/import-from-mongo.ts:129,141` + `css-api/.../import-from-mongo.service.ts:85`; model `css-api/service/src/models/unit.model.ts:49,145`; re-decl `css-api/client/src/types/SeamAccessCode.ts:4-6` | Rename to `seamDeviceTypes` across the chain, or document that "location" means the Seam device-type classification. Expose the field properly so css-api stops re-declaring `SeamAccessCode` (see C6). |
| C5 | med | Enum collision | **`SmartthingsErrorCodes` overlaps `CssErrorCodes` in the 1030xx space with different meanings** (`103002` = LOCK_NOT_FOUND vs NO_BACKUP_CODE; `103005` = NO_FREE_SLOTS vs UNIT_NOT_FOUND; `103003/103004` likewise). Code matched on number alone across services mis-routes. | `smarttingsSyncApi.ts:10-15` vs `codeSettingServiceApi.ts:12-19` | Renumber smartthings into a disjoint block; root fix = one shared registry of per-service code ranges. |
| C6 | med | Duplicate/stale type | **css-api re-declares published enums locally instead of importing them** — `ServerlessErrorCodesEnum.ts` ≡ `common.ts ErrorCodes`; `SmartthingsErrorCodesEnum.ts` ≡ `SmartthingsErrorCodes`; plus `SeamAccessCode` (C4). Sign the published types are not discoverable/trusted by the modern service. | `css-api/client/src/types/ServerlessErrorCodesEnum.ts` = `common.ts:11-16`; `.../SmartthingsErrorCodesEnum.ts` = `smarttingsSyncApi.ts:10-15` | Import from `@kasadev/code-api-types`, or consciously demote code-api-types to legacy-only. Pick one owner per contract. |
| C7 | med | Packaging | **Stale compiled artifacts in `dist/`** (`keycafeSyncApi`, `nexiaSyncApi`, `zervSyncApi`) whose sources are gone from `src/`. `tsc` doesn't delete orphaned outputs and `dist/` is gitignored (rebuilt on `prepublish`), so a publish from a dirty local `dist` would ship dead modules. | `dist/apis/{keycafe,nexia,zerv}SyncApi.*` present, absent from `src/apis/` and `types.ts` | Add a `clean` (`rimraf dist`) step before `tsc`. |
| C8 | low | Publish health | Types-only hygiene: `test` script is `exit 1` (CI never runs the existing `typecheck`); **tslint** (EOL 2019) still configured alongside prettier; **no `engines.node`** despite `@types/node ^24`; TS pinned 5.5.2. | `code-api-types/package.json` | `test` → `npm run typecheck`; drop tslint; add `engines.node`. |
| C9 | low | Type quality | Duplicated union members (`InvocationError \| ApiRequestParseError` listed twice) and `ApiSuccessResponse<any>` in several remotelock responses. | `remotelockSyncApi.ts:51-57,67-73,81,96` | De-dup; type the `any` payloads. |

**Confirmed exported-but-unused (deletion candidates):** all of
`riskScoreService.ts` (C3) and `SmartthingsCodeNotFoundError`
(`smarttingsSyncApi.ts:27`). Caveat: `types.ts` uses `export *` and consumers
use `import type` / structural matching, so payload/command types with "0 name
refs" (e.g. `CodeEntry`, `RemotelockDeviceDetails`) are still in use
structurally — **do not** delete those. The deletion list above is limited to
named enums/error aliases with no structural fallback.

**Publish health.** `main: dist/types.js`, `types: dist/types`, build `tsc`,
TS 5.5.2, `@types/node ^24`, dep `@kasadev/enums ^21.9.0`. No CI test gate
(see C8). Node engines unspecified.

---

## 2. file-utils — `@kasadev/file-utils` v5.2.0

**Role.** Grab-bag lib: Microsoft Graph (OneDrive) client + token credential
stores, docxtemplater helpers, axios error sanitizer, stream/buffer helpers.

**Consumer reality check.** 3 consumers: guest-api (CAA generation),
financial-service + financial-api/service (reservation invoices). The Graph
client + Mongo credential store are used by guest-api and financial-service;
docx helpers by financial-service.

**Findings:**

| # | Sev | Area | Finding | Evidence | Recommendation |
|---|---|---|---|---|---|
| F1 | **high** | Dormant bug (Mongoose strict-strip) | `MicrosoftGraphMongoCredentialStore.updateSetting` writes `$set: { token, expiresAt }` at **top level**, but `getToken` reads them from **`doc.data.token` / `doc.data.expiresAt`**. The consumer `Setting` schema defines only `{ project, data }`, so Mongoose strict mode **silently drops** the top-level write → the Mongo token cache never persists/reads. Only the per-process in-memory `localStore` works, so every cold start re-requests a Microsoft Graph token. Consumers already sensed it (`as unknown as` cast + "typing is incorrect in file utils" comment). | write `file-utils/src/microsoft-graph/credential-stores/mongo-credential-store.ts:84-90`; read `:71-79`; consumer schema `guest-api/src/interfaces/Setting.interface.ts:1-4` + `guest-api/.../caa-generator.service.ts:33-37` | Patch: write `$set: { data: { token, expiresAt } }` to match the read path and the `data` schema. Root cause: store designed against a `{token, expiresAt}` top-level doc but consumers use a generic `{project, data}` settings collection — align on `data`, and add a unit test that round-trips through a strict Mongoose model (would have caught this). |
| F2 | low | Dead/unsurfaced exports | `axios-helpers.ts` (`sanitizeAxiosError`, `axiosErrorHandler`) and `utils/file-utils.ts` (`streamFromBuffer`, `bufferFromStream`) are **not re-exported** from `index.ts` — they're internal-only (used by `client.ts`), yet look like public utilities. `maskPassword` is imported in `axios-helpers.ts` but **unused**. | `file-utils/src/index.ts:1-5`; `axios-helpers.ts:2` (unused import) | Either export the helpers intentionally or mark them internal; drop the unused `maskPassword` import. |
| F3 | low | Cosmetic | `docx-templater` `formatDate` format string is `'MMM, D, YYYY'` (stray leading comma → "Jun, 18, 2025"). Renders into guest-facing invoice/CAA docs. | `file-utils/src/docx-templater/index.ts` (`formatDate`) | Use `'MMM D, YYYY'`. |

**Publish health.** Node engines unspecified (`peerDependencies: mongoose >=8.x`).
TS ^5.7.3, jest + ts-jest, eslint 8, released via release-it. Ships `dist`
via `files: ["dist"]`. Pulls a tarball-URL dep
(`docxtemplater-image-module` from `modules.docxtemplater.com`) — a supply
availability risk if that host disappears, but not a finding today. Three
consumers pin different majors-compatible ranges (`^5.0.0`/`^5.2.0`) — fine.

---

## 3. lambda-utils — `@kasadev/lambda-utils` v1.1.1

**Role.** SQS Lambda helpers: `processSQSRecords` (the recommended
`ReportBatchItemFailures` partial-batch pattern), the deprecated
`handlePartialBatchFailures`, and `httpResponse`. Load-bearing for the lock
cluster's queue workers.

**Consumer reality check.** `processSQSRecords` is the live path, used across
~11 services (segment-sync confirmed via the `ln` alias; also automessages,
breezeway-sync, code-setting-service, price-api, remotelock-sync,
smartthings-sync, sensor-service, kustomer-sync, reservation-risk-service,
kasa-website-controller). **`handlePartialBatchFailures` has no real
consumers** — the `sqsUtils.n` calls in financial-service resolve to a
*separate* `@kasadev/utils` package, not this one.

**Findings:**

| # | Sev | Area | Finding | Evidence | Recommendation |
|---|---|---|---|---|---|
| L1 | med | Dead code + latent bug | The deprecated `handlePartialBatchFailures` calls `sqs.deleteMessageBatch({ Entries: <all fulfilled> })`, but SQS caps `DeleteMessageBatch` at **10 entries per call** — >10 successful messages throws `TooManyEntriesInBatchRequest`, paradoxically failing a batch *because* too much succeeded. It also ignores the `Failed` array in the delete response (silently-undeleted messages redeliver). Mitigant: **no workspace consumer calls it.** | `lambda-utils/src/handle-partial-batch-failure.ts:36-52` | Delete the function (self-deprecated, zero consumers). If retained, chunk entries into ≤10 and inspect `result.Failed`. |
| L2 | low | Resourcefulness / duplication | Two overlapping shared libs implement SQS partial-batch handling: `@kasadev/lambda-utils` and `@kasadev/utils` (`utils/src/sqsUtils.js`). financial-service uses the latter. Splits maintenance and lets the buggy variant (L1) live on elsewhere. | `utils/src/sqsUtils.js`; `financial-service/functions/feesEndpoints.ts` | Consolidate onto `lambda-utils.processSQSRecords` and retire the `utils` SQS helper (or vice versa) — one SQS-batch helper for the org. |
| L3 | low | Logging/PII | `handlePartialBatchFailures` logs the full `rejected` `PromiseRejectedResult[]` (including error reasons that may carry message payloads). Moot if L1 deletes the function. | `handle-partial-batch-failure.ts:54-58` | n/a if removed; else log counts + messageIds, not full reasons. |

`processSQSRecords` itself is **clean**: `Promise.all` over `processOneRecord`
which try/catches internally and never rejects, so the batch can't be poisoned
by a throw; failures map correctly to `batchItemFailures`. `httpResponse` and
`makeError` are sound.

**Publish health.** Modern dual ESM/CJS (`exports` map, tsup), `type: module`,
`engines.node >=20`, TS ^5.5.4, `sideEffects: false`, jest. Deps:
`@aws-sdk/client-sqs ^3`, `@kasadev/logger ^1.2.0`. Good shape; last released
2025-10-30.

---

## 4. url-shortener-api-client — `@kasadev/url-shortener-api-client` v1.0.2

**Role.** Thin `@kasadev/api-client` wrapper over the internal URL Shortener
service (`create`, `getByShortId`, `updateByShortId`). Ships a `./factories`
entry for test data.

**Consumer reality check — the headline.** **Zero consumers anywhere in the
workspace.** No package.json depends on it; no `.ts/.tsx` imports it (the only
matches are scheduler `.md` files). Even the `url-shortener` *service* repo
doesn't use its own client. A published lib (v1.0.2) that nothing imports is a
maintenance liability with no payoff.

**Findings:**

| # | Sev | Area | Finding | Evidence | Recommendation |
|---|---|---|---|---|---|
| U1 | med | Zero consumers | Published, versioned, CI-maintained, but imported by nothing in the workspace (incl. the url-shortener service itself). | workspace grep: only scheduler `.md` matches | Archive the repo (or document the external/planned consumer that justifies keeping it published). If the url-shortener service is meant to dogfood it, wire it up; otherwise it's dead weight. |
| U2 | low | Doc/API drift | README usage is wrong: it shows `client.create({ url })` and `data.url === url`, but the actual signature is `create(url: string)` (posts `{ url }`). Since there are no in-repo consumers to copy from, the README *is* the contract — and it's incorrect. | `url-shortener-api-client/src/UrlShortenerClient.ts:28-30` vs `README.md` usage block | Fix the README to `client.create(url)`. |
| U3 | low | Dead state | `#config` private field is stored in the constructor but never read afterward (config is consumed inline into `this.client`). | `UrlShortenerClient.ts:11,15-16` | Drop the field. |
| U4 | low | Dependency placement | `@ngneat/falso` (a test-data faker) is in **`dependencies`**, not `devDependencies`/`peerDependencies` — every consumer of the main client pulls falso into prod, even without using `./factories`. | `package.json` `dependencies` | Move falso to `peerDependencies` (optional) or split factories into their own publish. |

**Publish health.** Modern dual ESM/CJS (`exports` + `typesVersions`, tsup,
version-injector), `engines.node >=18`, TS ^6.3, jest. Mechanically healthy —
it's just unused.

---

## 5. css-debugger — internal SPA (private, v1.0.0)

**Role / architecture.** React 19 + Vite 8 SPA, Auth0-gated, deployed on
Netlify; an internal Hospitality tool to inspect lock-code / device /
reservation state by calling five internal APIs from the browser
(code-setting-service, css-api, device-service, smartthings-sync, seam-sync).
Routing in `src/App.tsx` (`ProtectedRoute` + `read:css-debugger`). API layer
is split: hand-rolled axios clients in `src/services/*.ts` **and** generated
`@kasadev/*-client` SDKs wired via React contexts. Auth decodes the JWT
client-side for permissions. Mutations live in
`results/CodeJobActions.tsx` (runJob/cancelJob) and an unused smartthings
`unlock()`. Not a published library, so "zero consumers" is expected, not a
finding.

**Findings (verified by subagent against file:line):**

| # | Sev | Area | Finding | Evidence | Recommendation |
|---|---|---|---|---|---|
| D1 | **high** | AuthZ | `CodeJobActions` triggers real `runJob`/`cancelJob` lock mutations gated **only** by the render-only `Can` component (returns `null` if no perm) — permissions come from a JWT the client decodes itself. A low-priv authenticated user can call `api.runJobNow(id)`/`cancelJob(id)` from console or an edited bundle. Exploitability hinges entirely on server-side authz. `runJob` is the surface implicated in the 2026-06-01 mass-delete incident. | `src/components/common/Can.tsx:13-15`; `results/CodeJobActions.tsx:64-86`; `src/services/api.ts:198-220`; `hooks/usePermissions.ts:34` | Confirm code-setting-service enforces a write permission on `/runJob` & `/cancelJob` server-side; that's the real fix. `Can` is a UX affordance, not a security boundary. Route to TechOps if server-side enforcement is absent. |
| D2 | **high** | Mutation surface | `SmartthingsSyncApiClient.unlock()` performs a **physical door unlock** (`POST /lock-unlock/{unitId}/{account}/{lock}`) from a tool labeled "debugger". Currently dead (only `getLockStatus` is called) but one import from being wired to a button with no guard. | `src/services/smartthings-sync-api.ts:103-123`; no caller in `src/` | Delete `unlock()` from the client, or gate behind server-side permission + explicit confirm + `Can` + actor logging. |
| D3 | med | Token storage | Auth0 tokens cached in **localStorage** (`cacheLocation: 'localstorage'`); the app displays door codes + guest PII, so any XSS exfiltrates a live bearer. Token also pasted onto `axiosInstance.defaults.headers.common` via `setToken`. | `src/config/auth0.ts:7`; `src/services/api.ts:79-82` | Pair with a tight CSP (D6) + short TTL; prefer per-request token injection (already done in `ApiContext`/`CssApiContext`) over the long-lived default header. |
| D4 | med | Race / cache | `EntityLink`+`useEntityResolver`: async `resolveEntity` with **no staleness guard/AbortController** → a slow earlier resolve can overwrite a newer one on prop change. Module-global `entityCache` **never invalidates** and **negative-caches transient failures permanently** (`catch { cache[id] = null }`) — one network blip shows "not found" until full reload. | `src/components/common/EntityLink.tsx:46-61`; `src/hooks/useEntityResolver.ts:21,32-43,78-79` | Add a `cancelled` flag in effect cleanup; cache only definitive nulls (not `catch`); give the cache a TTL. |
| D5 | med | Error swallowing | `ApiClient.search/getAuditLogs/searchLogs/getRelatedObjects` `catch → return []` — a 401/forbidden read is indistinguishable from "no codes". For a forensics tool, "API errored" rendering as "guest has no code" is dangerous. Inconsistent: `getCheckIns` rethrows. | `src/services/api.ts:101-104,119-122,141-144,156-159` | Propagate errors and render an explicit error state, as `getCheckIns` already does. |
| D6 | med | Headers | **No CSP** or security headers; `netlify.toml` sets only `Cache-Control`. Removes the main XSS mitigation given localStorage tokens (D3) + untrusted-JSON rendering (D9). | `netlify.toml`; no CSP in `index.html` | Add `[[headers]]` with restrictive `Content-Security-Policy`, `X-Content-Type-Options: nosniff`, `Referrer-Policy`, `X-Frame-Options: DENY`. |
| D7 | med | CI gate | CI runs **only `npm ci`** — `npm test` and `npm run lint` are commented out and `test/` is empty. No automated gate on PRs to a repo handling door codes. | `.github/workflows/test.yml:38-39`; empty `test/` | Re-enable `npm run lint` at minimum; add a smoke build assert. |
| D8 | low/med | PII logging | `debug`-namespaced `log(...)` dumps full API payloads incl. **door codes** and `error.response.data` to console when `localStorage.debug` is set. | `src/services/device-service-api.ts:60-64,121`; `smartthings-sync-api.ts:60-71` | Redact code/PII fields; scope to dev builds. |
| D9 | low | XSS surface | `@microlink/react-json-view` (unmaintained fork, `^1.31.19`) renders raw untrusted API JSON. Lib escapes values (no `dangerouslySetInnerHTML` in app code), so low risk, but it's the likeliest XSS vector absent CSP. | `src/components/DataViewer.tsx:46-71`; `LogsModal.tsx:310` | Keep current / consider a maintained alternative; rely on CSP (D6). |
| D10 | low | Architecture | Three near-identical hand-rolled axios clients with divergent auth lifecycles: `ApiContext`/`CssApiContext` inject tokens per-request (correct); `DeviceServiceApiContext` + `SmartthingsLockState` `setToken` once → stale token 401s mid-session after refresh. | `src/context/ApiContext.tsx:68-80` vs `DeviceServiceApiContext.tsx:24-54`; `results/SmartthingsLockState.tsx:44,89-90` | One axios factory with a fresh-token request interceptor; drop default-header `setToken`. |
| D11 | low | Hygiene | Stale `cdk.out/` committed (2021 CodeBuild pinned `nodejs:14` vs actual Node 24); documents the `kasa-npm-token-2` SecretsManager ARN/account but **leaks no secret value**. `.env`/`.env.backup` exist on disk but are gitignored and **not in git history** (verified). | `cdk.out/css-debugger-dev-pipeline.template.json:208-235`; `.gitignore` | `git rm -r cdk.out/`; keep `.env*` local-only. |

**Dependency note (not a finding):** react `^19.2.5`, vite `^8.0.10`,
typescript `~6.0.3`, eslint `^10`, `@types/node ^25` all resolve to real
installed versions — aggressive but not phantom/typosquatted. Dependabot
active.

---

## Architecture notes & bus factor

- The lock cluster's type + queue plumbing rests on two of these libs
  (`code-api-types`, `lambda-utils`). The recurring theme is **drift between
  the legacy code-setting-service and the modern css-api** showing up as
  type/error-code mismatches (C1, C2, C4, C6) — consistent with the broader
  CSS-migration-is-partial picture. Recommend reconciling code-api-types as a
  single source of truth or explicitly demoting it to legacy-only.
- **Resourcefulness flags:** two SQS-batch helper libs coexist
  (`lambda-utils` + `@kasadev/utils`) (L2); css-debugger hand-rolls three
  axios clients alongside the generated SDKs (D10).
- **Bus factor — css-debugger:** heavily single-author. The three Gábor
  Balázs identities account for ~197 / ~290 commits (~68%); secondary
  contributors Zoltán Fehér (~36), Norbert Pospischek (~20). A one-bus-factor
  internal tool that performs lock mutations — pair the D1/D2 mutation paths
  with a second reviewer. (The four small libs are similarly low-contributor
  but lower-risk; not separately tabulated.)

## Production signals (Step 3) — N/A

Libraries have no deployed service / Datadog presence. Runtime error
archaeology, log-noise, monitor coverage, and forgotten-automation checks do
not apply. (css-debugger is a Netlify-hosted SPA, not a backend service with a
Datadog index; its CI/quality gap is captured in D7.)

## Cost (Steps 4–5) — N/A

No ECS/Lambda/queue footprint to right-size and no AWS resources to probe for
these packages — no cost picture to estimate. The only adjacent cost lever is
indirect: F1 causes redundant Microsoft Graph token requests on every consumer
cold start (negligible $, but real call volume).

## Skipped / caveats

- **Steps 3–5 (Datadog/AWS/cost):** N/A for npm packages — skipped by design,
  per the task brief.
- **`git fetch` failed for all five repos** (no SSH/credential agent in the
  scheduled run). Audited local working state; `origin/*` comparisons may be
  stale. `code-api-types` was audited on its feature branch (master + 1 added
  field); `css-debugger` 4 commits ahead of local origin — both deltas trivial.
- **npm-registry auth not exercised** — no live `npm audit`/`npm outdated`
  network calls were made; dependency-health notes are from package.json /
  package-lock inspection only (treated as skip-with-note per the brief, not a
  failure).
- **No git-history secret scan beyond css-debugger** — the four small libs
  were checked in-tree only (small, type/util surface, low secret risk); a
  deep `git log -p` history sweep was not run on them within the timebox.
- Server-side authorization for css-debugger's `runJob`/`cancelJob` (D1) was
  **not** verified against code-setting-service/css-api in this run — the
  finding is conditional on that enforcement.
