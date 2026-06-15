# Fable audit — remotelock-sync (2026-06-13)

> Auditing origin/master @ 2e6b9fe (2026-06-03T15:15 +02:00). Local checkout was 8 commits behind, clean. Fresh worktree at `/tmp/fable-audit-remotelock-sync`.

## TL;DR

remotelock-sync is a lean Serverless Lambda service with no queues and no database — clean in structure, but it has three compounding security failures: a webhook secret hardcoded in git since 2020, that same secret being logged to Datadog on every call (~300K exposures in 14 days), and door PINs logged in plaintext (~48K times). The service also has zero Datadog monitors despite 39K errors in 14 days, and a chronic rate-limit storm against the RemoteLock API (9,200 HTTP 429s in 14 days, all on `createUserCode`). Total estimated monthly savings from token caching + log reduction: ~$70–100/month. Immediate action required: rotate the `WEBHOOK_SECRET` and scrub PINs from logs.

---

## Findings (ranked)

| # | Sev | Area | Finding | Evidence | Recommendation |
|---|-----|------|---------|----------|----------------|
| 1 | **high** | Security | `WEBHOOK_SECRET` UUID hardcoded as plaintext in `serverless.yml:97`, tracked in git since the initial commit (2020-09-28). Anyone with repo access can forge webhook events. | `serverless.yml:97`: `WEBHOOK_SECRET: '42cd421e-5aae-48f6-ae50-c4aa6d39acb1'` | **Flag for rotation immediately.** Move value to AWS Secrets Manager or SSM Parameter Store. Reference via `{{resolve:ssm:…}}` in serverless env or load at runtime in the handler. |
| 2 | **high** | Security / PII | Webhook handler logs the full Lambda event including the `X-Secret` header on every call (`getWebhookEvent.ts:26`). Confirmed: Datadog shows the live secret value in 302K log lines over 14 days. | Datadog: `get_webhook_event_start` 302K entries with `event.headers["X-Secret"]: "42cd…"` | Remove `event` from the `get_webhook_event_start` log (log only safe fields like `pathParameters.account`). Fix #1 first (rotate), then fix the log. |
| 3 | **high** | Security / PII | Door PINs logged in plaintext via `remotelock_create_access_person` (logs full request body with `attributes.pin`) and via `remotelock_request_data` (logs `JSON.stringify(data)` for every API call including create). Confirmed in Datadog: 48,223 PIN-bearing log lines in 14 days. | Datadog sample: `{"attributes":{"pin":"7267","name":"7267#TMP-506#BU"},"type":"access_user"}`. Code: `RemoteLockClient.ts:32` (`remotelock_request_data`), `AccessPerson.ts:72` (`remotelock_create_access_person`). | Redact `attributes.pin` before logging. In `RemoteLockClient.request()`, redact the `data` object for POST/PUT calls before `JSON.stringify`. Remove or redact the `request` field in `AccessPerson.createAccessPerson`. |
| 4 | **high** | Observability | Zero Datadog monitors for remotelock-sync. 39,134 errors in 14 days (2,795/day avg) — no alert fires. Token-refresh failures, rate limiting, and bulk-delete operations are all silent. | `GET /api/v1/monitor?name=remotelock` → empty. | Create monitors for: error-rate spike on `service:remotelock-sync-production*`, `token_refresh_error` 5-min window, 429 rate-limit burst (>100 in 5 min), and Lambda errors via CloudWatch. |
| 5 | **high** | Bugs / Resilience | `createUserCode` generates 8,100 HTTP 429 rate-limit errors in 14 days (88% of all 429s). The code propagates the 429 immediately as `RATE_LIMIT_REACHED` — no retry, no backoff, no throttling. CSS retries the Lambda, which immediately hits the rate limit again, forming a burst-retry storm. | Datadog: 429s on `remotelock-sync-production-createUserCode` count=8100. `RemoteLockClient.ts:65` throws `HttpApiError` with code 429 immediately. `function-helpers.ts:48` translates it to `RATE_LIMIT_REACHED` with no retry. | Add exponential backoff with jitter on 429 inside `RemoteLockClient.request()`. Surface `Retry-After` header to CSS so CSS can back off. Consider concurrency limiting (Lambda reserved concurrency + SQS buffer if CSS starts using async dispatch). Note: salto-sync, smartthings-sync, seam-sync likely have the same retry gap. |
| 6 | **medium** | Bugs / Resilience | `getWebhookEvent.ts:55–58`: SNS publish failure is silently swallowed. If `DEVICE_STATE_CHANGED_ARN` is unavailable, the function logs an error and returns `statusCode: 201`. RemoteLock considers the event delivered, but the device state change is lost permanently — no retry, no DLQ. | `getWebhookEvent.ts:55`: `catch (e) { logger.error(…); }` then `return { statusCode: 201 }`. | Return a 5xx status on SNS failure so RemoteLock retries the webhook. Or buffer to SQS with a DLQ before SNS publish. |
| 7 | **medium** | Security | `deleteCodeByKeyword` (Lambda `internal/deleteCodeByKeyword.ts`) deletes all access persons matching a keyword with no dry-run default and no kill switch. It fetches the full access person list first (potentially thousands), then deletes every matching name. This function triggered the 2026-06-01 mass-delete incident (19 active guest codes deleted). | `deleteCodeByKeyword.ts:13–26`. Serverless.yml: no HTTP event (Lambda-direct only), but no caller authentication beyond IAM. | Add `dryRun: boolean` param (default `true`). Log every would-be deletion when `dryRun=true` and return without deleting. Enforce `dryRun=false` only via explicit caller opt-in. Note: this pattern likely exists in other vendor-sync siblings. |
| 8 | **medium** | Resilience | `getAxios.ts:7`: HTTP timeout set to 300,000ms (5 minutes). A single unresponsive RemoteLock API call can hold the Lambda for 5 minutes, consuming compute and blocking CSS callers. Lambda default timeout is 600s, so a paginated `getAccessPersons` with 20 pages could hold a connection for up to 100 minutes if timeouts stacked (bounded only by the Lambda 900s limit). | `getAxios.ts:7`: `timeout: 300000`. Also TODO comment: `/** @TODO: find out optimal timeout value */` — unresolved since original commit. | Set Axios timeout to 30,000ms (30s) for interactive calls. For batch/paginated calls, 60s is generous. Catch `ECONNABORTED`/`ETIMEDOUT` explicitly and bubble as `NetworkApiError`. |
| 9 | **medium** | Cost / Performance | No token or secret caching. Every Lambda invocation: (1) loads the full credentials secret from Secrets Manager, (2) calls RemoteLock's OAuth2 endpoint for a fresh token. `loading_secret` and `token_refresh_success` each appear 577K times in 14 days (~41K/day). Secrets Manager charges per-API: ~577K calls/14d ≈ 1.2M/month = ~$6/month. Token fetch adds 200–500ms RTT to every cold invocation. | Datadog: `loading_secret` count=577,212. `token_refresh_success` count=576,979. | Cache the OAuth2 token in Lambda container global scope (tokens are valid for 1+ hour; reuse across warm invocations). Cache the parsed secret object similarly. This reduces Secrets Manager calls by ~95% and removes a network round-trip per invocation. |
| 10 | **medium** | Cost / Observability | Log spam: `remotelock_request_data` (943K) + `remotelock_request_response_data` (924K) + `loading_secret` (577K) + `loading_secret_success` (577K) = ~3M log entries in 14 days from just four message keys. These carry large JSON payloads. Together they dominate Datadog ingestion cost. | Datadog volume query: top 25 messages by count, 14d window. | Remove `remotelock_request_data` and `remotelock_request_response_data` entirely (they expose PINs anyway — fix #3). Remove `loading_secret`/`loading_secret_success` (they're operational noise with no actionable content). Keep one-line debug log at `DEBUG` level if needed. Estimated saving: >$50/month in Datadog ingestion. |
| 11 | **medium** | Bugs | `RemoteLockResponse.ts:getDeviceStatus`: the condition `attributes.devices_count < 1 \|\| attributes.devices_count > 1` means only `devices_count === 1` can ever reach the `set`/`not_set` branch. Any access spanning 2+ devices always returns `'error'` regardless of sync state. `connector_lock` device type is now appearing in production (seen in Datadog) but is not in `getWebhookEvent.ts`'s `VALID_DEVICE_TYPES` list — webhook events from `connector_lock` will silently return `deviceId: null`. | `RemoteLockResponse.ts:29–36`. Datadog: `accessible_type: "connector_lock"` in recent request logs. | Clarify intent: if multi-device accesses are valid, fix the condition to use `devices_failed_sync_count` as the primary error signal. Add `'connector_lock'` to `VALID_DEVICE_TYPES` in `getWebhookEvent.ts` if RemoteLock now sends it. |
| 12 | **low** | Security | TypeScript strict mode disabled — `tsconfig.json` has no `"strict": true`. All parameters and return types are implicitly `any` unless explicitly annotated. The codebase mixes TypeScript and JSDoc annotations; several lib files use untyped parameters (`person: any`, `error: any`). | `tsconfig.json`: no strict flag. `RemoteLockClient.ts:38`: `constructor(axiosClient)` — untyped. | Enable `"strict": true` in tsconfig and fix the type errors. At minimum enable `"strictNullChecks": true` to catch the null-propagation patterns (e.g. `getToken` returns `null` on failure and callers check with `if (!client)` but without strict mode this is unenforced). |
| 13 | **low** | Architecture | `serverless.yml:2`: `org: kasaliving` — should be `kasadev` per team conventions. | `serverless.yml:2`. | Change to `org: kasadev`. |
| 14 | **low** | Observability | CI (`node.js.yml`) runs only `npm test` — no TypeScript type-check step (`tsc --noEmit`). Type errors would pass CI. | `.github/workflows/node.js.yml`: build job only runs `npm ci` + `npm test`. | Add `npx tsc --noEmit` step to the CI workflow before tests. |

---

## Architecture notes

### Service map

remotelock-sync is a **pure Serverless Lambda service** (13 functions, nodejs24.x, Serverless Framework v4). No NestJS, no MongoDB, no SQS queues. All functions except one are invoked directly by the Code Setting Service (CSS) via Lambda SDK — not via API Gateway. The one HTTP-facing function is `getWebhookEvent`, which receives POST events from the RemoteLock platform at `https://remotelock-sync.kasa.com/webhook/{account}`.

**Component inventory:**

| Component | Role |
|-----------|------|
| `lib/RemoteLockClient` | Low-level HTTP client — wraps the RemoteLock REST API (axios, per-request auth token) |
| `lib/AccessPerson` | Domain layer — CRUD for access persons, accessibles, permission grants/revocations |
| `lib/Device` | Domain layer — device listing and temporary unlock |
| `lib/getToken` | Fetches a fresh OAuth2 client_credentials token per RemoteLock account name |
| `lib/secret` | Loads multi-account credentials JSON from AWS Secrets Manager |
| `lib/function-helpers` | `handlerWrapper` — resolves `accountName → token → client`, validates required fields, wraps errors uniformly |
| `lib/httpWrapper` | Adapts internal Lambda responses to HTTP-shaped API Gateway responses (used only by `getDevices`, `getDevice`, `unlockTemporarily`) |
| `lib/RemoteLockRequest` | Request builders for create/update/grant-permission |
| `lib/RemoteLockResponse` | Response parsers for access-person, device, and access objects |

**Data flow:** CSS → Lambda (direct invoke) → `handlerWrapper` → `getToken(accountName)` → `loadSecret(stage/credentials/Remotelock)` → Secrets Manager → RemoteLock OAuth endpoint → RemoteLock REST API → SNS (for webhook events only).

**No scheduled jobs.** All invocations are on-demand from CSS.

### Bus-factor table

| Author | Commits (2yr) | Areas |
|--------|---------------|-------|
| Zoltan Feher | 16 | lib/, functions/ — primary implementer |
| Norbert Pospischek | 12 | functions/, CI/CD |
| Gabor Balazs | 5 | Node/TS upgrades, misc |
| dependabot[bot] | 29 | Dependency bumps only |
| Others (3) | 3 | One-off |

**Effective bus factor: 2.** Zoltan Feher and Norbert Pospischek hold all domain knowledge. No CLAUDE.md, sparse code comments. On-call risk: if both are unavailable, only high-level understanding is possible.

### Step 2 static observations

- **No idempotency on createAccessPerson**: if CSS retries a create call (e.g. after a timeout), a second `access_user` is created. The 6,574 HTTP 422 "PIN has already been taken" errors in Datadog are the symptom — RemoteLock rejects the duplicate. The current error path logs an error and propagates it as `INVALID_REQUEST` to CSS. A look-up-or-create pattern would eliminate these.
- **`updateAccessPerson` is a TOCTOU race**: the method checks dates, conditionally updates, then diffs accessibles — none of this is atomic at the RemoteLock API level. Concurrent calls for the same person can produce partial state.
- **`getAllAccessPersons` pagination**: terminates when a page returns 0 items. This is correct but will loop indefinitely if RemoteLock returns non-empty pages forever (no circuit breaker). The `iteration` log fires 186K times in 14 days.
- **`getAccountNames` exposes credential account names** without authentication (Lambda-direct-only, so protected by IAM, but any caller with `lambda:InvokeFunction` permission gets the list of RemoteLock account names).
- **Shared libs in use**: `@kasadev/logger`, `@kasadev/lambda-utils`, `@kasadev/sns-events`, `@kasadev/code-api-types`, `@kasadev/enums` — good adoption of Kasa shared tooling.
- **`requestedByParser.ts`**: imported by `unlockTemporarily` but `requestedBy` is extracted and then never used after extraction (variable declared but no action taken). The `httpCall` variable in `unlockTemporarily.ts` is also computed but never used.

---

## Production signals

### Error archaeology (14-day window — full Datadog retention)

**Total errors:** 39,134 in 14 days (2,795/day avg)

| Error message | Count | Root cause |
|---------------|-------|-----------|
| `remotelock_api_error` | 19,574 | Vendor API errors (see breakdown below) |
| `create_access_user_handler_error` | 14,073 | Same 429/422 errors surfacing at handler level |
| `update_person_error` | 4,018 | Update failures (422/429) |
| `get_access_person_accesses_handler_error` | 948 | Access fetch failures |
| `token_refresh_error` 503/504 | 232 | RemoteLock OAuth endpoint intermittently down |
| `get_access_users_handler_error` | 201 | Paginated fetch failures |
| `get_devices_handler_error` | 51 | Device listing failures |
| `delete_code_handler_error` | 34 | Delete failures |

**`remotelock_api_error` HTTP breakdown:**

| HTTP Status | Count | Meaning |
|-------------|-------|---------|
| 429 | 9,212 | Rate limit exceeded — **88% from `createUserCode`** |
| 422 | 6,574 | "PIN has already been taken" — duplicate create attempts |
| 404 | 3,702 | Access person or device not found (deleted remotely?) |
| 503/504 | 89 | RemoteLock API intermittently unavailable |

**Chronic issues:**
1. The 429 + 422 pair (~16K combined) represents the create/retry storm: CSS calls `createUserCode`, RemoteLock rate-limits, CSS retries, RemoteLock rejects duplicate PIN. Neither the rate-limit backoff nor the idempotency check exist. This has been ongoing for the full 14-day window.
2. The 404s on access persons likely indicate CSS tries to operate on persons already deleted on the RemoteLock side (sync drift). No reconciliation logic exists.

### Log noise & cost

**Top 14-day log volume (selected):**

| Message | Count | Issue |
|---------|-------|-------|
| `remotelock_request_data` | 943,419 | Logs full request body (incl. PINs) on every API call |
| `remotelock_request_url` | 943,419 | Low-value URL/method log |
| `remotelock_request_response_data` | 923,834 | Logs full response body on every API call |
| `loading_secret` | 577,212 | One per invocation; secretId has no actionable info |
| `loading_secret_success` | 577,212 | Duplicate of above |
| `token_refresh_success` | 576,979 | One per invocation |
| `access_person_create_instance` | 529,612 | Constructor log; zero value |
| `iteration` | 186,805 | Pagination debug log with full arrays |

`remotelock_request_data` + `remotelock_request_response_data` alone = 1.87M logs in 14d carrying large JSON payloads. **Top reduction opportunity: remove these two log lines entirely** (they expose PINs anyway). This would reduce Datadog ingest by an estimated 30-40%.

### Monitor & alerting coverage

**Result: zero monitors.** `GET /api/v1/monitor?name=remotelock` returns an empty array.

**Gaps vs failure modes found:**

| Failure mode | Monitor exists? | Proposed monitor |
|---|---|---|
| Error rate spike | No | Logs-based: `service:remotelock-sync-production* status:error` count > 100 in 5m |
| Rate-limit storm (429 burst) | No | Logs: `remotelock_api_error` + `@status:429` > 50 in 5m → page IOT on-call |
| Token refresh failures | No | Logs: `token_refresh_error` > 10 in 1h |
| Lambda timeout | No | CloudWatch: `remotelock-sync-production*` Duration > 540,000ms |
| Webhook secret rejected | No | Logs: `get_webhook_event_missing_secret` > 20 in 10m (probe detection) |

Every chronic error from the error archaeology section has no monitor. This is a complete monitoring blind spot.

### Scheduled-job inventory

**No scheduled jobs.** No cron/EventBridge/scheduled Lambda defined in `serverless.yml`. All functions are demand-invoked by CSS. (No forgotten automation risk.)

### Dead API surface

Only `getWebhookEvent` has an HTTP event trigger (API Gateway POST `/webhook/{account}`). All other functions are Lambda-direct-only. No HTTP dead routes found.

---

## Cost

### Lambda sizing

All 13 functions are provisioned at **1024MB**. Actual workloads suggest this is oversized for most:

| Function | Avg Duration | P-max Duration | Invocations/14d | Est. Cost/mo |
|----------|-------------|----------------|-----------------|---|
| `getWebhookEvent` | ~100ms est. | — | 300,784 | ~$2 |
| `createUserCode` | 2,948ms avg | 53,643ms | 48,151 | ~$3 |
| `getAccessPersons` | 852ms avg | 50,989ms | ~1,500 est. | <$1 |
| Others (10 fns) | — | — | ~100K est. | ~$2 |

**Total Lambda cost estimate: ~$8–12/month** — not a major savings lever at current scale.

**Secrets Manager:** 577K API calls in 14d ≈ 1.2M/month. At $0.05/10K = **~$6/month**. Token caching in Lambda container scope would reduce this by ~95% → **save ~$5.70/month**.

**Datadog log ingestion:** ~6–8M log lines in 14 days. At Kasa's estimated ingestion cost, the `remotelock_request_data` + `remotelock_request_response_data` alone carry multi-MB JSON payloads. Conservative estimate: removing these two log lines saves **$40–60/month** in Datadog.

### Top 3 savings levers

1. **Remove `remotelock_request_data` / `remotelock_request_response_data` logs** — $40–60/month Datadog reduction. Also fixes the PIN PII issue.
2. **Cache OAuth2 token in Lambda container scope** — eliminates ~575K Secrets Manager calls/month = ~$5.70/month. Faster invocations too.
3. **Memory right-sizing** — `getWebhookEvent` at 300K invocations/14d with estimated <100ms duration could run at 256MB. Others could drop to 512MB. Estimated save: ~$2–3/month (low priority given Lambda pricing).

---

## Skipped / caveats

- **DLQ depth**: No SQS queues in this service — DLQ check is not applicable.
- **Git history secret scan**: Broad scan showed the `WEBHOOK_SECRET` has been in `serverless.yml` since the initial commit (2020-09-28). No other plaintext secrets found in tracked files or recent commit diffs.
- **Sibling note (salto-sync, smartthings-sync, seam-sync)**: The missing retry/backoff on 429, no token caching, PIN logging pattern, and `deleteCodeByKeyword` / no-dry-run pattern are architectural patterns that likely exist in the other three vendor-sync services — recommend the synthesis task flag these for cross-sibling review.
