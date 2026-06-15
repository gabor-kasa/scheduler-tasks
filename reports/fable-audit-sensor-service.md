# Fable audit — sensor-service (2026-06-12)

## Audit metadata

- **Branch audited:** origin/master (detached HEAD)
- **HEAD SHA:** bb76840b4faaeaf253c55bce975b9f687eb22f28
- **Commit date:** 2026-06-05
- **Local checkout state:** on feature branch `chore/HSP-3697-remove-tamper-flag`; audited via temp worktree of origin/master at `/tmp/fable-audit-sensor-service`
- **Datadog window:** 14 days (max retention)
- **AWS creds:** valid (PowerUser SSO)

---

## TL;DR

`sensor-service` is a moderately healthy Serverless Lambda service managing Minut sensor events, SmartThings device sync, and noise/smoke alert pipelines. The single most urgent finding is a **critical security/compliance issue**: `libs/lambdaUtils.ts` logs the full `getLockCodes` Lambda response — including all active door access codes for every SmartThings unit — to Datadog on every invocation of `smartThingsReport` (~9.3M log events/month). The second critical gap is the **lack of any Datadog monitors**; `syncMinutInfo` has been failing 11 times over 14 days with no alert firing. A related bug is that the Minut API OAuth token is cached indefinitely at module level and never refreshed, which periodically causes the entire Minut sync pipeline to fail until a Lambda container recycles. Fixing the logging issue alone saves ~$93/month in Datadog ingestion and eliminates a live door-code exposure.

---

## Findings (ranked)

| # | Sev | Area | Finding | Evidence | Recommendation |
|---|-----|------|---------|----------|----------------|
| 1 | **high** | Security / PII | **Door access codes logged to Datadog.** `libs/lambdaUtils.ts` logs `lambda_call_response` with the full Lambda response payload. `smartThingsReport` calls `getLockCodes` per unit; the response contains all active door codes (PC/BU/HK types). Confirmed in production: real codes present in Datadog. | `libs/lambdaUtils.ts:25` (`logger.info('lambda_call_response', { ..., response })`); confirmed in DD logs for `service:sensor-service-production-smartThingsReport message:lambda_call_response` | **Patch:** In `lambdaUtils.ts`, log response only on error — not on success — or at minimum strip the `response` field from success logs. **Fix:** Move to structured Lambda invocation that returns a typed response without echoing the full payload to logs; use `logger.debug` (which Datadog doesn't ingest at production log level) for success traces. |
| 2 | **high** | Security | **No authentication on Minut webhook endpoint.** `POST /minut-events` (`functions/minut-events.ts`) has no authorizer in serverless.yml and does not verify Minut webhook signatures (HMAC-SHA1 that Minut provides). Anyone who discovers the endpoint URL can send fake noise/smoke/tamper events, triggering real guest notifications and Step Function executions. | `serverless.yml:214-218` (`http: method: POST, path: /minut-events` — no authorizer); `functions/minut-events.ts` has no signature check | **Patch:** Add Minut webhook HMAC-SHA1 signature verification (Minut sends `X-Minut-Signature` header). **Fix:** Add a custom Lambda authorizer in serverless.yml or verify the header inline at handler entry; reject and return 403 on mismatch. |
| 3 | **high** | Resilience | **Minut OAuth token never refreshed — cached until container recycle.** `libs/minutClient.ts`: `minutClient` (Axios with Bearer token) is created once at module level. Minut `client_credentials` tokens expire (typically 1 hour). After expiry, `syncMinutInfo` (every 30 min), device lifecycle handlers, and `minutNamesReport` all fail with 401 until the container is replaced. Confirmed in production: 11 `sync_minut_error` events in 14 days, all from transient 502/504 — a stale token would look identical. | `libs/minutClient.ts:24-27` (module-level `let minutClient: AxiosInstance`), `libs/minutClient.ts:117-139` (`getClient()` short-circuits if already set) | **Patch:** Add a token expiry timestamp; re-fetch if `Date.now() > tokenExpiry - 5min`. **Fix:** Use an Axios request interceptor that catches 401s and refreshes the token before retrying. |
| 4 | **high** | Observability | **Zero Datadog monitors for sensor-service.** No monitors exist (confirmed via API tag search). `syncMinutInfo` has been failing 11 times in 14 days with no alert. The noiseBreach DLQ is not monitored. There is no cron-didn't-run alert for the hourly Minut sync or daily names report. | Datadog monitor API returned `[]` for `tags=service:sensor-service`; `sync_minut_error` count = 11 in 14 days | **Fix:** Create at minimum: (1) error-rate alert on `service:sensor-service-production-syncMinutInfo status:error` > 2 in 15 min; (2) noiseBreach DLQ awareness monitor (`> 1 message`); (3) cron-didn't-run alert (invocation count drops to 0 in 45 min window for syncMinutInfo). |
| 5 | **high** | Security / PII | **Guest PII (name, email, phone) logged at INFO level on every alert event.** `utils/alerts/query-helpers.ts:getActiveReservationByUnitAndDate` calls `logger.info('found_reservations', { ..., reservations })` with the full populated reservation array including `guest.email`, `guest.phone`, `guest.firstName`, `guest.lastName`. Every noise and smoke alert event flows through this path. | `utils/alerts/query-helpers.ts:56` (`logger.info('found_reservations', { count: reservations.length, query, reservations })`) | **Patch:** Replace with `logger.info('found_reservations', { count: reservations.length })` — strip the `reservations` array entirely. **Fix:** Audit all `logger.*` calls for PII; establish a lint rule against logging Mongoose documents directly. |
| 6 | **medium** | Resilience | **No timeout on outbound Minut API calls.** `libs/minutClient.ts` creates an Axios instance with no `timeout` option (defaults to 0 = no timeout). If Minut API hangs, `syncMinutInfo` (300s Lambda timeout) and `minutNamesReport` (300s) block for the full timeout, burning compute and blocking any concurrent execution. Confirmed: `syncMinutInfo` `max_ms = 300,000ms` (hitting full timeout). | `libs/minutClient.ts:6` — no `timeout` in `axios.create()`; CloudWatch: `syncMinutInfo` max duration = 300,000ms | **Patch:** Add `timeout: 30000` (30s) to the Axios instance. **Fix:** Add a retry interceptor with exponential backoff for 5xx/network errors (max 3 attempts). |
| 7 | **medium** | Bug | **Module-level timestamp in SmartThings reporter — `lastStatusUpdate` is frozen at container startup.** `smartThingsStatusReporter.ts:14`: `const timestamp = moment()` executes at module load, not per invocation. All SmartThings device `lastStatusUpdate` values written to MongoDB reflect the Lambda container creation time, not the actual check time. On a warm container (reused across 30-minute invocations), this can be hours stale. | `functions/smartThingsStatusReporter.ts:14` (`const timestamp = moment()` at module scope) | **Patch:** Move `const timestamp = moment()` inside the `handler` function body. |
| 8 | **medium** | Bug | **Webhook handler errors logged at INFO, not ERROR.** `minut-events.ts` catch block uses `logger.info('error', { err })` instead of `logger.error()`. Real production failures (DB unreachable, SNS publish failures, parse errors on Minut payloads) are invisible to Datadog error tracking and won't appear in error-rate monitors. | `functions/minut-events.ts:41` (`logger.info('error', { err })` inside catch block) | **Patch:** Change to `logger.error('minut_event_handler_error', { err })`. |
| 9 | **medium** | Architecture | **`resetMinutDevices` logic is dead — commented out but scaffolding remains.** `libs/minutService.ts:syncMinutDevice` computes `needsReset`, logs it, but the actual `await resetMinutDevices(...)` call is commented out. Devices with incorrect sound thresholds are detected but never corrected. The detection logic runs on every sync (overhead without effect). | `libs/minutService.ts` — last lines of `syncMinutDevice`, commented-out `resetMinutDevices` call | **Decision needed:** Either remove the dead detection logic entirely, or re-enable the reset (it was presumably disabled intentionally — add a comment explaining why). |
| 10 | **medium** | Architecture | **Duplicate `getUnitByInternalTitle` implementations.** `libs/unitRepository.ts` and `utils/alerts/query-helpers.ts` both define `getUnitByInternalTitle` with different signatures and different default behaviors (lean mode, select fields, populate). A bug fixed in one won't propagate to the other. | `libs/unitRepository.ts:27` vs `utils/alerts/query-helpers.ts:68` | **Fix:** Consolidate into `libs/unitRepository.ts`; make `utils/alerts/query-helpers.ts` import from there. |
| 11 | **medium** | Security | **Wildcard `execute-api:Invoke` IAM permission.** The Lambda execution role grants `execute-api:Invoke` on `Resource: '*'` — any API Gateway endpoint in the account. Should be scoped to the specific ARN(s) of the segment-sync and smartthings-sync APIs. | `serverless.yml:79-80` | **Fix:** Replace `Resource: '*'` with the specific execute-api ARNs for segment-sync and any other called gateways. |
| 12 | **medium** | Observability | **Smoke alert follow-up uses a fixed 6-minute time window with no tolerance.** `smokeAlertFollowUp.ts` queries events from 33 to 27 minutes ago — exactly a 6-minute window. If the Lambda fires late (cold start, throttling), events can fall outside this window and the follow-up is silently skipped. | `functions/alerts/smoke/smokeAlertFollowUp.ts:32-36` | **Fix:** Expand the look-back window to 33–23 minutes (10-minute buffer), or track "last processed timestamp" in a persistent store rather than relying on fixed wall-clock offsets. |
| 13 | **medium** | Bug | **Noise final warning saves with wrong event type.** `noiseFinalWarning.ts` uses `EVENT_TYPE = 'noise.alert.warning'` — identical to the regular `noiseWarning.ts`. The GX escalation is indistinguishable from a routine guest warning in `GuestReservationEvent`. | `functions/alerts/noise/state-machine/noiseFinalWarning.ts:6` | **Fix:** Change to `'noise.alert.final_warning'` or `'noise.alert.gx_escalation'`. |
| 14 | **low** | Architecture | **`minutReplaced.ts` logs at module scope (cold start noise).** `logger.info('new_minutReplaced_event_begin')` fires on every Lambda cold start, not per handler invocation. | `functions/minutReplaced.ts:1` | **Patch:** Move inside the `handler` function. |
| 15 | **low** | Deps | **`npm audit` reports 47 vulnerabilities** (2 critical in `fast-xml-parser` via `@aws-sdk`, 8 high — all in devDependencies or transitive serverless framework deps; no prod-dep critical vulns). Jest/node-notifier chain accounts for the bulk. | `npm audit` output | **Fix:** `npm audit fix` resolves most. The `fast-xml-parser` issue requires an `@aws-sdk/*` upgrade — check if the bundled serverless deps can be updated. Consider migrating Jest → Vitest (aligns with direction elsewhere in Kasa). |

---

## Architecture notes

### What it does

`sensor-service` is a **Serverless Framework v4 / AWS Lambda** service that bridges Kasa's physical sensor ecosystem (primarily Minut noise/smoke devices) to the rest of the Kasa platform. It:

1. **Receives Minut webhook events** (`POST /minut-events`) — parses noise-breach, tamper, smoke, and alarm events; persists them as `SensorEvent` documents; publishes them to SNS topics consumed by downstream services.
2. **Syncs Minut device state** (`syncMinutInfo` — cron every 30 min) — paginated fetch of all Minut homes/devices, upserts `Device` documents in MongoDB, resets device config if sound-level threshold is wrong (though the reset is currently commented out).
3. **Handles device lifecycle SNS events** — `minutAdded`, `minutRemoved`, `minutReplaced` manage the Minut ↔ Kasa unit association.
4. **Runs noise-alert Step Function pipeline** — `noiseBreach` SNS-SQS triggers a Step Functions state machine that sends up to 3 escalating warnings (6-minute grace periods); `noiseBreachEnded` and `noiseAlarmDetected` cancel it.
5. **Smoke alert pipeline** — `smokeAlert` SNS triggers immediate GX email; `smokeAlertFollowUp` re-checks unresolved smoke alerts every 6 minutes.
6. **SmartThings reporting** — `smartThingsReport` cron (every 30 min) syncs SmartThings cloud state to the `Devices` collection; parallelism: 50 units at once.
7. **Minut names health report** — daily cron posts Slack report to `#data-integrity-notifications` comparing Minut sensor names to Kasa `internalTitle`s.

### Component list

| Component | Detail |
|-----------|--------|
| Runtime | Node.js 24.x on AWS Lambda |
| Framework | Serverless Framework v4 |
| Orchestration | AWS Step Functions (noise alert state machine) |
| Messaging | SNS (publish/subscribe) + SQS (noiseBreach queue, DLQ) |
| Datastores | MongoDB (`Device`, `SensorEvent`, `MinutReportIgnoreList` collections); AWS SSM Parameter Store |
| External APIs | Minut API v8 (`api.minut.com`), SmartThings (via Lambda invoke to `smartthings-sync`) |
| Shared Kasa libs | `@kasadev/api-client`, `@kasadev/api-client-iam-authenticator`, `@kasadev/db-schemas`, `@kasadev/db-schemas-ts`, `@kasadev/enums`, `@kasadev/lambda-utils`, `@kasadev/logger`, `@kasadev/messaging`, `@kasadev/slack-notifications`, `@kasadev/sns-events`, `@kasadev/kontrol-api-client`, `@kasadev/code-api-types` |
| HTTP surface | `POST /minut-events` — Minut webhook receiver (edge CloudFront, no auth) |

### Bus-factor table (last 2 years)

| Author | Commits (all files) | Notable areas |
|--------|---------------------|---------------|
| norbertp-kasa (Norbert Pospischek) | 35 | libs/ (minutClient, minutService, unitRepository), functions/ |
| Gabor Balazs | 20 | utils/alerts/, functions/alerts/, governance |
| Zoltan Feher | 13 | functions/, libs/ |
| Kristóf Iváncza | 1 | — |
| Elliott Lui | 1 | — |

**Risk area:** `libs/minutClient.ts` and `libs/minutService.ts` (core Minut integration, most complex code) are effectively single-author (norbertp-kasa). If Norbert is unavailable, the Minut sync pipeline has no backup maintainer.

---

## Production signals

### Chronic errors (14-day window)

| Error | Function | Count (14d) | Root cause | Already monitored? |
|-------|----------|-------------|------------|-------------------|
| `sync_minut_error` (AxiosError 502) | syncMinutInfo | 8 | Minut API gateway returning 502 — transient upstream error, no retry logic | **No** |
| `sync_minut_error` (AxiosError 504) | syncMinutInfo | 3 | Minut API gateway timeout — no HTTP timeout set, Lambda hits 300s limit | **No** |
| `error_sending_minut_device_name_mismatch_report` | minutNamesReport | 1 | SSM parameter fetch for Slack webhook URL likely failing intermittently | **No** |

### Log noise summary

| Function | 14-day events | Top messages by volume |
|----------|--------------|----------------------|
| smartThingsReport | 7,602,706 | `lambda_call_response` (2.17M), `lambda_call` (2.17M), `smartthings_status_reporter_checking_unit` (1.09M) |
| syncMinutInfo | 2,341,472 | Per-device sync logs |
| postMinutEvents | ~128,000 | Normal event processing |
| Alert pipeline (all) | ~37,000 | Normal |

**Top log reduction opportunity:** Eliminating success-path `lambda_call` + `lambda_call_response` logs from `libs/lambdaUtils.ts` removes ~9.3M events/month (~$93/month at Datadog standard pricing) and closes the door-code exposure simultaneously.

### Monitor coverage gaps

| Failure mode | Monitor? | Proposed monitor |
|-------------|---------|-----------------|
| syncMinutInfo errors | **None** | Log alert: `service:sensor-service-production-syncMinutInfo status:error > 2 / 15m` |
| noiseBreach DLQ depth | **None** | SQS metric alert: `noiseBreachDeadLetterQueue messages > 1` |
| syncMinutInfo cron not running | **None** | Metric alert: Lambda invocation count drops to 0 over 45 min |
| smokeAlert pipeline errors | **None** | Log alert on `service:sensor-service-production-smokeAlert* status:error > 1 / 15m` |
| Minut auth failures | **None** | Log alert: `sync_minut_error` AND `401` in error stack |

### Scheduled job inventory

| Job | Cron | Enabled (prod) | Dry-run / kill switch | Observed running? |
|-----|------|---------------|----------------------|------------------|
| syncMinutInfo | Every 30 min | Yes | None | Yes (1,438 runs/30d) |
| smartThingsReport | Every 30 min | Yes | None | Yes (1,436 runs/30d) |
| minutNamesReport | Daily 15:00 UTC | Yes | None | Yes |
| smokeAlertFollowUp | Every 6 min | Yes | None | Yes |

All scheduled jobs mutate data (DB writes or Minut API calls) with no dry-run mode and no kill switch. Each is a medium-risk finding on the "forgotten automation" rubric regardless of current behavior.

### Dead API surface

Not applicable — `POST /minut-events` is active (~128K calls/14d).

---

## Cost

### Lambda compute (~$5/month total)

| Function | Invocations/month | Avg duration | Memory | GB-s/month | $/month |
|----------|------------------|-------------|--------|-----------|--------|
| syncMinutInfo | ~1,438 | 84.4s | 1GB | 121,307 | $2.02 |
| smartThingsReport | ~1,436 | 85.4s | 1GB | 122,594 | $2.04 |
| postMinutEvents | ~23,127 | <1s est. | 1GB | ~23,127 | $0.39 |
| Others | small | — | 1GB | — | <$0.50 |

**Note:** Both heavy cron functions hit 1024 MB but Lambda Insights is disabled (`defaultLambdaInsights: false`). Actual memory utilization is unknown; there may be headroom to reduce to 512 MB if testing confirms it.

### Datadog log ingestion (~$216/month estimated)

21.6M events/month × ~$0.10/million = **~$216/month** from sensor-service alone.

### Top 3 savings levers

1. **Remove success-path logs from `libs/lambdaUtils.ts`** (log only on error) → −9.3M events/month → **~$93/month** + eliminates door-code exposure.
2. **Reduce `smartThingsReport` per-unit verbose INFO logs** (emit per-batch summary only) → −2.1M events/month → **~$21/month**.
3. **Reduce `syncMinutInfo` per-device verbose logging** → −2.5M events/month → **~$25/month**.

Total achievable: **~$139/month** from logging alone.

---

## Skipped / caveats

- **`minutUpdate` Lambda** referenced in `serverless.yml` env var (`MINUT_UPDATE_LAMBDA`) is not defined in the `functions:` block — appears to be a stale reference. Not investigated further.
- **SmartThings Lambda memory utilization**: Lambda Insights disabled; exact memory headroom unknown without enabling it or CloudWatch memory metrics.
- **Minut API history**: 14-day log window only; cannot determine if token-expiry 401s have historically caused incidents (would look identical to transient 502 in the error log).
- **`netamoSchedule`** in `fnSourceEnabled` refers to a Netatmo schedule that doesn't exist in the `functions:` block — appears to be a dead config key from a removed integration.
