# Fable audit — salto-device-event-listener (2026-06-14)

## TL;DR

salto-device-event-listener is a compact ECS Fargate singleton that bridges Salto KS lock events to Kasa's device-service via SignalR WebSockets and SNS. The codebase is clean for its size, but carries two immediate operational issues: (1) the 10-minute cron job that refreshes Salto site membership has been failing with 401 errors on every single invocation for at least 7 days, meaning no new Salto sites can be discovered without a manual redeploy; and (2) every lock access event logs full guest PII (first name, last name, alias) to Datadog at info level — 85,390 times in 14 days. A confirmed bug in the graceful-shutdown path means SignalR connections are not actually closed on SIGTERM, and the OAuth token refresh strategy will silently strand long-lived connections after the token expires. Zero Datadog monitors exist for this service.

## Findings (ranked)

| # | Sev | Area | Finding | Evidence | Recommendation |
|---|-----|------|---------|----------|----------------|
| 1 | high | **Active bug / Observability** | `error_calling_get_sites_salto_sync_lambda` fires on every cron run (1,877 errors/14d, 1,009 in last 7 days — 100% failure rate since ~June 7). salto-sync `getSites` Lambda returns 401. No monitor alerts. New Salto sites cannot be added dynamically without a task restart. | DD: `service:salto-device-event-listener message:error_calling_get_sites_salto_sync_lambda` → 1,009 in 7d; all sample errors today: `"salto-sync returned status code: \"401\""` | Investigate why salto-sync `getSites` Lambda now returns 401 on direct invocation (possible requestContext auth check change after a salto-sync deploy). Short-term: add Datadog monitor on this error key. Medium-term: restart the task to re-seat the known sites. Root-cause: coordinate with salto-sync team on the invocation auth contract. |
| 2 | high | **PII in logs** | Every lock access event logs the full `parsedMessage` object at `info` level — including `user_first_name`, `user_last_name`, `user_alias`, `user_id` (guest identity data) and `access_by` (access method). Also logged on error path and for filtered events. 85,390 hits in 14 days. | `src/salto/EventStreaming.salto.ts:240-241` (`message_received_and_published_from_signal_r, {siteId, parsedMessage}`); also `:246-249` and `:252-255`. DD: 85,390 + 8,887 log events with full message objects. | Log only non-PII fields: `eventId`, `eventCategory`, `lockId`, `siteId`. Strip `user_first_name`, `user_last_name`, `user_alias`, `user_id`, `access_by` from log calls. |
| 3 | high | **Security / Data in logs** | `invokeLambda` logs the full Lambda response body at `info` level. Successful getSites responses include 10 Salto sites with `site_uid`, `customer_reference`, subscription details, and owner email addresses. Logged ~3,897 times in 14 days (~144×/day). | `src/utils/invoke-lambda.utils.ts:26-29` (`logger.info('got_response_from_invoked_lambda', { functionName, payload, responseBody })`). DD confirmed: full JSON body including `[REDACTED email]`, `[REDACTED email]` in `responseBody.body`. | Remove `responseBody` and `payload` from log. Log only `functionName`, `statusCode`. Apply to both invocation and response log lines. |
| 4 | high | **Reliability / SIGTERM** | `shutdownListeners()` uses `.map(async (c) => { await c.stop() })` — the outer map is not awaited and the result is discarded. All `c.stop()` calls are fire-and-forget. In `index.ts`, `shutdownListeners()` itself is not awaited either. On SIGTERM, `process.exit(0)` fires before any SignalR connection closes, leaving connections open on the Salto side and risking in-flight event loss. | `src/salto/EventStreaming.salto.ts:47-55` (`.map` not `Promise.all`); `src/index.ts:21` (result not awaited). | Change to `await Promise.all(this.connections.map(c => c.stop()))` and `await (await EventStreaming.getInstance()).shutdownListeners()` in the SIGTERM handler. |
| 5 | high | **Reliability / Token expiry** | The Salto OAuth token is fetched once at singleton creation and only refreshed in the `onreconnecting` handler. Typical OAuth `password` grant TTL is 1 hour. A service running >1 hour with no connection disruption will have an expired token when a reconnect finally occurs. SignalR's `onreconnecting` fires the async `setToken()` but the first reconnect attempt (0 ms default delay) fires before the HTTP token exchange completes — using the expired token and failing. After all retries exhaust, the connection is closed permanently and the site is silently dropped. | `src/salto/EventStreaming.salto.ts:101-118` (token set once in `getInstance()`), `:129` (`accessTokenFactory: () => this.token!`), `:177-184` (`onreconnecting` only caller of `setToken`). No `setInterval` or `expires_in` handling anywhere. | Add proactive token refresh: capture `expires_in` from the token response and schedule a `setTimeout` at 80% of TTL. Alternatively, make `accessTokenFactory` async and always fetch a fresh token. |
| 6 | high | **Observability / Health check lies** | `healthCheck()` returns `{ status: true, connections: 0 }` when there are no active connections. The ECS health check endpoint uses this — so a service that started with 0 sites (e.g., getSites returned null at startup due to the ongoing 401 issue) or lost all its connections reports itself as healthy indefinitely. ECS will not restart it, and no alert fires. | `src/salto/EventStreaming.salto.ts:63-72` (empty connections returns `{status: true, connections: 0}`). Combined with finding #1: a task that started when getSites was 401ing would have 0 connections and appear healthy. | Return `{ status: false }` when `connections.length === 0`. Or add a `started` flag: unhealthy only after startup completes with 0 connections. |
| 7 | high | **Reliability / Lambda timeout** | `invokeLambda` creates a `LambdaClient` with no `requestTimeout` or `connectTimeout`. At startup, `worker.init()` → `SiteManager.getInstance()` → `getSites()` → Lambda invocation blocks the entire startup. If the salto-sync Lambda is cold or hangs, the service hangs indefinitely (Lambda SDK default is 3 re-sends × Lambda max 15 min = up to 45 minutes). The SIGTERM handler is not registered until after startup completes, so the container cannot be killed cleanly during this window. | `src/utils/invoke-lambda.utils.ts:4-8` (no timeout on `LambdaClient`); `src/index.ts:40` (worker.init blocks before SIGTERM registration at line 18). | Add `requestHandler: new NodeHttpHandler({ requestTimeout: 5000, connectionTimeout: 2000 })` to `LambdaClient`. Add startup-timeout guard (e.g., `Promise.race([worker.init(), sleep(30_000).then(() => { throw ... })])`). |
| 8 | medium | **Reliability / Permanent site loss** | When a SignalR connection permanently closes (all reconnect retries exhausted), `onclose` removes the connection AND `SiteManager.removeSite` removes the site. The cron job only discovers net-new sites — it cannot re-add a site that was once managed and then lost. Until the next ECS task restart, that Salto site's lock events are silently dropped with no alert. | `src/salto/EventStreaming.salto.ts:162-169` (`onclose` emits and calls `removeConnection`); `src/custom-events/event-subscribers.ts:6-9` (also removes from SiteManager); `src/cron/jobs/fetch-new-sites.job.ts` (only adds new sites). | Track "known sites" separately from "active connections". On `onclose`, re-queue the site for reconnect attempts (with exponential backoff). Alternatively, trigger an immediate restart via the health endpoint (return unhealthy → ECS restarts). Add a monitor for `connection_closed_for_site` without subsequent `successfully_reconnected_to_site_events`. |
| 9 | medium | **Bug / Duplicate SIGTERM** | Two SIGTERM handlers are registered: `server.ts` registers `process.on('SIGTERM', ...)` (sets `state.shutdown = true`), and `index.ts` registers `process.once('SIGTERM', async () => { ... process.exit(0) })`. Because `process.once` is used in `index.ts`, it fires only once, while `process.on` in `server.ts` continues to be active. More critically, `server.ts` is imported before the SIGTERM handlers in `index.ts` are set — so the startup sequence registers both handlers on boot. On SIGTERM, both fire: `state.shutdown = true` AND the full shutdown path. No functional breakage today, but fragile and confusing. | `src/server.ts:16-18` (`process.on('SIGTERM', ...)`); `src/index.ts:18` (`process.once('SIGTERM', ...)`). | Remove the `process.on('SIGTERM', ...)` from `server.ts`. Pass shutdown state through dependency injection or a shared module instead. |
| 10 | medium | **Security / Unauthenticated health endpoint** | `/api/health` is publicly accessible with no authentication or network-level restriction. Response reveals internal state: connection count and overall connectivity to Salto. The service is `internetFacing: false` (CDK config), so it's only reachable within the VPC — this is the primary mitigation. | `src/server.ts:20-39` (no auth middleware); `cdk/config/config.ts:46-50` (`internetFacing: false`). | Accept as low risk given `internetFacing: false`. Document explicitly in README. Add a note that any future change to `internetFacing` requires adding auth. |
| 11 | medium | **Monitoring** | Zero Datadog monitors exist for `salto-device-event-listener`. No alerting on: error rate, cron-not-running, connection loss, token expiry, Lambda 401s, SNS publish failures. | DD monitors API: `[]` returned for `name=salto-device-event-listener`. | Add: (1) log alert for `error_calling_get_sites_salto_sync_lambda` count > 10/hour; (2) log alert for `connection_closed_for_site` without reconnect; (3) log alert for `failed_to_publish_message` count > 5/hour; (4) anomaly on total log volume. |
| 12 | medium | **CI / Caching bug** | `test.yml` workflow caches `./app/node_modules` but the project root is `.` with `node_modules` at `./node_modules`. Cache key also uses `./app/package-lock.json` which doesn't exist. Every CI run re-installs dependencies from scratch — no cache benefit. | `.github/workflows/test.yml` cache path `./app/node_modules`, key `./app/package-lock.json`. | Fix cache path to `./node_modules` and key to `./package-lock.json`. |
| 13 | medium | **Architecture / SNS publish failure** | `handleMessage` catches `publishDeviceStateChangedEvent` failures and logs them but discards the event. There is no retry, no dead-letter queue, no compensation. A transient SNS or network error silently drops a lock-access event — device-service never learns about it. | `src/salto/EventStreaming.salto.ts:213-249` (`catch` logs and discards). | Add a retry (e.g., 3× exponential backoff) before giving up. For unrecoverable failures, emit to a DLQ or write to a local buffer. Add a Datadog monitor on `failed_to_publish_message`. |
| 14 | medium | **Security / maskPassword bug** | `maskPassword` correctly masks long values but exposes the full secret for values ≤3 chars: for length 1 `i<2` is always true, for length 2 both `i<2` and `i>0` are true, for length 3 all three indices satisfy one branch. The function is called on every secret at startup. | `src/utils/mask-password.ts:1-7` (mask condition `i < 2 || i > password.length - 2`). | Fix mask logic: `password.length <= 4 ? '****' : password.slice(0, 2) + '#'.repeat(password.length - 3) + password.slice(-1)`. Also reduce to a single `secret_loaded` info log rather than one per key. |
| 15 | low | **Architecture / Dead secret** | `SALTO_SERVER_URL` is loaded from Secrets Manager, validated by Zod, and stored in `SecretStore` — but never accessed via `secretStore.get('SALTO_SERVER_URL')` anywhere in the codebase. Unnecessary Secrets Manager read on every startup. | `src/config/secret-manager.config.ts:22` (SALTO_SERVER_URL in schema); no `secretStore.get('SALTO_SERVER_URL')` call exists. | Remove `SALTO_SERVER_URL` from `SecretStore` schema and `loadSaltoAPISecrets`. |
| 16 | low | **Architecture / URL substring match** | `removeConnection` filters connections by `c.baseUrl.includes(siteId)`, which could match partial site IDs (e.g., `"123"` matches `"1234"`). Production Salto site IDs are UUIDs, so collision is unlikely today, but the pattern is fragile. | `src/salto/EventStreaming.salto.ts:57-61`. | Use a `Map<string, HubConnection>` keyed by `siteId` for O(1) exact-match lookups, replacing both the array and the substring filter. |
| 17 | low | **Dependencies** | `@microsoft/signalr ^10.0.0` targets the .NET 10 preview/RC release line. The `^` range allows auto-upgrade across minor/patch versions in an unstable pre-release track. `express ^5.2.1` is Express 5 (stable since late 2024, but with a narrower community surface than v4 for edge cases). | `package.json: "@microsoft/signalr": "^10.0.0"`, `"express": "^5.2.1"`. | Pin `@microsoft/signalr` to an exact version or use a tilde-range (`~10.0.0`) until .NET 10 reaches final release. Monitor for breaking changes in minor bumps. Express 5 is acceptable risk — no immediate action. |
| 18 | low | **Dependencies / Security** | `fast-xml-parser` (critical GHSA-37qj-frw5-hhjh, GHSA-jmr7-xgp7-cmfj) and `path-to-regexp` (high GHSA-j3q9-mxjg-w52f) are confirmed production dependencies via `@aws-sdk/core` and `express`. `fast-xml-parser` is used only for AWS SDK's XML protocol handling (not used on any code path in this service — the endpoints are REST/JSON). `path-to-regexp` is used by Express routing (the single `/api/health` route). | `npm audit --production` confirms both as production vulns; `package-lock.json`: `fast-xml-parser: 5.2.5, 5.7.3 (dev=False)`, `path-to-regexp: 8.2.0 (dev=False)`. | Upgrade `@aws-sdk/*` to the latest minor (fast-xml-parser fix is in newer patch versions). For path-to-regexp, upgrade Express to latest 5.x which should pull in a patched version. |

## Architecture notes

### What salto-device-event-listener does

salto-device-event-listener is a Serverless ECS Fargate singleton (exactly 1 task, cpu=512/mem=1024 in production) acting as a real-time bridge between Salto KS lock events and Kasa's device-service.

**Data flow:**
1. At startup, fetches all Salto site IDs from salto-sync via direct Lambda invocation
2. Opens a SignalR WebSocket connection to `wss://eventstreaming-connect-production.saltoks.com/v1/hub/entries?site_id=<id>` for each site (10 sites in production)
3. On `ReceiveMessage`, parses the lock event and publishes a `deviceStateChanged` SNS event (filtered: `privacy_mode` and `office_mode` events are silently dropped)
4. A 10-minute cron job calls `getSites` again to discover newly added sites

**Component list:**
- `EventStreaming` (singleton) — OAuth token management, SignalR HubConnection lifecycle, message parsing, SNS publishing
- `SiteManager` (singleton) — tracks managed site IDs, delegates to salto-sync Lambda
- Express app — single `/api/health` route (ECS container health check)
- `cron` (CronJob, every 10 min) — calls `fetchNewSites`
- `invokeLambda` util — direct AWS Lambda SDK invocation (no API Gateway)
- Secrets via AWS Secrets Manager (`${stage}/credentials/salto-connect-api`)
- SNS target: `deviceStateChanged-production`

**No database.** No Mongoose. Stateless except for in-memory connection array.

**Structural positives:**
- Secrets Manager for all credentials (no env-var secrets)
- Zod schema validation on startup config
- `withAutomaticReconnect()` on all SignalR connections
- Graceful SIGTERM handler (though it doesn't actually await connection teardown — see Finding #4)
- EMIT_EVENTS / ENABLE_JOBS feature flags allow disabling mutations in non-production (but no dry-run in production)
- `internetFacing: false` — not publicly reachable

**Structural concerns:**
- `EventStreaming` is a god class: OAuth auth, connection lifecycle, message parsing, SNS publishing, health reporting all in one 268-line file
- No error boundary between startup (getSites via Lambda) and event streaming — a Lambda 401 at startup causes 0 listeners with no restart signal
- No tests

### Bus-factor table (2-year git window)

| Author | Human commits | Scope |
|--------|--------------|-------|
| Zoltan Feher | 7 | Core application logic (SignalR, event handling, site management) |
| Kristóf Iváncza | 12 | Infrastructure / CDK / CI / deployment |
| Gabor Balazs | 3 | Ops / maintenance / config fixes |
| Janos Mayer | 1 | Minor |

**Assessment:** Effective ownership split between Zoltan (application behavior) and Kristóf (infra). Reasonable two-person coverage for a service of this size. The core SignalR logic and token handling are Zoltan's work and have no tests. If Zoltan is unavailable, the token-refresh edge cases and reconnect behavior would be hard to debug safely.

## Production signals

**Log retention window used:** 14 days.

**Total volume:** 117,778 log events in 14 days (~8,413/day).

### Chronic errors (14-day window)

| Error key | Count (14d) | Last 7d | Root cause | Monitor? |
|-----------|-------------|---------|-----------|----------|
| `error_calling_get_sites_salto_sync_lambda` | 1,877 | 1,009 | salto-sync returns 401 on direct Lambda invocation | No |
| `error_happened_during_server_start` | 1,072 | 0 | ZodError: LOG_FORMAT undefined in Zod 4.4.3 (fixed in PR #70) | No |
| WebSocket 1006 disconnect | 130 | ~65 | SignalR connection drop (normal; reconnects successfully ~129 times) | No |
| `on_reconnecting_error_event_handler` | 130 | ~65 | Pairs with above; expected during reconnect | No |
| WebSocket connect failed | 26 | ~13 | Salto endpoint unreachable during reconnect window | No |

**Root-cause analysis:**
- **error_calling_get_sites_salto_sync_lambda (ACTIVE)**: The salto-sync Lambda `getSites` is returning `{statusCode: 401}` on every direct invocation. This started approximately June 7th (1,009/7 days = 144/day = every 10 min = every cron run). The June 1-2 errors (868) included some startup-time failures during the LOG_FORMAT incident. The July pattern is all cron. Likely cause: a salto-sync deploy changed how the handler validates the Lambda event context. Confirmed by sampling `get_sites_salto_sync_lambda` error logs today (20:00, 19:50, 19:40 UTC+2).
- **error_happened_during_server_start (RESOLVED)**: All 1,072 occurrences are from June 1st (924) and May 31st (147). ZodError due to Zod 4.x changing how optional fields behave — `LOG_FORMAT` was required but not set in the production task definition. Fixed in PR #70. Zero occurrences in the last 7 days.

### Log noise summary

| Message | Volume (14d) | Level | Contains PII/data | Action |
|---------|-------------|-------|------------------|--------|
| `message_received_and_published_from_signal_r` | 85,390 | info | **Yes — guest PII** | Strip PII fields; keep `lockId`, `siteId`, `eventCategory` only |
| `not_published_message_from_salto` | 8,887 | info | Yes — full parsedMessage | Strip PII; downgrade to debug |
| `got_response_from_invoked_lambda` | 3,897 | info | Yes — full site data + owner emails | Remove responseBody from log |
| `invoking_lambda` | 3,897 | info | Yes — full payload | Remove payload; log functionName only |
| `starting_job`/`finished_running_job`/`no_new_site_ids_were_added` | 3,892 each | info | No | Consider downgrading to debug |

**Top savings opportunity:** `message_received_and_published_from_signal_r` (85,390/14d) is the largest log category. Stripping the full `parsedMessage` object (which carries ~10+ fields per event) could reduce total log volume by ~73% and eliminate the PII exposure. Secondary: remove the `responseBody` from Lambda response logs (3,897 large JSON payloads).

### Monitor coverage gaps

Zero monitors for this service. Mapped against failure modes:

| Failure mode | Proposed monitor |
|---|---|
| getSites Lambda 401 (ongoing) | Log alert: `error_calling_get_sites_salto_sync_lambda` count > 2 in 15 min |
| Connection permanently closed | Log alert: `connection_closed_for_site` without subsequent `successfully_reconnected` in 5 min |
| SNS publish failure | Log alert: `failed_to_publish_message` count > 5 in 15 min |
| Service unhealthy / high error rate | Log alert: status:error count > 10 in 15 min |
| No messages received (dead silence) | Anomaly monitor: `message_received_and_published_from_signal_r` drops to 0 for >30 min |

### Scheduled-job inventory

| Job | Schedule | DD confirms running? | Dry-run / kill switch? |
|-----|---------|---------------------|----------------------|
| `fetchNewSites` (CronJob, UTC) | `*/10 * * * *` | Yes (`starting_job` × 3,892 in 14d) | `ENABLE_JOBS=false` env var kills it. No dry-run — but it's read-only (no mutations). |

**Note:** When `EMIT_EVENTS=false`, no SNS messages are published — effective kill switch for the main data flow. No fine-grained site-level kill switch.

### Dead API surface

One HTTP route: `GET /api/health` — actively used by ECS health check. Not dead.

## Cost

**ECS Fargate task (production):** cpu=512 (0.5 vCPU), mem=1024 MB + Datadog sidecar (cpu=128, mem=256 MB). Desired count = 1, min=1, max=1.
- Monthly cost (1 task × 0.5 vCPU × ~$0.04048/vCPU-hour + 1 GB × ~$0.004445/GB-hour) × 720 hours ≈ ~$23/month.
- The sidecar adds ~10% more: ~$2/month.

**Datadog log ingestion (14d):** 117,778 events. Estimated ~0.3–0.5 KB/event avg (many carry large JSON) = ~35–60 MB/14d. Low absolute cost, but 73% of that volume is PII-bearing events that add compliance risk without proportional operational value.

**Top savings levers:**
1. Strip `parsedMessage` from `message_received_and_published_from_signal_r` logs (85,390 events × ~0.5 KB = ~43 MB/14d savings, ~$0.09/month at $0.10/GB — low dollar but PII elimination is the real win).
2. Remove `responseBody` from `got_response_from_invoked_lambda` (3,897 events × ~3 KB body = ~11 MB/14d, ~$0.02/month).
3. Right-sizing: the task at 512 cpu / 1024 MB is reasonably sized for a WebSocket-heavy workload. No immediate change recommended until token/reconnect issues are resolved.

## Skipped / caveats

- **AWS DLQ/CloudWatch checks**: AWS SSO session expired. DLQ not applicable (service has no SQS queues). CloudWatch Lambda utilization not pulled.
- **Git history secret scan**: Bounded to credential/env files in last 2 years. No hardcoded secrets found. All credentials correctly use Secrets Manager references.
- **Datadog monitors API**: Returned empty array — confirms zero monitors, not an API auth issue (service discovery query confirmed 117K events exist).
- **tsconfig.json**: `strict: true` IS enabled — several workflow subagent findings claiming it's absent were incorrect and excluded.
- **`error_happened_during_server_start`**: All 1,072 occurrences are historical (June 1st incident, ZodError for LOG_FORMAT). Fixed in current HEAD. Not a current issue.
- **salto-sync 401 root cause**: Cannot determine without access to salto-sync source or the failing Lambda's CloudWatch logs. Requires cross-team investigation.
