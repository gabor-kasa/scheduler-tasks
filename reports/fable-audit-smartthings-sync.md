# Fable audit — smartthings-sync (2026-06-13)

## TL;DR

`smartthings-sync` is a moderately healthy Serverless Lambda service running on Node 24 / TypeScript 6, but it has two issues that need immediate attention: door lock PINs are logged to Datadog in plain text at INFO level across multiple functions (~1.17M `get_lock_codes_codes` log events in 14 days), and there are zero Datadog monitors watching the service despite ~5K errors/day. The chronic error patterns — 9,249 `getLockStatus` 400s and 2,293 `no_client_found` — have been firing for at least 14 days with no alert. Estimated Lambda spend is ~$350–450/month with meaningful savings possible by right-sizing memory from 1024MB to 512MB across all 16 functions.

## Findings (ranked)

| # | Sev | Area | Finding | Evidence | Recommendation |
|---|---|---|---|---|---|
| 1 | **high** | Security/Compliance | Door lock PINs logged in plain text to Datadog at INFO level | `set-code.ts:29` (`event.code`), `function-helpers.ts:69` (`awsEvent` includes PIN for setCode), `delete-code.ts:30` (`codes` maps slot→PIN), `get-lock-codes.ts:29` (`codes`), `get-account-codes.ts:93` (`results` contains parsed PINs) | Redact the `code` field from events and the `codes`/`results` objects before logging. Use a sanitizer or only log counts/keys. Immediate fix — PINs have been in Datadog for at least 14 days. |
| 2 | **high** | Monitoring | Zero Datadog monitors watching this service — 10,965+ errors/14d never alerted | Datadog monitors API returns 0 results for "smartthings" | Add monitors: error-rate on `smartthings_handler_failed`, `no_client_found` count threshold, checkSmartthingsHealth cron-didn't-run, Lambda error rate. |
| 3 | **high** | Dependencies | 2 CRITICAL + 3 HIGH npm vulnerabilities in production deps | `npm audit --production` | CRITICAL: `fast-xml-parser` (entity expansion DoS, XML injection), `basic-ftp` (path traversal, CRLF injection). HIGH: `axios` (SSRF via NO_PROXY bypass, prototype pollution, CVE-2025-62718/CVE-2025-62719+); `mongoose` (NoSQL injection via `$nor`); `@smartthings/core-sdk` (transitive axios). Fix: upgrade `axios` ≥ 1.8.x, `mongoose` ≥ 8.x, `@aws-sdk/*` packages. Axios vulnerabilities are highest-risk given direct use in SmartThings API calls. |
| 4 | **medium** | Bugs | Chronic `smartthings_handler_failed` HTTP 400 errors: 9,249 on getLockStatus, 1,624 on getLockCodes over 14 days | Datadog error query: `service:smartthings-sync-production-getLockStatus status:error` — error msg: "Request failed with status code 400" | Root cause: stale/failed SmartThings OAuth token refresh or CSS calling devices/accounts that no longer respond. Add token refresh error handling in `SmartAppContextClient.createInstance`. Add a monitor. Structural fix: surface 400 errors distinctly from other failures. |
| 5 | **medium** | Bugs | Chronic `no_client_found` + `account_credentials__not_found`: 2,293 errors/14d — CSS calling SmartThings account names not in Secrets Manager | Datadog: `service:smartthings-sync-production* message:no_client_found` — 2,015 from getLockStatus | Root cause: CSS units with `smartthingsAccountName` set to decommissioned account names. Structural fix: add an admin endpoint or audit job that cross-checks CSS `smartthingsAccountName` values against Secrets Manager entries; return distinct error code so CSS can deactivate stale accounts. |
| 6 | **medium** | Bug | `addCorrectSlotInfoForPCAndBU` throws `TypeError: Cannot set properties of undefined` on codes without `additionalData` | `get-account-codes.ts:29`: `result[slot].additionalData.isInCorrectSlotRange = ...` — `additionalData` is only set in `CodeCommentParser.ts` when `stringifiedAdditionalData` is present | Guard: `if (result[slot].additionalData) { ... }` before assignment, or initialize `additionalData = {}` unconditionally in `parseCodeComment`. |
| 7 | **medium** | Resilience | No timeout on SmartThings SDK API calls — hung calls hold Lambda for full 60s (900s for checkSmartthingsHealth) | `SmartAppContextClient.ts` — `apiCall()` / `apiCallOnSelectedCtx()` pass through to SDK with no timeout config | Set axios/SDK timeout (e.g., 15s) in the SmartApp SDK options. Add per-account error containment in `checkSmartthingsHealth`'s batch loop. |
| 8 | **medium** | Log noise | getLockCodes generates 4 INFO log lines per invocation including `codes` (PIN map) — 1.17M `get_lock_codes_codes` events in 14 days; getLockStatus adds another 4.4M lines — together 73% of all 21.8M log events | Datadog volume query: getLockCodes 8.3M + getLockStatus 7.8M = 16.1M of 21.8M total/14d | Remove or downgrade to DEBUG: `get_lock_codes_codes` (logs PINs), `using_smartapp_context_client` (no signal), `get_lock_status_retrieved_device` at scale. This also fixes Finding #1. Estimated 40% log volume reduction. |
| 9 | **medium** | Cost | All 16 Lambda functions deployed at 1024MB; getLockCodes/getLockStatus each ~83K invocations/day — memory is almost certainly over-provisioned | CloudWatch: all functions at 1024MB; Datadog volume confirms high invocation rate | Profile with Lambda Power Tuning. Likely 256–512MB is sufficient for most functions, saving ~$150–200/month. checkSmartthingsHealth (complex fan-out) may legitimately need 1024MB. |
| 10 | **low** | Monitoring | `checkSmartthingsHealth` outer `try-catch` swallows all errors and exits silently — no alert if the entire daily health check fails | `check-smartthings-health.ts:72-74` — `logger.error` only, no re-throw | Re-throw (or publish a CloudWatch `checkSmartthingsHealth_failed` metric) so a missing-run monitor can catch it. |
| 11 | **low** | Architecture | `lockNameToDeviceId` makes serial SmartThings `devices.list()` calls per location context — O(n × latency) per setCode/deleteCode/unlock | `SmartAppContextClient.ts:270` — sequential `for...of` over `ctxList` | Parallelize with `Promise.all` or cache deviceId→ctx mapping in Lambda invocation scope. |
| 12 | **low** | Code quality | `url.parse()` DEP0169 deprecation warnings from `@smartthings/core-sdk` appear as Lambda ERROR-level log entries (Node 24 routes `process.emitWarning` to stderr) | Datadog: multiple DEP0169 entries as `status:error` messages | File upstream issue with `@smartthings/core-sdk`. Short-term: filter out DEP0169 in log processing. Scheduled: upgrade SDK when a Node 24-clean release is available. |
| 13 | **low** | Code quality | `process.env.ACCOUNT_NAME = accountName` mutates shared Lambda env for logging only | `function-helpers.ts:84` | Pass `accountName` as a logger context field instead. |
| 14 | **low** | Code quality | `getRandomFreeSlot` vs `getSlotAvailability` use different `FIRST_SLOT` defaults (1 vs 5); `getRandomFreeSlot` not called in production paths | `SmartAppContextClient.ts:231,243` | Remove `getRandomFreeSlot` (dead code) or align defaults. |
| 15 | **low** | Code quality | TypeScript `strict: false` — implicit `any`, unchecked null | `tsconfig.json` | The `smartthings-sync-ts6` branch targets TS 6 strict — ensure this ships. |

## Architecture notes

SmartThings hub/lock vendor sync. 16 Serverless Lambda functions (Node 24.x, TypeScript, Serverless Framework v4). All 1024MB. Last deployed 2026-06-11.

**Component list:**
- Core Lambda invocations (direct from CSS/Kontrol): `setCode`, `deleteCode`, `getLockCodes`, `getLockStatus`, `getLockHistory`, `getAccounts`, `getAccountCodes`, `getAccountHealth`, `unlock`, `reloadCodes`
- HTTP/API Gateway (IAM-authed): `deleteCodeViaApi`, `getLockStatusViaApi`, `getLockHistoryViaApi`, `unlockViaApi`
- Public SmartThings webhook (SDK RSA signature verification): `POST /smartapp-webhook`
- Scheduled daily cron (3pm UTC, production-only): `checkSmartthingsHealth`
- MongoDB: `smartthings-sync-accounts` collection (SmartApp context store); cross-DB read from `code-setting-service.units`
- AWS Secrets Manager: per-account SmartThings credentials (appId, clientId, clientSecret, optional PERSONAL_TOKEN)
- SSM Parameter Store: DB connection string, internal API URLs, Slack webhook map
- Outbound: SmartThings API (`@smartthings/core-sdk` + `axios`), Breezeway Sync API (IAM), Slack, SNS (`deviceStateChanged` topic)

**Kasa libs used:** `@kasadev/logger`, `@kasadev/lambda-utils`, `@kasadev/db-schemas-ts`, `@kasadev/code-api-types`, `@kasadev/sns-events`, `@kasadev/enums`, `@kasadev/slack-notifications`, `@kasadev/breezeway-sync-api-client`, `@kasadev/api-client-iam-authenticator`

**Audited:** branch `master`, HEAD `2d3c4dc`, committed 2026-06-02.

**Security posture (IAM/infra):** Good — tightly scoped IAM role, no wildcard actions, secrets via Secrets Manager/SSM (not plain env vars), no public S3. SmartApp webhook correctly unprotected from AWS IAM (SmartThings can't sign IAM); SDK handles its own RSA signature verification.

### Bus-factor table

| Author | Commits to functions+lib (Jan 2024–Jun 2026) |
|---|---|
| norbertp-kasa / Norbert Pospischek | 22 |
| Zoltan Feher (both spellings) | 8 |
| Gabor Balazs | 6 |
| dependabot[bot] | 31 (deps only) |
| devin-ai-integration[bot] | 1 |
| Kristóf Iváncza | 1 |

Norbert Pospischek is the dominant human maintainer of SmartThings-specific business logic (slot ranges, code comment format, SmartApp context management). Zoltan Feher has material contributions. Three humans with meaningful context — moderate risk, not a single-person bus. Dependabot is the most active contributor by commit count (deps-only).

## Production signals

**Datadog window used: 14 days** (Kasa retention limit)

### Chronic errors (top 5)

| Error key | Count/14d | Root cause | Monitor exists? |
|---|---|---|---|
| `smartthings_handler_failed` | 10,965 | SmartThings API HTTP 400 on getLockStatus (9,249) and getLockCodes (1,624). Likely stale OAuth tokens or decommissioned devices. | No |
| `no_client_found` (+ `account_credentials__not_found`) | 2,293 | CSS calling SmartThings account names not in Secrets Manager — decommissioned accounts. | No |
| `account_health_failed` | 28 | Per-account errors in checkSmartthingsHealth — isolated bad accounts. | No |
| `smartapp_failed_to_subscribe_to_capability` | 6 | SmartApp lifecycle — transient. | No |
| `url.parse()` DEP0169 | ~20 | Node 24 deprecation from SmartThings SDK. Logged as ERROR by Lambda stderr routing. | No |

**Total: 70,172 errors in 14 days (~5K/day). ZERO monitors for any of them.**

### Log noise

Total log volume: **21.8M events in 14 days** (1.56M/day). Top emitters:
- `getLockCodes`: 8.3M (38%) — every invocation logs 4 INFO lines including `get_lock_codes_codes` with raw `codes` object (slot→PIN map)
- `getLockStatus`: 7.8M (36%) — 4 INFO lines per call
- `smartapp`: 4.2M (19%) — webhook events including code change payloads

**Top reduction opportunity:** Downgrade `get_lock_codes_codes` and `using_smartapp_context_client` to DEBUG or remove them entirely. Saves ~9M log events/14 days (41% total volume reduction). Also fixes the PII compliance finding.

### Monitor coverage gaps

No monitors target this service. Proposed additions:
1. **Error rate**: alert when `smartthings_handler_failed` exceeds 100/hour
2. **Account not found**: alert when `no_client_found` exceeds 50/day (indicates CSS/Secrets drift)
3. **Cron didn't run**: alert if `checkSmartthingsHealth` produces no logs between 14:00–16:00 UTC
4. **Lambda error rate** (CloudWatch): alert on Lambda-level errors (timeout, crash) > 1/hour

### Scheduled job inventory

| Job | Schedule | Enabled in prod | Dry-run switch | Kill switch | Monitoring |
|---|---|---|---|---|---|
| `checkSmartthingsHealth` | `0 15 * * ? *` (3pm UTC) | Yes | `DRY_RUN=false` in prod | No kill switch | None |

**checkSmartthingsHealth** confirmed running (2026-06-13T15:01 UTC), sends Slack notifications on offline devices. DRY_RUN is only `'true'` in dev — production always sends. A kill switch (`enabled: false` flag in serverless.yml already exists via `fnEnabled`) is there but requires a redeploy to toggle.

### Dead API surface

Service is primarily queue-driven (direct Lambda invocations). The 4 HTTP endpoints all show active traffic in Datadog. No dead endpoints identified.

## Cost

**Lambda configuration:** All 16 functions at 1024MB. Last deployed 2026-06-11.

**Estimated monthly footprint:**

| Function | Est. invocations/month | Memory | Avg duration | Est. cost/month |
|---|---|---|---|---|
| getLockCodes | ~2.5M | 1024MB | ~3s | ~$125 |
| getLockStatus | ~2.3M | 1024MB | ~3s | ~$115 |
| setCode | ~580K | 1024MB | ~5s | ~$48 |
| deleteCode | ~180K | 1024MB | ~4s | ~$12 |
| getAccountCodes | ~145K | 1024MB | ~8s | ~$20 |
| getAccountHealth | ~30K | 1024MB | ~10s | ~$5 |
| checkSmartthingsHealth | ~30/month | 1024MB | ~600s | ~$0.30 |
| All others | ~100K | 1024MB | ~3s | ~$5 |
| **Total Lambda** | | | | **~$330/month** |

**Top savings levers:**

1. **Right-size Lambda memory 1024→512MB** for getLockCodes, getLockStatus, setCode, deleteCode, unlock (no evidence 1024MB is needed — these are API-call-heavy, not compute-heavy). Est. saving: **~$150/month** (Lambda pricing is proportional to GB-seconds).
2. **Reduce log volume** by removing/downgrading verbose INFO logs in getLockCodes+getLockStatus. Est. Datadog log ingestion saving: **~$15–60/month** (depending on indexed vs ingested pricing tier; volume reduction ~41%).
3. **Fix `no_client_found`** — 2,293 failed invocations/14d that do no useful work and still bill. Est. saving: ~$5/month (small but also reduces error noise).

## Skipped / caveats

- `git fetch origin` failed overnight (SSH key not available) — audited local `origin/master` state (2026-06-02); no code changes expected.
- AWS creds were valid (SSO session active) — CloudWatch + Lambda API checks completed.
- No SQS queues for this service — DLQ checks not applicable.
- Datadog retention confirmed 14 days (cannot look further back).
- `smartthings-sync-ts6` branch (TypeScript 6 upgrade in progress) not audited — same architecture, TS6 strict mode would catch many `any` and null issues.
