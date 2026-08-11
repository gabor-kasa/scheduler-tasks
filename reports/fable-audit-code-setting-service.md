# Fable audit — code-setting-service (2026-06-18)

> Legacy / migration-status audit. Scope override per task: this repo is the
> Serverless-Lambda predecessor of **css-api** and is being migrated to it
> (`shared-kasa-css-api-migration` skill). Refactor-oriented static findings on
> code slated for deletion are **out of scope**. The report answers: what's
> left, what still takes traffic, chronic errors, cost of keeping it, and
> decommission blockers.

- **Branch audited:** `master` @ `a8dcf466`, tag `v36.0.0`, commit 2026-06-15. Checkout clean, up to date with origin.
- **Companion report:** night-1 `reports/fable-audit-css-api.md` (the receiving side).

## TL;DR

Despite the "legacy" label, code-setting-service is **not dormant — it's the
live execution engine** for lock-code assignment (~7M log events/day; `runJob`
alone is 82% of volume). The css-api migration is **partial**: models, HTTP CRUD
and reservation events are ported, but the entire job-execution spine
(`runJob` + the 5-min scheduler), the code-audit pipeline, the Seam failure
callbacks, and ~15 device-event handlers are **not** — css-api still calls back
into this Lambda to run jobs. So decommission is far off. Two findings need
action now: **(1) an active, unalerted Seam-404 error flood** (42,561 errors on
06-16, still going) caused by an unclassified HTTP 404 that retries forever
(`SeamSync/ProcessorChain.ts:491`), and **(2) STS credentials
(`x-amz-security-token`, signed `authorization` headers) being logged in
plaintext to Datadog** in those same error logs — route both to TechOps. The
biggest cost lever is demoting `runJob`'s per-item INFO spam to debug
(~$130–170/mo Datadog); the bigger structural prize is finishing the migration
so this parallel service can be turned off.

---

## Architecture map

**code-setting-service** is a Serverless Framework (v4) Lambda monorepo on
`nodejs20.x`, region `us-west-2`. It manages smart-lock access codes across
five providers (Remotelock, Seam, SmartThings, Salto, Callbox/Building codes).
Despite the "legacy" label it is the **live execution engine** for code
assignment: ~90 Lambda functions, MongoDB via Mongoose 9, SNS→SQS event fan-in
via `@kasadev/serverless-sns-sqs-lambda`.

**Component groups:**
- `functions/api/` — HTTP endpoints (getCodes, useBackupCode, createManualCode, runJobHttp, search, getAuditLogs, …)
- `functions/events/` — SNS/SQS event handlers (reservation lifecycle, per-provider device events, Seam async-result callbacks)
- `functions/internal/` — scheduled/internal jobs (importFromMongo, checkCodeGroups, cleanup*, codeAudit*, checkLowCodeCount, …)
- `functions/scheduler.js` + `fill-scheduler-queue.js` + `run-job.js` — the **core scheduler**: a cron fills a queue with due CodeJobs, `runJob` executes each
- `lib/` — domain logic (Scheduler/{Universal,Primary,Preset,Backup}Code, devices/CodeService*, reservation event libs)
- `data/mongo/` — Mongoose models (Code, CodeJob, Access, Unit, Building, AuditLog)
- Surprisingly current deps: TS 6.0.3, mongoose 9.7, jest 30, serverless 4.37, modern `@kasadev/*` libs. Recent dep bumps (package.json touched 2026-06-17).

**Bus-factor (commits since 2024-06):** Norbert Pospischek (~254, incl. bot
alias `norbertp-kasa`) and Zoltan Feher (~178) are the two primary maintainers;
dependabot (107), Gabor Balázs (~72), Márk Szávin (13), Kristóf Iváncza (12).
Two strong active maintainers → low single-author risk, but the deep
provider-specific ProcessorChain logic (Seam/Salto/Remotelock) concentrates in
Norbert/Zoltan. Secret scan of the tree: clean (no hardcoded credentials).

**Scheduled jobs (serverless.yml `schedule` events):**

| Job | Cron | Mutates? |
|-----|------|----------|
| `fillSchedulerRunQueue` | `0/5 * * * ?` (every 5 min) + `02 11 ? * 4` (weekly) | enqueues due CodeJobs |
| `scheduler` (deprecated) | `0/5 * * * ?` | legacy, kept for old logs |
| `importFromMongo` | `cron(17 0/4 * * ?)` (every 4h) | yes — upserts units/buildings |
| `checkCodeGroups` | `cron(0 12 ? * 4)` (weekly Wed) | yes |
| `cleanup` | `cron(0 3 * * ?)` (daily 03:00) | yes |
| `codeAuditQueueFiller` | (see Production signals — the Jun-1 incident job) | yes (dryRun-gated) |

---

## Production signals (Datadog)

**Log window used: ~15 days.** Datadog index retention for this service is
~15–16 days — total event counts are identical at 15d / 30d / 90d
(~105.9M) and scale linearly only up to ~16d. The 90-day window in the task
is not available; ~15d is the real retained window.

### What's still receiving traffic (production Lambda log volume, 7 days)

Case-variant service tags merged. This is the single most important section
for the decommission question — **the service is very much alive**:

| Lambda | Events / 7d | Role |
|--------|------------:|------|
| `runJob` | **37.6M** | core CodeJob executor (scheduler dispatches to it) |
| `codeAuditQueueProcessor` | 4.59M | code-audit pipeline (the Jun-1 mass-delete incident handler) |
| `handleSeamFailedAccessMethod` | **1.70M** | Seam async failure callback — abnormally high (see chronic errors) |
| `fillSchedulerRunQueue` | 1.62M | every-5-min scheduler queue filler |
| `handleRemotelockAccessGranted` | 207K | Remotelock access-granted event |
| `codeAuditQueueFiller` | 132K | code-audit fan-out filler |
| `handleSeamAccessMethodIssued` | 29.5K | Seam success callback |
| `runJobHttp` | 21.6K | manual job trigger (HTTP) |
| `handleSeamCodeSetOnDevice` | 18.3K | Seam device-set callback |
| `search` | 15.3K | HTTP search endpoint |
| `handleRemotelockReplaced` | 5.6K | device replace event |
| `getRelatedObjects` / `getAuditLogs` / `getCodes` / `useBackupCode` | 2.5K / 2.4K / 2.4K / 2.0K | HTTP read/backup endpoints |
| `handleExtensionChainBroke`, `handleSeam*`, `handleRemotelock*`, `handleBuildingCode*`, `handleSmartthings*`, `cleanup`, `checkCodeGroups`, `cancelJob` | < 1K each | low-volume but live |

Total ~7M events/day. ~100K `status:error` events over the 15-day window
(~0.1% error rate). _Chronic-error and log-noise detail appended below after analysis._

---

### Chronic errors (15-day window, `status:error`)

`runJob` accounts for ~96% of all errors (it's the executor where every
provider call lands). Top normalized keys:

| Error key | /15d | ~/day | Root cause (file:line) | Monitor? |
|-----------|-----:|------:|------------------------|----------|
| `seam_check_code_failed` — bare HTTP 404 | 74,974 | spiking to 42k/day | `SeamSync/ProcessorChain.ts:491` — unclassified 404, retries (see Finding 1) | ✗ |
| `Lock <X> not found in account <Y>` (SmartThings) | 8,983 | ~600 | `code-audit/smartthings-code-on-lock-provider.ts:40` — lock deleted/config mismatch (business) | ✗ |
| `No available slots found on smartthings lock` | 6,183 | ~412 | downstream smartthings-sync — lock at code capacity (operational) | ✗ |
| `PIN has already been taken` (Remotelock/Salto) | 5,460 | ~364 | `RemotelockSync/ProcessorChain.js:290` — handled (rollback); PIN-space collision | ✗ |
| `salto_lambda_error` | 1,079 | ~72 | `SaltoSync/SaltoSync.ts:54` — no transient/permanent split, all retried | ✗ |
| `internal error … contact administrator` | 534 | ~36 | generic downstream 500 | ✗ |
| `Slot number is missing … removeCode [Dev]` | 313 | ~21 | `SmartthingsSync/ProcessorChain.js:184` — data-integrity bug in job creation | ✗ |

### Log noise / cost (7-day volume)

| Lambda | Events/7d | % | Status mix |
|--------|----------:|--:|-----------|
| `runJob` | 37.6M | 82% | 99.4% INFO |
| `codeAuditQueueProcessor` | 4.59M | 10% | INFO |
| `handleSeamFailedAccessMethod` | 1.70M | 3.7% | 99.95% INFO |
| `fillSchedulerRunQueue` | 1.62M | 3.5% | INFO |

`runJob` logs ~10–15 INFO lines per job (paired `mongodb_find_by_id`/`_found`,
`lambda_call`/`_response`, `run_job`/`run_job_found`/`run_job_response`,
per-item persists). `handleSeamFailedAccessMethod` emits ~8 INFO lines per
message including a full mongo connect→query→disconnect lifecycle per
single-message invocation (~22K real Seam access-method failures/day drive it).

### Monitor coverage

Only **3** monitors reference this service: `Salto user created as SUSPENDED`
(144808922), `Code Setting Service - mongoDB model.save race condition`
(101859523), and a generic `[DLQ] New message` template (85095726, *No Data*).
**No error-rate, no Seam-404, no scheduler-didn't-run, no per-DLQ-depth
monitor.** The 42k/day Seam-404 flood fired completely unalerted.

---

## Findings (ranked)

| # | Sev | Area | Finding | Evidence | Recommendation |
|---|-----|------|---------|----------|----------------|
| 1 | **high** | Active incident | **Seam-404 error flood, ongoing.** A bare HTTP 404 from `client.codes.getCodesByDeviceId` (Seam device deleted server-side) carries no `seamErrorDetails`, escapes every classification branch, and falls through to `logger.error('seam_check_code_failed')` **without `shouldRetry:false`** → scheduler retries on already-`failed` codes until the retry window lapses. | Datadog: `seam_check_code_failed` 06-16=**42,561**, 06-17=**19,912**, 06-18=3,050 (partial), vs ~6-10/day baseline. Code: `lib/devices/SeamSync/ProcessorChain.ts:415,491`; retry default `lib/Scheduler/Errors/SchedulerError.ts:30`, `handleSchedulerError.js:117`. | **Patch (here, now):** in the `catch`, classify a bare HTTP 404 from the device-codes lookup as device-not-found → return `shouldRetry:false`, mark the code, notify TechOps (mirror the `:464` branch). **Root cause:** the checkCode path is *not* ported to css-api — finish that migration and add 404→terminal classification there so the bug isn't recreated. Route the live incident to TechOps. |
| 2 | **high** | Security / PII | **STS credentials logged in plaintext.** The structured `error` attribute of `seam_check_code_failed` (and likely sibling seam error logs) serializes the outbound axios request `config.headers` — including `authorization: AWS4-HMAC-SHA256 …` and a full `x-amz-security-token` (STS session token) — into Datadog at error level. | Datadog raw events (3/3 sampled in last 3d) contain `x-amz-security-token`, `IQoJ…`, `authorization`, `x-amz-date`. Source: error logged at `ProcessorChain.ts:491` includes the seam-sync client's signed request. | **Patch:** strip `authorization`/`x-amz-*` headers (and any `config.headers`) before logging — add a `redactRequestHeaders(error)` in the seam-sync HTTP client error path. STS tokens are short-lived so rotation isn't required, but **confirm with TechOps (Balázs Antal)** and check who/what has Datadog log read access. Structural: a shared `sanitizeAxiosError` used by all provider clients. |
| 3 | **high** | Decommission blocker | **css-api cannot run yet without legacy.** css-api's `runJob()` still does `invokeLambda('code-setting-service', …, 'runJobHttp')` — there is no native job executor, and no scheduler/queue-filler in css-api. The entire job-execution spine lives only here (37.6M log events/7d). | css-api `service/src/utils/run-job.ts` (invokes legacy); legacy `functions/run-job.js`, `functions/fill-scheduler-queue.js` (cron `0/5 * * * ?`). No css-api equivalent. | Port the CodeJob executor (`lib/Scheduler/*`) and the every-5-min scheduler to css-api before any decommission. This is the #1 blocker. |
| 4 | **medium** | Observability | **No alerting on the failure modes that actually fire.** Only 3 monitors touch the service; none cover error-rate, the Seam-404 key, scheduler-didn't-run, or per-queue DLQ depth. | Datadog monitor search (3 results, one *No Data*). | Add: (a) log-alert on `seam_check_code_failed` > 500/h, (b) general `status:error` rate monitor, (c) `fillSchedulerRunQueue` "no invocation in 15m" monitor, (d) real DLQ-depth monitors per queue. Every chronic error above is currently silent. |
| 5 | **medium** | Cost / noise | **runJob INFO spam = ~82% of this service's log volume.** ~10–15 INFO lines/job (paired find/lambda-call/run-job logs). | Datadog: runJob 37.6M/7d, 99.4% INFO. | Demote the per-item paired INFO logs (`mongodb_find_by_id`+`_found`, `lambda_call`+`_response`, `run_job`/`_found`/`_response`) to debug. Est. ~40–48% of total ingestion removed. |
| 6 | **medium** | Cost / efficiency | `handleSeamFailedAccessMethod` opens & tears down a Mongo connection per single-message invocation and logs the full lifecycle (~8 INFO lines × 22K msgs/day = 1.7M/7d). | Datadog status breakdown: 99.95% INFO; `get_connection_connecting`→`successfully_disconnected_from_mongo_db` per invocation. | Reuse a warm Mongo connection; collapse the per-invocation lifecycle logs to debug. Saves ~1.4M events/7d + connection churn. Separately: 22K Seam access-method-creation failures/day is worth a Seam-health look. |
| 7 | **low** | Dual-run risk | Several jobs exist in **both** repos with their own schedules (`cleanup`, `check-code-groups`, `check-low-code-count`, `import-from-mongo`, reservation-event handlers, `code-assignment-at-cut-off`). If both legacy and css-api subscribe to the same SNS topics / run the same cron, events process twice. | Migration map (PORTED rows) + css-api `cdk/config/queues.ts`. Not confirmed live (AWS creds expired). | Before decommission, audit SNS subscriptions + EventBridge rules to ensure exactly one consumer per topic/cron. Verify no double-execution today. |

---

## Migration status (what's left vs ported to css-api)

The migration is **partial and front-loaded on the easy parts** (models, HTTP
CRUD, reservation events, code-service scaffolding). The execution spine and
the long tail of device events remain only in legacy.

**Ported (safe-ish):** Mongoose models; reservation lifecycle event handlers;
`code-assignment-at-cut-off`; `cleanup`, `check-code-groups`,
`check-low-code-count`, `import-from-mongo`; core HTTP CRUD (getCodes,
createManualCode, removeCode, assignCodeToReservation, unitLockCodes); provider
code-service *scaffolding* (`libs/code-services/*`). css-api also adds **new**
ops endpoints (fix-code-duplicates, migrate-salto-locks, migrate-unassigned-seam-codes).

**NOT ported (still only here, high traffic):**
- **runJob executor + scheduler/queue-filler** — the job-execution spine (Finding 3). css-api delegates back via lambda invoke.
- **code-audit pipeline** (`codeAuditQueueFiller`/`Processor`, 4.7M/7d) — no css-api equivalent; this is the lock↔DB reconciliation (and the Jun-1 incident lived here — see the `code-audit-mass-delete-incident` memory).
- **Seam failure callbacks** (`seam-failed-to-{set-code,delete-code,create-access-method}`) — only `seam-access-method-issued` is ported. The Seam checkCode/ProcessorChain *error-classification* logic (Finding 1's bug) is **not** ported.
- **~15 device lifecycle handlers** — Remotelock (incl. `access-granted` 207K/7d), SmartThings, Salto, Callbox, Lockbox, building-code, unit-status install/remove/replace events.
- **SmartThings code-reset Step Function**; several debug/admin HTTP endpoints (getAuditLogs, searchLogs, search, getRelatedObjects, smartthingsLockState, getBackupCodesCount, cancelJob).

(Detailed function-by-function table produced during the audit; the above is
the decision-relevant rollup.)

---

## Cost

AWS creds expired overnight, so Lambda invocation/duration and ECS metrics
weren't pulled — figures below are estimated from Datadog volume + infra defs.

**Datadog ingestion is the dominant, clearly-attributable cost.** ~45.9M log
events/7d ≈ **~197M/month**. At an indexed-log rate of ~$1.70/M events
(15-day retention tier) that's **≈ $300–350/month** in Datadog for this one
service — and ~82% of it is `runJob` INFO spam.

**Lambda:** not directly measured (no CloudWatch). `fillSchedulerRunQueue`
fires every 5 min (8.6k/month); `runJob` fires per due CodeJob at very high
frequency (the 37.6M log lines imply hundreds of thousands of invocations/day).
Likely a meaningful but secondary cost vs Datadog; needs CloudWatch invocation
metrics to size precisely.

**Top savings levers:**

| Lever | Action | Est. saving |
|-------|--------|------------|
| 1. runJob log volume | Demote per-item paired INFO → debug (Finding 5) | ~$130–170/mo Datadog (~40–48% of this service's ingestion) |
| 2. handleSeamFailedAccessMethod | Warm Mongo connection + lifecycle logs → debug (Finding 6) | ~$10–20/mo + fewer Mongo connections |
| 3. Fix Seam-404 retry loop | Finding 1 patch stops the flood | removes ~40k error events/day during incidents |

**The bigger cost story is structural:** keeping a fully parallel legacy
service alive (Lambda + Datadog + maintenance + on-call surface for an
unmonitored 42k/day error flood) until the migration finishes. Decommission is
the real saving — see blockers.

---

## Decommission blockers

Ranked — what must move to css-api before code-setting-service can be turned off:

1. **Job-execution spine** — port `runJob` executor + the every-5-min
   `fillSchedulerRunQueue` scheduler to css-api and remove css-api's
   `invokeLambda('code-setting-service', …)` callback. Nothing runs without this.
2. **code-audit pipeline** (`codeAuditQueueFiller`/`Processor`) — port the
   lock↔DB reconciliation. Carry forward the Jun-1 incident's guard rails
   (dryRun default true, kill switch) — see `code-audit-mass-delete-incident`.
3. **Seam failure callbacks + checkCode error-classification** — port
   `seam-failed-*` handlers and the ProcessorChain logic, fixing Finding 1's
   404 handling in the process (don't reintroduce the bug).
4. **Device lifecycle events** — port the ~15 Remotelock/SmartThings/Salto/
   Callbox/Lockbox/building-code/unit-status handlers (incl.
   `remotelock-access-granted`, 207K/7d).
5. **SmartThings code-reset Step Function** and remaining ops/debug HTTP endpoints.
6. **Cut-over hygiene** — before flipping, audit SNS/EventBridge so exactly one
   consumer owns each topic/cron (avoid the Finding-7 dual-run), add the
   Finding-4 monitors on the css-api side, then dark-run css-api and watch for
   missed events before removing legacy subscriptions.

---

## Skipped / caveats

- **AWS-dependent checks skipped** — SSO token expired overnight (`aws sts get-caller-identity` → "Token has expired"). DLQ depths, CloudWatch Lambda metrics, and live IAM inspection not retrieved. Lambda invocation/duration cost figures are estimated from Datadog log volume, not CloudWatch invocation metrics.
- Datadog window is ~15d (index retention), not the 90d the task requested — stated above.
