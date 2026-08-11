# Fable audit — cross-repo SYNTHESIS (2026-06-19)

> Finale of the June 2026 Fable audit series. Synthesizes 13 per-repo reports
> (11 runtime services + `hsp-libraries` batch + `jira`) audited Jun 11–19 under
> `AUDIT_PLAYBOOK.md`. Source reports live in `reports/fable-audit-*.md`.
> **All findings here are report-only** — the draft tickets in §5 are for Gabor to
> triage and file after cross-checking. No tickets/PRs/Slack created by this run.

**Inventory:** 13/13 expected reports present, all with findings sections. No
missing or failed audits.

| Service / repo | Date | Findings | Highest sev |
|---|---|---|---|
| code-setting-service | 06-18 | 7 | high (live incident) |
| css-api | 06-11 | 13 | high |
| device-service | 06-11 | 15 | high (9 high) |
| seam-sync | 06-14 | 14 | high |
| smartthings-sync | 06-13 | 15 | high |
| remotelock-sync | 06-13 | 14 | high |
| salto-sync | 06-13 | 14 | high |
| salto-device-event-listener | 06-14 | 18 | high (7 high) |
| sensor-service | 06-12 | 15 | high |
| callbox-automation | 06-15 | 14 | high |
| sns-events | 06-17 | 11 | high |
| hsp-libraries (5 pkgs) | 06-18 | F1/C1/C2/D1/D2 high | high |
| jira (jira-dashboard) | 06-19 | 20 | high |

---

## 1. Portfolio top 10

Re-ranked across all repos by **service criticality × guest impact × live-ness**,
not by each repo's local severity. css-api and code-setting-service are the live
lock-code execution spine (highest criticality); the four vendor-sync services
(seam/smartthings/remotelock/salto) sit directly between a reservation and a guest
getting through a door.

| # | Repo | Finding | Evidence | Patch vs root-cause |
|---|------|---------|----------|---------------------|
| 1 | **code-setting-service** | **Active, unalerted Seam-404 error flood on the live execution engine.** A bare HTTP 404 (Seam device deleted server-side) escapes classification and falls through to `logger.error` *without* `shouldRetry:false`, so the scheduler retries already-`failed` codes until the window lapses. | DD `seam_check_code_failed` 06-16=**42,561**, 06-17=19,912 vs ~6–10/day baseline. `lib/devices/SeamSync/ProcessorChain.ts:415,491`; retry default `Scheduler/Errors/SchedulerError.ts:30`. | **Patch:** classify bare 404 → device-not-found → `shouldRetry:false`, mark code, notify (mirror `:464`). **Root:** the checkCode path is not yet ported to css-api — finish that with 404→terminal classification so the bug isn't recreated. **Route live incident to TechOps.** |
| 2 | **fleet-wide (~11 services)** | **Guest door-code PINs (and guest PII) logged in plaintext to Datadog — confirmed in production.** The single highest-impact compliance exposure; appears in nearly every runtime service. See §2-A for the full repo list. | css-api `code-assignment-at-cut-off.service.ts:117`; sensor `lambdaUtils.ts:25` (~9.3M/mo); smartthings `get-lock-codes.ts:29` (1.17M/14d); remotelock `RemoteLockClient.ts:32` (48K PIN lines); seam `webhook.service.ts:42`; device-service `processDeviceEvent.ts:18`; callbox; salto-device-event-listener `EventStreaming.salto.ts:240`. | **Patch:** strip `code`/`pin`/`confirmationCode`/guest fields at each call site. **Root:** add PII-key redaction to `@kasadev/logger` + a Datadog Sensitive Data Scanner rule for `pin`/`code`/`access_code_id`. **Audit Datadog read-access + historical exposure with TechOps.** |
| 3 | **code-setting-service** | **STS credentials logged in plaintext** — the structured `error` attr of `seam_check_code_failed` serializes the signed outbound axios request headers (`authorization: AWS4-HMAC-SHA256…`, full `x-amz-security-token`). | DD raw events (3/3 sampled) contain `x-amz-security-token`, `IQoJ…`. Source `ProcessorChain.ts:491`. | **Patch:** `redactRequestHeaders(error)` strips `authorization`/`x-amz-*` before logging. **Root:** shared `sanitizeAxiosError` for all provider clients. Tokens are short-lived (no rotation) but **confirm DD read-access with TechOps**. |
| 4 | **remotelock-sync** | **`WEBHOOK_SECRET` UUID hardcoded in git since 2020-09-28 and logged to Datadog on every call** (~302K exposures/14d). Anyone with repo or DD access can forge RemoteLock webhook events. | `serverless.yml:97`; DD `get_webhook_event_start` 302K entries with live `X-Secret`. | **Patch:** stop logging the event; move secret to SSM/Secrets Manager. **Rotate immediately — route to TechOps / #sekurity-korner.** |
| 5 | **css-api** (+ fleet) | **Destructive scheduled jobs default `dryRun:false` with no kill switch — the Jun-1 mass-delete incident class.** `cleanup` and `import-from-mongo` default false on EventBridge; `check-code-groups` has no dry-run at all. Same shape recurs across the fleet (§2-E). | `cleanup.handler.ts:11`, `import-from-mongo.handler.ts:8`, `check-code-groups.service.ts:14`. The actual Jun-1 culprit was remotelock `deleteCodeByKeyword` (no dry-run). | **Patch:** default `dryRun:true` on all scheduled handlers. **Root:** shared "destructive job" wrapper — dryRun-true default + SSM/ConfigCat kill switch without redeploy. Carry into the css-api port of code-audit. |
| 6 | **remotelock-sync** | **`createUserCode` 429 retry storm — guests not getting codes.** 8,100 HTTP 429 + 6,574 HTTP 422 ("PIN already taken", duplicate creates) in 14d. No backoff, no idempotency; CSS retries immediately → re-hits the limit. | DD 429s on `createUserCode`=8,100; `RemoteLockClient.ts:65` throws 429 immediately; `function-helpers.ts:48`. | **Patch:** exponential backoff + jitter on 429, surface `Retry-After`. **Root:** shared vendor-HTTP resilience policy (§2-C) + look-up-or-create idempotency. |
| 7 | **seam-sync** | **Seam fails to create access methods 22,800×/day — likely direct guest door-code impact.** Plus `error_getting_access_grant_code` at 28K/day (callers polling deleted grants). Chronic across the full 14d window, unalerted. | DD `handling_failed_to_create_access_method`=319,112/14d; `error_getting_access_grant_code`=393,815/14d. | **Patch:** add monitors; verify downstream retry/alert on `seamFailedToCreateAccessMethodEvent`. **Root:** investigate device/device-type failure split in Seam; fix the stale-grant-id caller (CSS-API/device-service). |
| 8 | **device-service** | **css-api 503s not differentiated from 4xx → 2,599 parse errors/14d (~97% of daily errors).** `getDeviceDetails` treats 503 like any error; no `retryOn`. A sibling client (`Kontrol.ts`) already has the right retry pattern in the same repo. | DD `parse_message_error`+`process_device_event_error`=2,599 each/14d (all 503). `CodeSettingService.ts:11-23`. | **Patch:** add `retries:3, retryOn:[500,502,503,504]` (copy `Kontrol.ts`). **Root:** `@kasadev/css-api-client` base client should ship retry config by default (§2-C). |
| 9 | **device-service** | **RemoteLock access-denied events silently dropped to DLQ — one missing `return`.** `RemoteLockDeviceEventParser.isDeviceEvent()` falls off the end (returns `undefined`/falsy) when `associated_resource_type` is present, so `canParse()` rejects every such event → `CantFindParserError` → permanent DLQ. | `lib/parsers/RemoteLockDeviceEventParser.ts:166-170`. | **Patch:** add `return false;` after line 169 (one line). **Root:** the god-parser concentrates all classification; split + unit-test the `canParse` gate. |
| 10 | **salto-device-event-listener** | **getSites Lambda 401 every cron run for 7+ days + a health check that lies.** New Salto sites can't be discovered without a task restart; `healthCheck()` returns `status:true` with 0 connections, so ECS never restarts a stranded task and nothing alerts. | DD `error_calling_get_sites_salto_sync_lambda`=1,009/7d (100% of cron runs since ~Jun 7); `EventStreaming.salto.ts:63-72`. | **Patch:** restart task to re-seat sites; add monitor; return `status:false` when connections=0. **Root:** cross-team — salto-sync `getSites` invocation auth contract changed; reconcile. |

**Runners-up (strong, just outside the 10):** device-service **IDOR** on the
direct-Lambda `getEvents` path (returns all tenants' events with no scope field,
`functions/getEvents.ts:25`); **fast-xml-parser critical** in five services' AWS-SDK
bundle (§2-G); css-debugger **client-side-only authz** on `runJob`/`cancelJob`
(D1, same surface as Jun-1); callbox **`handlerWrapper` returns `null` → HTTP 502 →
Twilio 11× retry storm** (`handler-wrapper.ts:98`); salto-sync **`scan-inventory`
`return` instead of `continue`** silently skips all remaining devices on one DB
error (`scan-inventory.ts:83`); sns-events **frozen `eventTimeStamp` default**
(time-series corruption, `event-timestamp-validator.ts:7`); file-utils **Mongoose
strict-strip** makes the Graph token cache a no-op (F1).

---

## 2. Systemic patterns (≥ 2 repos)

The four vendor-sync services were the prime suspects, and they are — but the two
biggest patterns (PII-in-logs, missing monitors) span essentially the whole fleet.
Every pattern below has a fix that belongs in a **shared lib or the
template-domain-mono-repo**, not in N per-repo patches.

### A. Door-code PINs / guest PII logged to Datadog — **~11 repos**
css-api, code-setting-service, device-service, sensor-service, smartthings-sync,
salto-sync, remotelock-sync, seam-sync, callbox-automation,
salto-device-event-listener, css-debugger (console). **Root cause:** no
log-sanitization layer; every service hand-logs raw request/response/event bodies.
**Fix (shared):** PII-key redaction (`pin`, `code`, `confirmationCode`, `secret`,
`x-amz-*`, `authorization`, guest name/email/phone) in `@kasadev/logger` + a Datadog
Sensitive Data Scanner backstop. This is one lib change that closes a fleet-wide
compliance gap and most of the cost lever in §3 simultaneously.

### B. Missing HTTP-client timeouts — **8 repos**
device-service (css-api/seam-sync), sensor-service (Minut), smartthings-sync (SDK),
seam-sync (Seam SDK), remotelock-sync (**300,000 ms / 5 min!**),
salto-device-event-listener (Lambda client), callbox-automation (Mongo connect),
jira (every outbound). **Root cause:** Node `fetch`/axios/AWS-SDK default to no
timeout; each service must opt in and most don't. **Fix (shared):** a default
timeout (10–30 s) baked into `@kasadev/api-client` and the generated `*-client`
SDKs, plus `serverSelectionTimeoutMS`/socket timeouts in a shared Mongoose connect
helper.

### C. Missing retry/backoff on vendor 429/5xx — and the inverse, retry-forever on terminal errors — **4+ repos**
remotelock (429 storm, no backoff), device-service (503 not retried), salto-sync
(hitting Salto 429 despite Bottleneck), code-setting-service (Seam **404 retried
forever** — the opposite failure). **Root cause:** no shared transient-vs-terminal
classification policy; each client invents its own (or none). **Fix (shared):**
a vendor-HTTP resilience wrapper with exponential backoff + jitter for transient
(429/5xx, honoring `Retry-After`) and hard-stop for terminal (404/422), used by all
provider clients. `device-service/services/Kontrol.ts` is the in-repo reference impl.

### D. Zero or inadequate Datadog monitors — **fleet-wide**
**Zero monitors:** sensor-service, smartthings-sync, remotelock-sync, seam-sync,
salto-device-event-listener. **Inadequate (none on the modes that actually fire):**
code-setting-service (3, none useful), device-service (3, no error-rate), css-api
(gaps), salto-sync (1), callbox (1). Every chronic error in §4 fired unalerted.
**Root cause:** monitor creation isn't part of service bootstrap. **Fix
(template-mono-repo):** the shared CDK pattern should provision a baseline monitor
set per service — error-rate, DLQ depth, cron-didn't-run — at deploy time.

### E. Destructive scheduled jobs without dry-run default / kill switch — **6 repos**
css-api (cleanup/import/check-code-groups), code-setting-service
(codeAuditQueueFiller — the Jun-1 job), device-service (3 dead migration Lambdas with
live `updateMany`/`bulkWrite`, no trigger, no guard), remotelock-sync
(`deleteCodeByKeyword` — the actual Jun-1 culprit), salto-sync (`scanInventory`),
smartthings-sync (`checkSmartthingsHealth`, prod always live). **Root cause:** no
shared guard-rail pattern. **Fix (shared):** a "destructive job" wrapper —
`dryRun:true` default + SSM/ConfigCat kill switch togglable without redeploy. Ties
directly to `code-audit-mass-delete-incident`.

### F. OAuth token caching / refresh bugs — **4 repos**
sensor-service (Minut token never refreshed, cached till container recycle),
remotelock-sync (no caching → 577K Secrets-Manager reads/14d), smartthings-sync
(stale OAuth refresh), salto-device-event-listener (fetched once, refresh-race on
reconnect). **Root cause:** ad-hoc per-service token management. **Fix (shared):**
an expiry-aware token-cache helper (cache in container scope, refresh at ~80% TTL,
async `accessTokenFactory`).

### G. `fast-xml-parser` critical + `mongoose` `$nor` NoSQL-injection via stale transitives — **6 repos**
fast-xml-parser (CVSS 9.3, via `@aws-sdk/core`): device-service, sensor-service,
smartthings-sync, callbox-automation, salto-device-event-listener. mongoose `$nor`
(GHSA-wpg9-53fq-2r8h): salto-sync, smartthings-sync. **Root cause:** stale
`@aws-sdk`/`mongoose` pins + **no `npm audit` gate in CI anywhere**. **Fix
(org-wide):** coordinated `overrides` bump + an `npm audit --audit-level=high` CI
step in the shared workflow template (jira repo already did this via overrides — use
it as the pattern).

### H. Swallowed errors / silent partial success ("wrong-but-green") — **7 repos**
device-service (`recordStateTransition`, isDeviceEvent), smartthings
(checkHealth swallow), seam-sync (`deleteCodesFromDevices` partial state),
salto-device-event-listener (SNS publish discarded, SIGTERM not awaited), jira
(partial Jira fetch dropped, single-page scan, PTO silently zeroed), sns-events
(partial batch-publish lost), css-api (`Promise.allSettled` drops import failures).
**Root cause:** catch-log-don't-rethrow + `Promise.all(Settled)` without inspecting
failures. **Fix:** more cultural than a single lib — partial-result return contracts
(`{succeeded, failed}`) + a lint rule against bare catch-and-return; worth an ADR.

### I. TypeScript `strict:false` — salto-sync, smartthings-sync, remotelock-sync, device-service (partial). Lower priority; the `*-ts6` branches address several. Mentioned for completeness, not ticketed individually.

---

## 3. Cost rollup

Two levers dominate: **Datadog INFO-log spam** (every high-volume service) and
**Lambda 1024 MB over-provisioning** (smartthings the worst). Dollar figures are the
authors' estimates (most runs couldn't pull CloudWatch — AWS creds expired
overnight, see §6), so treat as order-of-magnitude. SNS-events and the libraries
have no compute/Datadog footprint ($0).

| # | Repo | Lever | Effort | Est. $/mo |
|---|------|-------|--------|----------:|
| 1 | smartthings-sync | Right-size 16 Lambdas 1024→512 MB (+ log volume −41%) | M (power-tune) | **~$150–210** |
| 2 | code-setting-service | Demote `runJob` per-item paired INFO → debug (82% of its volume) | S | **~$130–170** |
| 3 | sensor-service | Stop logging `getLockCodes` response ($93) + per-unit/per-device verbose ($46) | S | **~$139** |
| 4 | css-api | `import_mongo_unit` INFO→debug ($15–40) + WORKER 512→256 if p50<20% ($45) | S/M | **~$60–85** |
| 5 | remotelock-sync | Drop `remotelock_request_data`/`_response_data` ($40–60) + token cache ($5.70) | S | **~$46–66** |
| 6 | seam-sync | Collapse 4-line webhook + 2-line worker log sequences to 1 each (~68% vol) | S | **~$28** |
| 7 | device-service | Demote `get_parser_*` hot-path logs + memory canary 1024→512 | S/M | **~$15–23** |
| 8 | salto-sync | Fix `more_than_one_lock_found_for_unit` (2.7M warn/14d) root cause | M (data) | **~$3** (huge noise-ratio win) |
| — | salto-device-event-listener / callbox | Strip PII logs (cost negligible; the win is compliance) | S | <$1 |

**Total estimated monthly savings: ~$570–740/month**, ~80% of it Datadog log
ingestion. The largest *single* action by ROI is the **shared `@kasadev/logger`
PII-redaction change (§2-A)** — it captures a big slice of items 2–8 *and* closes
the fleet-wide compliance gap in one lib release. Note: cost step on
sub-$5/mo Lambda-only services (salto-sync, callbox, salto-device-event-listener)
produced little — see retro §6.

---

## 4. Chronic-error hit list (longest-running production errors)

Ranked by volume × age. All chronic across the full ~14-day Datadog retention
window unless noted, and (except the bottom two) **completely unalerted**.

| Repo | Error | Volume | Age / trend | Root cause |
|------|-------|--------|-------------|------------|
| seam-sync | `error_getting_access_grant_code` | 393,815/14d (**28K/day**) | chronic ≥14d | Callers (CSS-API/device-service) poll `GET /access-grant/:id/code` after the grant is deleted from Seam — stale ref. |
| seam-sync | `handling_failed_to_create_access_method` | 319,112/14d (**22.8K/day**) | chronic ≥14d | Seam can't create the physical lock code after grant setup — possible guest door-code impact. |
| code-setting-service | `seam_check_code_failed` (404) | 74,974/14d, **spiking 42,561 on 06-16** | acute spike on a ~6–10/day baseline | Bare 404 retried forever (Top-10 #1). Live. |
| remotelock-sync | `remotelock_api_error` + handler errors | 39,134/14d (**2,795/day**) | chronic ≥14d | 429 (9,212) rate-limit storm + 422 (6,574) duplicate-PIN creates; no backoff, no idempotency. |
| smartthings-sync | `smartthings_handler_failed` (400) + `no_client_found` | ~13,258/14d (part of ~70K total errors, ~5K/day) | chronic ≥14d | Stale OAuth tokens / decommissioned SmartThings accounts not in Secrets Manager. |
| device-service | `parse_message_error` (+paired) | 2,599/14d (**185/day**) | chronic ≥14d | css-api 503 not retried (Top-10 #8). |
| salto-device-event-listener | `error_calling_get_sites_salto_sync_lambda` (401) | 1,877/14d, **100% of cron since ~Jun 7** | ongoing 7+ days | salto-sync getSites invocation auth contract changed (Top-10 #10). |
| salto-sync | `more_than_one_lock_found_for_unit` (warn) | 2,699,442/14d | chronic ≥14d | Multi-lock units in DB silently excluded from status updates — data-quality + 70% of the service's log volume (not an error per se). |
| css-api | `salto_code_value_not_set_after_job` (88/day), `error_fetching_access_codes_for_access_id` (55/day) | 1,996/14d combined | chronic ≥14d | Salto async job doesn't write code value back; cleanup/fetch race. |

---

## 5. Draft ticket batch (report-only — do not file from this run)

HSP drafts for each portfolio-top-10 and each systemic pattern. Priority reflects
guest impact + live-ness. **The four secret-rotation items must be routed to TechOps
(Balázs Antal) / #sekurity-korner, not just filed as tickets.**

### Portfolio top 10

1. **[Blocker] code-setting-service: Seam-404 retry-forever flood (live incident)** — Classify bare HTTP 404 from `getCodesByDeviceId` as device-not-found (`shouldRetry:false`) at `ProcessorChain.ts:491`; add a `seam_check_code_failed > 500/h` monitor. *Priority: Highest. Route live incident to TechOps.*
2. **[Compliance] Fleet: redact door PINs + guest PII from Datadog logs** — Add PII-key redaction to `@kasadev/logger` + DD Sensitive Data Scanner; patch the confirmed call sites (css-api, sensor, smartthings, remotelock, seam, device-service, callbox, salto-device-event-listener). Audit DD read-access + historical exposure with TechOps. *Priority: Highest.*
3. **[Security] code-setting-service: STS creds in Datadog error logs** — `redactRequestHeaders` / shared `sanitizeAxiosError` strip `authorization`/`x-amz-*`. *Priority: High. Route to TechOps.*
4. **[Security] remotelock-sync: rotate WEBHOOK_SECRET + stop logging it** — Rotate the 2020 UUID, move to SSM, drop `event` from `get_webhook_event_start`. *Priority: High. Route to TechOps / #sekurity-korner.*
5. **[Reliability] Fleet: dry-run default + kill switch for destructive scheduled jobs** — Shared "destructive job" wrapper (`dryRun:true` default + SSM/ConfigCat kill switch); apply to css-api cleanup/import/check-code-groups, remotelock `deleteCodeByKeyword`, salto-sync `scanInventory`, device-service migration Lambdas. *Priority: High (Jun-1 incident class).*
6. **[Guest impact] remotelock-sync: backoff + idempotency on createUserCode** — Exponential backoff + jitter on 429 (honor `Retry-After`); look-up-or-create to kill the 422 duplicate-PIN storm. *Priority: High.*
7. **[Guest impact] seam-sync: triage 22.8K/day access-method-creation failures** — Investigate device-type failure split; verify downstream retry/alert; add warn-rate monitor. *Priority: High.*
8. **[Reliability] device-service: retry css-api 5xx** — Add `retries:3, retryOn:[500,502,503,504]` to the css-api client; default it in `@kasadev/css-api-client`. *Priority: High.*
9. **[Bug] device-service: RemoteLock isDeviceEvent missing return** — Add `return false;` at `RemoteLockDeviceEventParser.ts:169`; regression test. *Priority: High (one-line, drops all RemoteLock access-denied events today).*
10. **[Reliability] salto-device-event-listener: fix getSites 401 + lying health check** — Cross-team fix of the salto-sync invocation auth; `healthCheck` returns false at 0 connections; add monitor. *Priority: High.*

### Systemic patterns

- **[Shared lib] Default HTTP/Mongo timeouts in `@kasadev/api-client` + connect helper** (§2-B, 8 repos). *Priority: High.*
- **[Shared lib] Vendor-HTTP resilience policy: transient-vs-terminal retry/backoff** (§2-C). *Priority: High.*
- **[Template-mono-repo] Baseline Datadog monitor set per service at deploy** (§2-D, fleet). *Priority: High.*
- **[Shared lib] Expiry-aware OAuth token-cache helper** (§2-F, 4 repos). *Priority: Medium.*
- **[Org-wide] `npm audit --audit-level=high` CI gate + `@aws-sdk`/`mongoose` overrides bump** (§2-G, 6 repos). *Priority: Medium (use jira repo's overrides as the pattern).*
- **[ADR] Partial-result return contracts; ban catch-log-return** (§2-H, 7 repos). *Priority: Medium.*
- **[Security] seam-sync: rotate apigw tokens in cdk.context.json** — *Priority: High. Route to TechOps.*
- **[Security] jira: rotate the two committed ICS calendar tokens; move to SSM** — *Priority: High. Route to TechOps.*

### Other notable (file as capacity allows)
device-service IDOR on `getEvents` (move scope guard into the parser — High);
css-debugger server-side authz on `runJob`/`cancelJob` (verify enforcement — High,
route to TechOps if absent); callbox `handlerWrapper` null→502 retry storm (return
`buildForwardToGx()` — Medium); sns-events lazy `eventTimeStamp` default
(`.default(() => …)` — Medium); file-utils Mongo token-cache strict-strip (F1 —
Medium); url-shortener-api-client archive (zero consumers — Low); code-api-types
error-code/command-shape drift vs css-api (C1/C2 — Medium).

---

## 6. Audit retro

**Checks that earned their cost:**
- **Datadog error archaeology** — by far the best ROI. It surfaced the live,
  unalerted incidents that static review never would: the Seam-404 flood, the
  getSites 401 (failing 100% for a week), and the 22.8K/day seam access-method
  failures. This is the check to keep and deepen.
- **Live PII-in-logs inspection** — turned a theoretical concern into a confirmed,
  fleet-wide compliance finding with exact message keys. High value.
- **Hardcoded/logged-secret scan** — found four rotate-now secrets (remotelock
  WEBHOOK_SECRET, code-setting-service STS creds, seam apigw tokens, jira ICS
  tokens). High value, directly actionable.
- **Destructive-job / guard-rail check** — directly tied to the Jun-1 incident and
  consistently productive.
- **Monitor-coverage pass** — cheap and consistently damning (5 services with zero
  monitors). High actionability.

**Checks that produced noise / diminishing returns:**
- **Per-repo `npm audit`** — surfaced the *same* `fast-xml-parser`/`mongoose`
  transitives five times, mostly dev-dep or AWS-SDK-bundled. Should be one org-wide
  sweep, not per-repo. Worse, it couldn't run offline in several runs
  (sns-events flagged an unverifiable "CRITICAL" it then had to retract) — noise.
- **Bus-factor tables** — informative the first few times, but it's the same three
  names (Norbert / Zoltán / Gábor) every report. Marginal new signal after repo 3;
  better as a single org snapshot.
- **Cost step on tiny Lambda-only services** — effort estimating $0.06/mo
  (salto-sync), <$0.01/mo (callbox), ~$0.10/mo (salto-device-event-listener). Skip
  the cost step below a threshold.
- **TS `strict:false`** — flagged repeatedly with low audit-context actionability;
  the `*-ts6` branches already address it.

**What a future round should change:**
1. **Run systemic checks once, cross-repo** — npm audit, logger-PII grep, timeout
   grep, monitor-coverage, bus-factor — instead of rediscovering them per repo.
   Per-repo runs should focus on production signals (the high-ROI part).
2. **Fix the AWS-creds-expire-overnight problem** — most runs couldn't pull
   CloudWatch/DLQ/Lambda metrics, so cost and DLQ figures are estimates. This is the
   `scheduler-aws-creds-frozen-env` quirk; pre-stage long-lived creds or schedule
   when a refresh is available.
3. **Provision an SSH/deploy key for the scheduler env** — `git fetch` failed in
   nearly every run, so audits ran on possibly-stale local refs.
4. **Reset the playbook's log window to 14–15 days** — that's the real Datadog
   retention; the 90-day expectation never held.
5. **Skip Steps 3–5 for library repos** (correctly done for hsp-libraries/sns-events
   — make it the documented default) and skip the cost step for sub-$5/mo services.
