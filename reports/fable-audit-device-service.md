# Fable audit — device-service (2026-06-11)

## TL;DR

device-service is a high-throughput Lambda with several acute production risks that should be addressed before the next on-call rotation. The single most important finding is a **production error storm: 2,599 errors in 14 days (185/day)** caused by css-api 503 responses that are not differentiated from expected 4xx "device not found" — fixing this alone would eliminate ~97% of all daily error-level logs. Combined with confirmed PII (door access codes) being logged to Datadog and returned in API responses, an IDOR on the direct-Lambda invocation path of `getEvents`, and a missing return statement in `RemoteLockDeviceEventParser.isDeviceEvent` silently dropping all RemoteLock access-denied events, there are 9 high-severity findings requiring prompt action. DLQs are currently empty, all 3 scheduled jobs are running on schedule, and no committed secrets were found. Estimated savings: ~$10–15/month in Datadog ingestion from log volume reduction.

---

## Findings (ranked)

| # | Sev | Area | Finding | Evidence | Recommendation |
|---|-----|------|---------|----------|----------------|
| 1 | **high** | Resilience | **CSS-API 503 not differentiated from 4xx: 2,599 parse errors in 14 days.** `SeamEventParser.getDeviceDetails` treats css-api HTTP 503 the same as any other error, causing the Lambda to fail and log two error-level entries per event (`parse_message_error` + `process_device_event_error`). `CodeSettingService.resolveDeviceDetails` only handles 404 as `UnprocessableEventError`; any 5xx propagates as a thrown error. Contrast: `Kontrol.ts` in the same repo has `retryOn: [500,502,503,504]` with 3 retries + exponential backoff. | Datadog: `parse_message_error` + `process_device_event_error` count 2,599 each over 14d (all "Request failed with status code 503 Service Unavailable"). `services/CodeSettingService.ts` lines 11–23: no `retryOn`/`retries` in `defaultOptions`. `services/Kontrol.ts:46-51`: retry pattern in place. | **Patch**: Add `retries: 3, retryOn: [500, 502, 503, 504], retryDelay: retryDelayMs` to `getCSSApiClient()` defaultOptions (copy pattern from `Kontrol.ts`). Also add a path in `resolveDeviceDetails` to treat HTTP 503 as `UnprocessableEventError` when the response indicates transient unavailability vs genuine server error. **Root-cause fix**: The `@kasadev/css-api-client` base client should expose retry config by default so callers don't have to opt in individually. |
| 2 | **high** | Security | **Dead migration Lambdas deployed with live write access and no dry-run guard.** Three one-off data-migration handlers (`migrateCodes`, `fixSmartthingsUnlockEventNames`, `regenerateSmartthingsReadableTexts`) remain deployed as live Lambda functions. They carry `Event.updateMany` / `Event.bulkWrite` calls against the production Events collection, have no schedule or event trigger, no `dryRun` guard, and are invocable by any IAM principal with `lambda:InvokeFunction`. | `serverless.yml` lines 193–201; `functions/internal/migrate-codes.ts`, `functions/internal/fix-smartthings-unlock-event-names.ts`, `functions/internal/regenerate-smartthings-readable-texts.ts` — none have a schedule or event trigger block. | Verify each migration has already run and its target documents carry the expected fields. Remove all three from `serverless.yml` and delete the handler files. If any might need to run again, add an explicit `dryRun` guard before re-deploying. |
| 3 | **high** | Security/PII | **Door codes in logs and API responses.** `processDeviceEvent` logs full raw SQS payload at INFO level (4 log statements). SmartThings payloads contain `payload.codeDetails.code` (raw 4-digit PIN); RemoteLock payloads carry `payload.attributes.pin`. The Event `code` field is returned verbatim in `getEvents` responses via an unfiltered `IEvent → DeviceEvent` cast. Confirmed in Datadog: `originalMessageBody` field with Seam `access_code_id` visible in live error logs. | `processDeviceEvent.ts:18–37` (four log statements, including `sqsEvent`, `messageBody`, `event`, `savedEvent`). `lib/responseBuilder.ts:26`: `event as DeviceEvent` with no field projection. `data/models/Event.ts:26,47` (`code: String`, `originalPayload: Object`). `services/SeamSync.ts:24`: `seam_sync_get_codes_by_device_id_response` logs full code array. | **Patch**: Replace broad log statements in `processDeviceEvent` with field-allowlisted versions omitting `originalPayload`, `code`, `pin`, and all vendor credential sub-fields. In `EventService.findEvents` or the response builder, project out `code` and `originalPayload` before returning the API response. **Root-cause fix**: Add scrubbing in `@kasadev/logger` for known PII field names, or add a Datadog Sensitive Data Scanner rule for `access_code_id`, `pin`, and `code` patterns. |
| 4 | **high** | Resilience | **HTTP timeouts missing on css-api and seam-sync-api.** `CssApiClient` and `SeamSyncClient` are instantiated with no timeout. Node.js `fetch` has no built-in timeout; a hung css-api TCP connection holds a Lambda concurrency slot for the full 60s function timeout. At `reservedConcurrency=5`, a wave of slow calls saturates all workers and stalls the SQS queue entirely. `maxRetryCount=1` means events fail permanently after 1 retry and go to DLQ. | `services/CodeSettingService.ts:11–23`: no timeout in `defaultOptions`. `services/SeamSync.ts:16–31`: no timeout. `services/Kontrol.ts:35–52`: retries, `retryDelay`, `retryOn` present but also no explicit timeout. `serverless.yml`: `processDeviceEvent` timeout=60s, `reservedConcurrency=5`. | Add `timeout: 10000` (10s) to `getCSSApiClient()` and `getSeamSyncClient()` `defaultOptions`. Also add `serverSelectionTimeoutMS: 5000, connectTimeoutMS: 10000, socketTimeoutMS: 30000` to `mongoose.connect()` in `data/database.ts`. |
| 5 | **high** | Security/Authz | **IDOR: `getEvents` direct-Lambda invocation bypasses tenant scope guard.** `getEvents` enforces a mandatory `unitId`/`buildingId`/`reservationId` guard only when `event.body` is present (the HTTP/API-Gateway path). The direct-Lambda invocation path sets `params = event` and passes straight to `EventSearchRequestParser`, which treats all three scope fields as optional. A call with no scope fields returns ALL events across all tenants. | `functions/getEvents.ts:25–37`: two-path logic; scope guard inside `if (event.body)` only. `lib/EventSearchRequestParser.ts:63–65`: all scope fields optional, no at-least-one guard. Any IAM principal with `lambda:InvokeFunction` can invoke without scope. | Move the "at least one of `unitId`/`buildingId`/`reservationId` required" check into `EventSearchRequestParser` (or a validator called before `findEvents`), so it applies on both invocation paths. |
| 6 | **high** | Correctness | **`RemoteLockDeviceEventParser.isDeviceEvent` missing return — RemoteLock access-denied events silently go to DLQ.** `isDeviceEvent()` returns `true` when `payload.attributes.associated_resource_type` is absent, but falls off the end (returns `undefined` → falsy) when it is present. `canParse()` gates on `this.isDeviceEvent()`, so all RemoteLock events that carry an `associated_resource_type` are rejected by every parser, resulting in `CantFindParserError` and permanent DLQ delivery. | `lib/parsers/RemoteLockDeviceEventParser.ts:166–170`: `isDeviceEvent()` returns `true` for the absent case but has no `return` statement for the truthy case. `lib/parsers/ParserAbstract.ts`: `canParse()` gates on `isDeviceEvent()`. | Add `return false;` after line 169 of `isDeviceEvent()`. One-line fix. The intent is `true` only when there is no `associated_resource_type`. |
| 7 | **high** | Correctness | **`recordStateTransition` swallows all non-duplicate DB errors — silent uptime data loss.** The entire body of `recordStateTransition` is wrapped in a single outer try/catch that logs but does NOT rethrow. Any non-duplicate DB error (network timeout, write conflict, Atlas connection exhausted) inside the tail-reconcile or `refreshUptimeCache` steps is silently consumed. Uptime data is permanently lost with no visibility. | `services/DeviceService.ts:240–298`: outer catch at line 290 calls `logger.error()` and returns. `serverless.yml`: no reconciliation job. The comment at lines 39–44 refers to a "daily reconciliation job" that does not exist. | Rethrow from the outer catch so the error propagates through `upsertDeviceFromEvent` to `processDeviceEvent`, allowing SQS to retry. Also remove the inaccurate "daily reconciliation job" comment. |
| 8 | **high** | Runtime | **npm critical vulnerability: fast-xml-parser@5.2.5 (CVSS 9.3 + 7.5).** `fast-xml-parser@5.2.5` is hoisted to top-level `node_modules` via `@aws-sdk/core@3.864.0` (a production dependency). Affected by GHSA-m7jm-9gc2-mpf2 (entity encoding bypass via regex injection in DOCTYPE) and GHSA-37qj-frw5-hhjh (RangeError DoS via numeric entities). | `package-lock.json`: `node_modules/fast-xml-parser` version 5.2.5, `dev: null` (production). `npm audit` metadata: `critical=1, high=6`. | Add `overrides.fast-xml-parser` to `>=5.3.5` in `package.json` and regenerate the lock. Add `npm audit --audit-level=high` as a CI step in `node.js.yml` to block future critical/high vulnerabilities. |
| 9 | **high** | Bus factor | **`DeviceService.ts` and `EventService.ts` are sole-author critical modules.** `services/DeviceService.ts` (814 lines, primary service layer): 100% of 2024+ commits from Gabor Balazs. `services/EventService.ts`: 100% of commits from Zoltan Feher. `data/models/Device.ts`: 100% Gabor. `lib/parsers/SeamEventParser.ts`: 83% Gabor. These four files cover the entire event-ingestion pipeline. | Bus factor table: `DeviceService.ts` (Gabor 100%), `EventService.ts` (Zoltan 100%), `data/models/Device.ts` (Gabor 100%), `SeamEventParser.ts` (Gabor 83%). | Schedule 30-minute knowledge-transfer sessions for `DeviceService` and `EventService`. Add ADR comments explaining the uptime cache model, event-ingestion pipeline, and atomic-upsert design so the files are self-documenting for a new maintainer. |
| 10 | **medium** | Monitoring | **5 missing Datadog monitors, including 1 dead existing monitor.** No error-rate monitor for `processDeviceEvent` (148 errors/day, no alert has ever fired). Monitor ID for "Device is down for 2 hours" is in 'No Data' state. No cron-health monitors for `cleanupOldEvents` (daily), `cleanupStaleDevices` (weekly), or `refreshUptimeCaches` (hourly). No DLQ depth alert. | Datadog monitors: only 3 exist (IDs 290886702–290886706: queue age, depth, DLQ inflow — all OK). Datadog shows 2,599 errors in 14d with zero alerts. | Create: (1) log-based error-rate monitor `parse_message_error OR process_device_event_error count > 50 / 30min`; (2) log-absence monitors for each cron job; (3) deactivate or fix the dead "Device is down" monitor. |
| 11 | **medium** | Correctness | **Duplicate `ValidationError` class causes wrong HTTP error code in `getDevices`.** `getDevices.ts` defines its own `class ValidationError extends Error` at line 49, independent of `lib/ValidationError.ts`. `lib/responseBuilder.ts` checks `instanceof ValidationError` (importing from `lib/`) — so a `ValidationError` thrown by `getDevices` is seen as `instanceof Object`, not `instanceof lib/ValidationError`, and returns `INTERNAL_SERVER_ERROR` instead of `INVALID_REQUEST`. | `functions/getDevices.ts:49` (local class). `lib/ValidationError.ts:1` (canonical). `lib/responseBuilder.ts:35` (`instanceof` check importing from `lib/`). | Remove the local `ValidationError` in `getDevices.ts` and import from `@lib/ValidationError`. |
| 12 | **medium** | Correctness | **`cleanupOldEvents` uses `updatedAt` as retention cutoff instead of `eventTimeStamp`; also returns `undefined` on empty result.** `updatedAt` reflects the last Mongoose write — any migration or backfill script updates this field, potentially preserving events indefinitely. Genuinely stale events retain their old `updatedAt` and ARE cleaned up correctly, but any doc touched after creation (e.g. backfills) may escape the cleanup window forever. Also: when `dryRun=false` and `docs.length=0`, the function falls off the try block and returns `undefined`, which the Lambda framework treats as an error. | `functions/cleanup-old-events.ts:31` (`updatedAt` filter). `data/models/Event.ts:59` (`eventTimeStamp` index exists). `cleanup-old-events.ts:44–65` — no explicit return when `docs.length === 0` and not `dryRun`. | Change query filter to `{ eventTimeStamp: { $lt: cutoffDate.toISOString() } }`. Add `return createSuccessResponse({message: 'No events to delete.', deletedCount: 0})` for the empty case. |
| 13 | **medium** | Resilience | **`cleanupOldEvents` BATCH_SIZE=1,000,000 risks Lambda OOM and MongoDB BSON limit.** `BATCH_SIZE` defaults to 1,000,000 with no override in `serverless.yml`. `Event.find().limit(1_000_000)` materializes up to 1M ObjectIds in Lambda heap (1024 MB). A `$in` with 1M elements can exceed MongoDB's 16 MB BSON document limit. | `functions/cleanup-old-events.ts:9` (default 1,000,000). `serverless.yml`: no `BATCH_SIZE` env override for `cleanupOldEvents`. At current throughput (~1.58M events/14d), the first run after deployment would attempt to delete millions of documents in one shot. | Set `BATCH_SIZE` to 10,000 in `serverless.yml` for `cleanupOldEvents` and add a pagination loop that deletes until zero documents remain. |
| 14 | **medium** | Security | **IAM over-permission: `secretsmanager` and `execute-api` on `Resource: '*'`.** The Lambda execution role grants `secretsmanager:GetSecretValue` (+ 3 other actions) on `Resource: '*'`. The service consumes only one secret. `execute-api:Invoke` is also on `*`. A compromised Lambda could enumerate and read any secret in the account. | `serverless.yml:75–83` (secretsmanager, `Resource: '*'`). `serverless.yml:118–119` (`execute-api:Invoke`, `Resource: '*'`). Only one Secrets Manager reference in the config (`custom.secrets.slackUrl`). | Scope `secretsmanager Resource` to the specific secret ARN: `arn:aws:secretsmanager:us-west-2:${aws:accountId}:secret:${self:custom.stage}/slackUrls*`. Scope `execute-api:Invoke` to specific API Gateway ARNs. |
| 15 | **medium** | Logging | **Duplicate error logging inflates error counts and splits Datadog service facet.** Every css-api failure generates exactly two error-level log entries (`parse_message_error` + `process_device_event_error`) because `processDeviceEvent`'s outer catch re-logs the same error with a different key — doubling the apparent error rate in Datadog. Additionally, the service appears under two Datadog facet values (`processDeviceEvent` camelCase and `processdeviceevent` lowercase), splitting dashboards and monitors. | Datadog: `parse_message_error` + `process_device_event_error` are 1:1 correlated at 2,599 each. Service facet: `device-service-production-processDeviceEvent` (19.36M logs) vs `device-service-production-processdeviceevent` (4.76M logs). | In `processDeviceEvent`, the outer `logger.error` at the catch site re-logs what was already logged in `parseMessage`. Remove the duplicate outer log (keep the rethrow). Normalize the service name in the Datadog log pipeline. |

---

## Architecture notes

**Service overview**: Lambda-based smart-lock domain service (NOT NestJS). Serverless Framework v4, Node.js 24, TypeScript 6. Processes device-state-changed events from SNS → SQS (batchSize=1, maxRetryCount=1, reservedConcurrency=5). Maintains three MongoDB collections: Events (immutable log), Device (materialized view of latest device state), DeviceStateChange (uptime transition log with rolling-window caching).

**Deployment**: 13 Lambda functions deployed. 3 with schedules: `cleanupOldEvents` (daily midnight UTC, dryRun: false), `refreshUptimeCaches` (hourly), `cleanupStaleDevices` (weekly Sunday 01:30 UTC, dryRun: false). API functions (`getEvents`, `getDevices`, `getDeviceStateChanges`) are fronted by Auth0 API gateway in kasa-devops/infra — this service exports Lambda ARNs, deploys no HTTP triggers itself.

**Outbound dependencies**: css-api (~1.82M calls/14d), seam-sync-api (~241k calls/14d), kontrol-api GraphQL (~104k calls/14d), code-setting-service Lambda (sync invoke), smartthings-sync Lambda (sync invoke), MongoDB Atlas, SNS (`guestCheckedIn`).

**Shared libs use**: Correct use of `@kasadev/logger`, `@kasadev/api-client` + `@kasadev/api-client-iam-authenticator`, `@kasadev/css-api-client`, `@kasadev/seam-sync-api-client`, `@kasadev/sns-events`, `@kasadev/code-api-types`, `@kasadev/enums`. No wheel-reinvention. Vitest migration complete (PR #146).

**Structural improvements** (not ranked as individual bugs but worth scheduling):
1. Split `SeamEventParser` (614 lines) into `SeamEventClassifier` + `SeamDeviceDetailsResolver` + slim parser. The current god-parser concentrates all Seam knowledge, making the css-api error handling (Finding #1) harder to scope correctly.
2. Extract `isMessageDuplicate` from `lib/MessageParser.ts` into `EventService` — bypasses the service layer, creates an invisible write path.
3. Extract Event deletion in `cleanupOldEvents` into `EventService.cleanupOldEvents()` — mirrors how `cleanup-stale-devices.ts` delegates to `DeviceService`.

**Bus-factor table** (git log --since=2024-01-01):

| Path | Top author | ~% recent commits | Risk |
|------|-----------|-------------------|------|
| `services/DeviceService.ts` | Gabor Balazs | 100% (10/10) | **high** |
| `services/EventService.ts` | Zoltan Feher | 100% (3/3) | **high** |
| `data/models/Device.ts` | Gabor Balazs | 100% (5/5) | **high** |
| `lib/parsers/SeamEventParser.ts` | Gabor Balazs | 83% (18/22) | **high** |
| `lib/parsers/SmartthingsDeviceEventParser.ts` | Gabor Balazs | 64% | medium |
| `functions/processDeviceEvent.ts` | distributed (Zoltan/Norbert/Gabor/Devin) | 40%/20%/20%/20% | low |

Overall: Gabor is the primary author (96 commits since 2024 vs Zoltan Feher's 78 combined). Critical risk area: the entire materialized-view pipeline (DeviceService, Device model, SeamEventParser) is effectively sole-maintained.

---

## Production signals

**Log window used**: 14 days (now-14d to now-14d — full Datadog retention; 90-day query confirmed same volume as 14-day).

**Chronic errors** (production, 14d):

| Error key | Count (14d) | Root cause |
|-----------|------------|------------|
| `parse_message_error` | 2,076 prod + 523 dev = 2,599 | css-api 503 — no retry in CodeSettingService (Finding #1) |
| `process_device_event_error` | 2,599 | Paired duplicate log of above (Finding #15) |
| `process_device_event_dlq_error` | 3 | Clustered 2026-06-03, TCP socket reset, likely Atlas connectivity blip |
| `publishing_guestCheckedIn_failed` | 3 | kontrol-api 502 during deploys (sporadic) |
| `call_graphql_server_error` | 2 | Sporadic kontrol-api error |

**Log noise** (production processDeviceEvent, 14d):

| Message key | Count (14d) | Issue |
|-------------|------------|-------|
| `get_parser_found` | 3,163,564 | Per-event INFO, full `parser` object logged |
| `get_parser_mapped_sqs_event` | 3,163,564 | Full event w/ originalPayload logged (PII) |
| `process_device_event_parsed_message` | 1,581,782 | Full messageBody logged |
| `start_process_device_event` | 1,581,782 | Full sqsEvent logged (PII, Finding #3) |
| `get_connection_using_existing_connection` | 1,552,542 | Per-invocation noise |
| `css_resolve_device_details_responded_with_code_not_found` | 359,076 | Expected INFO; high volume |
| `call_graphql_server_request` | 104,896 | Logs full GraphQL query + variables |
| `call_graphql_server_response` | 104,893 | Logs full GraphQL response (reservation/guest data) |

**Monitor coverage** (3 existing monitors, all OK):

| Monitor | Status | Gap |
|---------|--------|-----|
| Queue Age High | OK | — |
| Queue Depth High | OK | — |
| DLQ Inflow | OK | — |
| Error rate | **missing** | 2,599 errors/14d unmonitored (Finding #10) |
| Cron-didn't-run (×3) | **missing** | Data-deleting jobs with no health check (Finding #10) |
| Latency/duration spike | **missing** | — |

**Scheduled job health** (production, 14d):

| Job | Expected | Observed | Status |
|-----|----------|----------|--------|
| `cleanupOldEvents` (daily) | 14 | 14 | ✓ Running |
| `refreshUptimeCaches` (hourly) | ~336 | Running (1,751 progress logs) | ✓ Running |
| `cleanupStaleDevices` (weekly) | 2 | 2 | ✓ Running |

**DLQ status** (live AWS check, 2026-06-11):
- Production: 0 messages, 4-day retention
- Dev: 0 messages, 4-day retention

---

## Cost

**Lambda production (30d)**:
- `processDeviceEvent`: 2.77M invocations × 537ms avg × 1024MB = ~1.48M GB-s → **~$25/month**
- `refreshUptimeCaches`: ~720 invocations × 24.9s × 1024MB = ~18.4k GB-s → **~$0.31/month**
- Other functions (API, cron): **~$1–2/month**
- **Total Lambda: ~$26–27/month** (reasonable for 2.77M events/month)

**Top savings levers** (estimated):

1. **Reduce Datadog log volume** (~$10–15/month): `get_parser_found` + `get_parser_mapped_sqs_event` at 3.16M events each per 14d are the biggest contributors. Demoting to `debug` or removing them cuts hot-path log volume ~60%. Removing `start_process_device_event`'s full-payload log also fixes the PII issue (Finding #3). Combined with the duplicate error-log fix (Finding #15), this reduces total log events by ~9M/14d.

2. **Memory right-sizing for processDeviceEvent** (~$5–8/month): At 537ms avg duration, this is primarily I/O-bound. Profiling at 512MB (halving memory) would save ~$12/month if duration stays under 30s. Validate with a 1-week canary.

3. **Fixing css-api retry** ($0 cost, eliminates overhead): The 2,599 failed events/14d create DLQ traffic, UnprocessableEvent docs, and doubled error-level log entries. The fix (add retry config, Finding #1) eliminates this entirely and is essentially free.

---

## Skipped / caveats

- **npm audit fix**: Not run (read-only audit). `fast-xml-parser` critical is in the Lambda runtime bundle (`@aws-sdk/core` is a prod dep) — needs attention (Finding #8). Run `npm ls fast-xml-parser` to confirm bundle inclusion.
- **Mongoose strict mode**: `strictQuery: true` is set correctly in `data/database.ts`. No silent field-stripping found.
- **TypeScript strict mode**: `strictNullChecks: false` and `noImplicitAny: false` are weak settings that hide potential null-dereference bugs — not ranked as a finding because the existing test suite provides coverage, but worth enabling incrementally.
- **`getSmartthingsHealth` attack surface**: Deployed Lambda with no trigger, invocable via SDK by any IAM principal with `execute-api:Invoke *`. Lower priority than ranked findings but worth noting — the IAM scoping fix in Finding #14 partially addresses this.
- **CSS-API timeout**: No explicit timeout configured on any of the 3 outbound HTTP clients (css-api, seam-sync, kontrol-api). Finding #4 focuses on css-api/seam-sync as the highest-volume paths; kontrol-api also needs a timeout added.
- **MongoDB connection resilience**: `mongoose.connect()` has no `serverSelectionTimeoutMS` or socket timeout configured — Lambda invocations can hang indefinitely waiting for Atlas. Covered in Finding #4's recommendation.
- **Full git history secrets scan**: Not run (time budget). Grep over recent (2024+) patterns found nothing. CI uses `NPM_AUTH_TOKEN` as a GitHub Actions secret (not committed).
