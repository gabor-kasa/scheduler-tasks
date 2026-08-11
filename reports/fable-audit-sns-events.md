# Fable audit — sns-events (2026-06-17)

Audited: detached worktree off cached `origin/master` HEAD `54ec39dd` (2026-06-03 11:29 UTC,
"Merge PR #985"). `git fetch` failed at runtime (ssh publickey denied) so this is the
2026-06-03 tree, not necessarily today's tip. Local checkout was on a stale feature branch
(`chore/add-production-release-summary`, 2026-03-04) — left untouched.

## TL;DR
`@kasadev/sns-events` (v75.5.0) is a **library + infra repo**, not a runtime service: ~286
type-safe SNS publisher functions over 29 domains, plus two serverless@4 stacks declaring
240 SNS topics. It's disciplined and well-structured — a single validation chokepoint
(`src/sns.ts`), clean publisher↔topic alignment, 199 test files. The **single most important
finding is a verified dormant bug**: two publishers build their joi schema once at module
load / first call, so the `eventTimeStamp` default (`new Date().toISOString()`) is **frozen
at process start** — long-lived callers that omit the timestamp stamp every event with the
service's boot time (time-series corruption). Next: **none of the 240 SNS topics are
encrypted at rest** despite carrying guest PII, payment and reservation data, and the **v1
CloudFormation stack is at 167/200 outputs** — one new topic in the wrong file fails the
whole deploy. No direct $ savings (SNS topic cost is negligible; no compute in this repo);
the levers here are correctness, compliance, and deploy-safety, not spend.

## Findings (ranked)

| # | Sev | Area | Finding | Evidence | Recommendation |
|---|-----|------|---------|----------|----------------|
| 1 | **high** | Dormant bug | **Frozen `eventTimeStamp` default.** `getEventTimestampValidator()` does `.default(new Date().toISOString())` — the date is evaluated when the joi schema object is *built*. Two publishers build their schema **once** (module-level / cached singleton), not per-call, so the default freezes at first import/call. Any caller that omits `eventTimeStamp` gets the process-start time forever. The other 61 timestamp users build the schema inside the publish fn (fresh each call) and are safe. | `src/helpers/event-timestamp-validator.ts:7`; frozen in `src/publishers/portfolio-manager/roomTypeInventoryChanged.ts:41` (module `const schema`) + `:74`; `src/publishers/extension-requests/extensionRequestBaseSchema.ts:5,9,26` (cached `let schema`) | **Root fix (covers all current + future cases):** make the default lazy — `.default(() => new Date().toISOString())` in `event-timestamp-validator.ts`. Joi evaluates a function default at validation time. Cheap one-liner, kills the whole bug class. Patch alone: rebuild those 2 schemas per-call. |
| 2 | **medium** | Resilience / bug | **Partial batch-publish failures are easy to lose.** `sendMessagesBatch` chunks at 10, accumulates `{messageIds, failures}` and returns them, but (a) nothing forces callers to inspect `failures` — a partially-failed batch looks like success; (b) if a *whole* chunk's `send()` rejects, the promise throws and already-published chunks' ids are lost with no partial result, and later chunks never run; (c) `entry.MessageId!` non-null assertion. Synthetic ids `chunk-${i}-message-${idx}` could map failures back to input indices but the return value doesn't. | `src/sns-client.ts:57-88` (loop 62-85, `entry.MessageId!` 79) | Return failures keyed to original input index; consider a `throwOnPartialFailure` option (default true) so silent partial loss isn't the default. Wrap the per-chunk `send()` so one chunk's rejection doesn't discard prior successes. |
| 3 | **medium** | Security / compliance | **No encryption-at-rest on any SNS topic.** Zero `KmsMasterKeyId` / SSE across all 240 topics, including ones carrying guest PII, payments, identity/background-check and reservation data (`guestCreated`, `guestPhoneUpdated`, payment/risk topics, reservation*). | `grep KmsMasterKeyId services/` → 0 matches; 170 topics v1 + 70 v2 | Add `KmsMasterKeyId: alias/aws/sns` (AWS-managed key, no extra cost) to each topic's `Properties`. Relevant to PCI/CCPA posture. Subscribers need matching `kms:Decrypt` — coordinate, don't bulk-flip blind. |
| 4 | **medium** | Bug / contract | **TS interface vs joi schema mismatch (`maxStayNights`).** Interface marks it optional, schema marks it `.required()`. A caller trusting the type and omitting it hits a runtime joi error. The type lies. Symptom of a broader gap: nothing checks interface↔schema agreement. | `src/publishers/tax/taxDefinitionCommon.ts:32` (`maxStayNights?: number`) vs `:70` (`.required()`) | Decide the truth and align both. Root fix: a unit test (or `Joi.object<T>()` stricter typing) that fails when a required schema key is optional in the interface or vice-versa. |
| 5 | **medium** | Infra / deploy-safety | **v1 stack at 167/200 CloudFormation outputs.** Banner already warns; existing test only fails at 201. Adding one output to `services/v1/serverless.yml` fails the *entire* stack deploy. | `services/v1/serverless.yml:3-12` (banner), 167 `*Output:` entries; `src/__test__/serverless.unit.test.ts` limit check | CI guard failing at >195 (not 201) to catch it in PR. Keep routing new topics to v2 (70/200, healthy). Longer term: split stacks by domain to remove the ceiling. |
| 6 | **medium** | CI / supply chain | **Autorelease PRs skip every CI check.** Each step in `node.js.yml` is gated on `!contains(login,'npm-autorelease-pr-creator')`, and those PRs carry the `automerge` label → version-bump PRs merge with **no build, no test, no changelog check**. CI also has no `lint`, no `prettier`, no `npm audit` step at all. | `.github/workflows/node.js.yml` (per-step `if:`); `.github/workflows/automerge.yml` | At minimum run `npm run build` on autorelease PRs. Add `npm run lint` + `npm audit --audit-level=high` steps for normal PRs. |
| 7 | **low** | Correctness / clarity | **FIFO dedup is intentionally disabled via random dedup id — but undocumented.** 29 publishers pass `setDeduplicationId: random*` putting `Math.random()` into `MessageDeduplicationId` on `.fifo` topics that also set `ContentBasedDeduplication: true` (e.g. `nightlyRatesUpdated` → `nightlyRatesUpdated-${stage}.fifo`). The explicit id overrides content dedup, so dedup is effectively **off** while ordering (per `messageGroupId`) is kept. This is *plausibly intended* ("always push the latest rate/inventory"), so not a bug — but it's a foot-gun for the next reader and relies on two near-identical helpers. | `src/helpers/randomize-deduplication-id.ts`, `random-deduplication-id.ts`; `src/publishers/revenue-management/nightlyRatesUpdated.ts:46`; `services/v1/serverless.yml:999`; 29 callers | Document the intent at the helper. Consolidate the two helpers into one named `disableFifoDeduplication()` (or similar) so the intent is self-evident. |
| 8 | **low** | Maintainability | **Duplicated inline validators.** MongoId regex `/^[a-fA-F\d]{24}$/` is re-declared inline in multiple publishers instead of living in `helpers/basic-validators.ts`. | `src/publishers/rate-plans/ratePlanEdited.ts:33`, `src/publishers/stay-restrictions/stayRestrictionCommon.ts:8` | Add `mongoId`/`mongoIdArray` to shared validators and reuse. |
| 9 | **low** | Security (dev tooling) | **Codegen interpolates unsanitized input.** `scripts/add-new-event.mjs` injects inquirer answers (`subfolderName`, `topicName`) into file paths and generated TS template strings with no validation (path traversal / broken-TS injection). Runs only on developer machines with trusted input → low. | `scripts/add-new-event.mjs` (path.join + template literals) | Validate `topicName`/`subfolderName` against `^[a-zA-Z0-9_-]+$` before use. |
| 10 | **low** | Docs | **README is stale.** Documents Seed.run as the deploy path; actual deploy is GitHub Actions (`deploy-serverless-{dev,production}-v{1,2}.yml`). | `README.md:96-101` vs `.github/workflows/` | Update the deploy section to reflect GitHub Actions + workflow_dispatch for prod. |
| 11 | **low** | Validation | **Timestamp regex is unanchored + unescaped `.`** (`/\d{4}...\.\d{3}Z/` — the `.` matches any char, no `^`/`$`), so `...00X000Z` passes the regex. Impact is contained because joi `.isoDate()` runs alongside and rejects it; the regex is effectively decorative. | `src/helpers/event-timestamp-validator.ts:6` | Anchor + escape: `/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/`. Fold into the #1 fix. |

## Architecture notes
- **Two faces.** (a) **Library:** ~286 publisher fns across 29 domain folders (`src/publishers/*`), each = a joi schema + the `createPublisher`/`createBatchPublisher`/`createCommandPublisher` factory in `src/sns.ts`. The factory validates the body, stamps `eventName`/`commandName`, attaches `environment` + optional message attributes / FIFO group / dedup id, and calls the SDK v3 wrapper (`src/sns-client.ts`). (b) **Infra:** `services/v1/serverless.yml` (2321 lines, 170 topics) + `services/v2/serverless.yml` (955 lines, 70 topics), two independent serverless@4 stacks exporting CFN outputs that other services import as `event:<stage>:<name>`.
- **Single chokepoint, clean.** Spot-checks found no publisher bypassing the factory to call `sns-client` directly; validation is centralized and consistent. Publisher↔topic alignment is tight (the subagent sweep found no obvious orphan publishers or undeclared topics in the sampled set).
- **Schema versioning is name-based and informal.** `CommonEvent` has only `eventName` — no schema version. Breaking changes rely on additive-only discipline + occasional `*V3` event names (`kbcFinalStepReachedV3`). Combined with `stripUnknown: true` (default in `src/sns.ts:43`), a field a caller adds but the schema author forgot to declare is **silently dropped** — no concrete live instance found, but `maxStayNights` (#4) shows interface/schema do drift. Worth a documented versioning convention.
- **v1/v2 split** is a deliberate workaround for the CFN 200-output cap, not accidental forking (no topic-name collisions seen; v2 is the "new topics go here" stack).

### Bus-factor (commits since 2024-06, by area)
`git shortlog` returned empty for the 2-year window on this detached worktree (sparse/limited history available locally); per-directory author counts:

| Area | Top authors (commit count) | Note |
|------|----------------------------|------|
| `src/` overall | zoltan feher (44), Matt Nasiatka (23), norbertp-kasa (21), Corey Stubbs (15) | healthy spread |
| `src/helpers/` | Janos Mayer (5), then 1 each (zoltan, Péter Horváth) | **thin** — the shared validator/dedup layer (where finding #1 lives) is effectively one-author |
| `services/` (infra) | zoltan feher (26), Corey Stubbs (10), norbertp-kasa (9) | reasonable |

`src/helpers/` is the bus-factor risk: it's the highest-leverage code (every publisher depends on it) with the thinnest authorship.

## Production signals
**Not applicable — this repo has no runtime service.** It ships an npm package and declares SNS topics; there is no Lambda/Fargate/cron in it, no `dd-trace`/Datadog instrumentation, and therefore no `service:` to query. Datadog error-archaeology, log-noise, monitor-coverage, scheduled-job and dead-endpoint passes (playbook Step 3) don't apply here — the operational signals for these events live in the **consuming** services' dashboards, not in this repo. (DD_SERVICE_QUERY discovery: no candidate service name exists for sns-events.)

One adjacent observation: the only "automation" this repo owns is its own CI/CD (deploy on master push, npm auto-release). Finding #6 is the relevant gap there.

## Cost
**Negligible direct AWS spend, and no compute to right-size.** The repo provisions only SNS *topics* (no subscriptions, queues, or functions). SNS topic existence is free; cost accrues per-publish ($0.50/M requests) and is driven by the *publishing* services, not this repo. Datadog ingestion: none from this repo (no runtime logs). There is therefore no CPU/memory/Lambda right-sizing lever here. The real "cost" exposure is **operational risk**, not dollars:
- v1 output ceiling (#5) — a failed deploy blocks all event changes in that stack.
- Frozen-timestamp bug (#1) — corrupted event timing can cause expensive downstream reprocessing / data-quality cleanup in consumers.
- No encryption-at-rest (#3) — compliance/audit exposure rather than spend.

AWS-dependent checks (DLQ/SQS/CloudWatch, playbook Step 4) skipped — no creds and nothing for this repo to query (no queues owned here).

## Skipped / caveats
- **`git fetch` failed** (ssh publickey denied at runtime); audited the cached `origin/master` @ `54ec39dd` (2026-06-03). Today's tip may differ.
- **`npm audit` / `npm outdated` could not be run.** `node_modules` is absent and the run had no network. A subagent initially reported a "CRITICAL fast-xml-parser CVE via AWS SDK 3.840→3.1068" — that was **not verifiable** (audit can't run offline) and is **excluded** as a finding. What *is* true: `@aws-sdk/client-sns` is pinned at `^3.840.0` (~mid-2025) and `joi@^17` (v18 exists). **Recommendation: add `npm audit` to CI (#6) and let it report real vulns**; treat dep-freshness as a routine bump, not a confirmed vuln.
- **Datadog / AWS production passes** N/A (no runtime service, no creds) — see Production signals / Cost.
- Findings dropped after adversarial re-check: extension-request `price: Joi.number()` "allows floats" (it has a sibling `currency` field → plausibly major-unit decimal, not cents — not a bug); `getBasicValidators` lazy-singleton "test pollution" (joi validators are immutable — non-issue); hardcoded `us-west-2` region (the `setCustomSnsClient` escape hatch exists).
- Scale note: 286 publishers / 240 topics were sampled, not exhaustively enumerated; orphan-event analysis characterizes the set but a 100%-coverage publisher↔topic diff (worth adding as the test in #4/#5) was not run.
