# Fable audit — callbox-automation (2026-06-15)

## TL;DR

callbox-automation is a small, focused Twilio/Lambda service that handles intercom-to-door-unlock automation for Kasa buildings. The codebase is clean and test-covered, and production shows zero errors in 14 days (~6 calls/day). However, it has two high-severity live issues that need immediate attention: **door codes are logging to Datadog in plaintext** (confirmed in production logs — CCPA/security violation), and **the webhook error handler returns `null` instead of a valid TwiML response** (any unhandled exception triggers an HTTP 502, causing Twilio to retry indefinitely). A third high issue: the `enabled` flag on Callbox records is never enforced during call routing — disabled callboxes still accept calls. The service has strong single-author concentration (Zoltan Feher owns ~80% of recent commits). Monthly AWS cost is negligible; no meaningful savings opportunity.

---

## Findings (ranked)

| # | Sev | Area | Finding | Evidence | Recommendation |
|---|-----|------|---------|----------|----------------|
| 1 | high | Security — PII/codes in logs (LIVE) | Door codes are logged to Datadog in plaintext. Confirmed in production: `getting_accesses_for_code_and_buildings` emits `"code": "XXXX"` and `request_authorized` emits the full `access` document including `code`. Also: `callbox_call_not_authorized` logs `body.Digits`; `logToSlack(...)` sends the raw digit string to Slack. `build_gather_response` logs full Twilio event body including the full URL-encoded POST body. | `data-query-layer/access-dql.ts:18-20` (`code` param), `functions/handleGuestInput.ts:77` (`access` obj), DD: confirmed `code` field in production logs | Remove `code`/`Digits` from all logger calls. Use `logger.info('getting_accesses', { buildingIds, codeLength: code.length })` instead. Strip codes from access objects before logging (`const { code: _, ...safeAccess } = access`). In webhook.ts:21 replace `{ event }` with `{ handlerName, awsRequestId: ctx.awsRequestId }`. |
| 2 | high | Bug — resilience (retry storm risk) | `handlerWrapper` returns `null` on unhandled error (`utils/handler-wrapper.ts:98`). AWS API Gateway converts Lambda `null` response to HTTP 502; Twilio treats 502 as a webhook failure and retries up to 11 times over ~15 minutes. Any unhandled exception in a webhook handler will produce a retry storm of up to 11 duplicate call-answer attempts. | `utils/handler-wrapper.ts:98` — `return null` in catch block | Return a valid TwiML response on error: replace `return null` with `return buildForwardToGx()` (already imported). This gracefully forwards the call to GX instead of producing 502s. |
| 3 | high | Bug — disabled callboxes still active | `findCallboxByCallboxNumber` queries `{ number, deleted: false }` without filtering `enabled: true`. A callbox marked `enabled: false` still processes incoming calls as if active. The `enabled` field is stored in the schema, updated by `callbox-changed` handler, but never checked at call time. | `data-query-layer/callbox-dql.ts:14` | Change query to `{ number, deleted: false, enabled: true }`. Add test asserting disabled callboxes return no result. |
| 4 | medium | Bug — retries query string parsed incorrectly | `handleGuestInput.ts:146`: `parseInt(event.queryStringParameters.retries[0], 10)` — `retries` is a `string`, so `[0]` yields the first *character*, not first array element. Works accidentally for single-digit retries (max=2 today), but silently misparses if `MAX_RETRIES` is ever raised above 9 (e.g., `retries=10` parses as `1`). | `functions/handleGuestInput.ts:146` | Fix: `parseInt(event.queryStringParameters.retries, 10)`. |
| 5 | medium | Bug — non-idempotent callbox-installed handler | `handleCallboxAutomationInstalledInBuilding` throws `Callbox already exists...` on SQS redelivery, sending the message to DLQ. There is no idempotency check: if the handler Lambda times out after creating the record but before acknowledging the SQS message, the redelivery fails. | `functions/events/callbox-installed.ts:36-38` | Use an upsert pattern: `findOne({ number: phoneNumber, deleted: false })` — if found and data matches, succeed silently; if found with different data, update; only create if absent. |
| 6 | medium | Data integrity — multiple accesses for same code (3 events, June 13) | `callbox_call_multiple_accesses_found_for_code_and_building` fired 3 times on 2026-06-13, each with 2 active accesses for the same code+building. The handler takes `activeAccesses[0]` non-deterministically. Root cause: likely a duplicate `setCode` call (retry) creating two access records with the same code; `createAccesses` in `access-dql.ts` has no uniqueness constraint or upsert — it always inserts. | DD: 3 events 2026-06-13T20:50-21:15; `data-query-layer/access-dql.ts:63-70` | Add a MongoDB unique index on `(callbox, code, deleted=false)` or implement an upsert in `createAccesses`. Short-term: add a dedup query before insert. |
| 7 | medium | Architecture — `enabled` flag semantically dead | `ICallbox.enabled` is stored and updated by `callbox-changed` events but never enforced during call routing (covered by #3). Any engineer reading the schema would expect `enabled: false` to stop call processing. | `data/models/Callbox.ts:9`, `data-query-layer/callbox-dql.ts:14` | Enforce filter (fix #3); add integration test asserting disabled callboxes are rejected. |
| 8 | medium | Resilience — no MongoDB connect timeout | `mongoose.createConnection(url, { maxPoolSize: 1 })` has no `serverSelectionTimeoutMS` or `connectTimeoutMS`. If Atlas is unreachable, the Lambda hangs until the Lambda timeout (~6s for API Gateway), making callers wait silently before getting a GX fallback. | `data/models/MongoModel.ts:13` | Add `serverSelectionTimeoutMS: 3000, connectTimeoutMS: 3000`. If connection fails, catch the error and return `buildForwardToGx()` immediately. |
| 9 | medium | Resilience — hardcoded DTMF audio asset on external Twilio subdomain | `getDtmfMp3()` and `autorespond.ts` hardcode `https://charcoal-louse-2621.twil.io/assets/dtmf_9.mp3`. If this Twilio asset account is deleted, restructured, or the URL changes, door-unlock silently fails (Twilio can't play the tone) and guests are locked out. No fallback path. | `functions/handleGuestInput.ts:168`, `functions/autorespond.ts:12`, `utils/test-callbox-response.ts:7` | Move the MP3 URL to an SSM parameter (`/config/callbox/${stage}/dtmfMp3Url`). Consider rehosting in an S3 bucket Kasa controls. |
| 10 | medium | Security — `setCode`/`removeCode` authorization undocumented | These Lambda functions have no HTTP events block (direct Lambda invocation) and no IAM resource policy in serverless.yml. The caller identity and authorization model are implicit. If any team or role has `lambda:InvokeFunction` on this account, they can create/delete access codes. | `serverless.yml:125-133` (no `events:` block, no `resourcePolicy:`) | Document the caller (likely CSS API or device-service) and add an explicit Lambda resource policy restricting invocation to the caller's IAM role. |
| 11 | low | Security — `SKIP_VERIFICATION` env var dead code | `SKIP_VERIFICATION` is injected into `webhook` and `handleGuestInput` env but no code reads it. The actual signature bypass only checks `STAGE/NODE_ENV === 'test'`. Dev config has `SKIP_VERIFICATION: true` — a reader expects this disables verification, but it doesn't. | `serverless.yml:107,121`, `utils/handler-wrapper.ts:35` | Either remove the dead env vars, or implement the check: `if (process.env.SKIP_VERIFICATION === 'true') return;`. |
| 12 | low | Architecture — SQS event parser reads only first record | `parseSQSEvent` reads `Records[0]` only. Current `batchSize: 1` protects against silent message drops, but it's a footgun if batchSize is ever increased. | `functions/utils/sqs-event-parser.ts:5` | Add `if (event.Records.length !== 1) throw new Error('Expected exactly 1 SQS record')`. |
| 13 | low | Runtime — `moment`/`moment-timezone` unused prod deps | Neither `moment` nor `moment-timezone` appear in any source import in master. They add unnecessary bundle weight on every Lambda cold start. | `package.json:69-70` | Remove from `dependencies`. Run `depcheck` to confirm. |
| 14 | low | Dependency health — 2 critical, 13 high npm audit findings | `fast-xml-parser` (devDep via serverless, critical: entity injection bypass); `basic-ftp` (devDep via mongodb-memory-server, critical: path traversal); `axios` (transitive runtime dep via twilio, high: prototype pollution chains, SSRF, credential leaks). | `npm audit` (2 critical, 13 high, 40 moderate) | `npm audit --omit=dev` to confirm runtime-only exposure. Pin `axios` to ≥1.16.0 via overrides if needed. Run `npm audit fix` for dev dep chains. |

---

## Architecture notes

### Service overview

callbox-automation automates the guest-entry workflow for Kasa buildings that use Twilio-connected intercom/callbox systems. When a guest's call comes in from the intercom:

1. **webhook** (`POST /incoming-call`) — verifies Twilio HMAC signature, looks up the building by caller ID (the callbox's Twilio number), and prompts for a 4-digit code via TwiML `<Gather>`.
2. **handleGuestInput** (`POST /validate-code`) — receives the DTMF digits, queries `Access` records, and if valid plays a DTMF tone (MP3 via Twilio `<Play>`) to trigger the door-unlock relay; otherwise retries up to `MAX_RETRIES` times then forwards to GX.
3. **autoRespond9** (`POST /autorespond-9`) — simple bypass endpoint that plays the door-unlock DTMF tone directly (used for testing or specific building types).
4. **setCode** / **removeCode** (direct Lambda invocation) — CRUD for `Access` records; called by downstream services (CSS API or device-service) when reservations are created/cancelled.
5. **callboxInstalled / Changed / Removed** (SNS→SQS) — maintains the `Callbox` registry from building-configuration events.

**Components:**
- Runtime: Node.js 24.x, AWS Lambda (Serverless Framework v4, `us-west-2`)
- Datastore: MongoDB Atlas (`callbox-automation` database, maxPoolSize=1)
- Telephony: Twilio Voice (HMAC signature-verified webhooks)
- Feature flags: ConfigCat (client initialized in `lib/feature-flags.ts` but **zero callers in master** — dead code)
- Notifications: `@kasadev/slack-notifications` (conditional on `USE_SLACK_NOTIFICATION=true`)
- Events out: AWS SNS `deviceStateChanged` topic on successful authorization
- Events in: SNS→SQS for callbox lifecycle (installed/changed/removed), `batchSize: 1`, `visibilityTimeout: 300`

**Shared Kasa libs used:** `@kasadev/logger`, `@kasadev/enums`, `@kasadev/db-schemas-ts`, `@kasadev/sns-events`, `@kasadev/slack-notifications`, `@kasadev/code-api-types`

**No scheduled cron jobs** — the service is purely event-driven.

### Bus-factor table

| Area | Primary author (2024–2026) | Share |
|------|---------------------------|-------|
| All business logic | Zoltan Feher | ~80% |
| Event handlers (installed/changed/removed) | Zoltan Feher | ~100% |
| API handlers (set/remove code) | Zoltan Feher + Norbert Pospischek | ~60/40 |
| Webhook / handleGuestInput | Zoltan Feher + Norbert Pospischek | ~70/30 |
| Dependency bumps | dependabot[bot] | 25/57 commits |

**Risk:** Zoltan Feher is the sole effective maintainer of business logic. No handoff documentation. Norbert Pospischek has minor contributions but is not a reliable backup for the call-flow logic.

---

## Production signals

**Log window used:** 14 days (Kasa Datadog retention limit). `git fetch` failed (SSH auth), so remote-commit recency unknown.

### Error archaeology

**0 errors in production in the last 14 days.** Error rate monitor (`Callbox-Automation (PROD): Error Rate Elevated`) is in OK state. The service is operationally healthy by error count.

### Activity summary (14d)

| Log message | Count | Notes |
|-------------|-------|-------|
| `get_connection_connecting` | 215 | Every Lambda invocation opens a cold connection (closeConnection on each request) |
| `get_connection_connected` | 215 | Paired with above |
| `callbox_handler_start` | 80 | Incoming calls routed to webhook handler |
| `validating_twilio_request` | 80 | Signature verification on every call |
| `create_accesses_called` | 70 | setCode invocations |
| `create_accesses_created_ids` | 69 | Successful code sets |
| `remove_accesses_called` | 65 | removeCode invocations |
| `build_gather_response` | 40 | Prompts for code (webhook) |
| `request_authorized` | 29 | Successful door unlocks |
| `callbox_call_not_authorized` | 10 | Failed code attempts |
| `callbox_call_multiple_accesses_found_for_code_and_building` | 3 | Data integrity issue (see finding #6) |

**Throughput:** ~6 incoming calls/day, ~2 authorizations/day, ~5 setCode/day, ~4.6 removeCode/day.

### Log noise & cost

- The double `get_connection_connecting/connected` pair (215 entries each) is the top log emitter — a direct consequence of `closeConnection()` being called after every request. Keeping the connection warm (Lambda warm invocations re-use the connection cache) would eliminate ~430 logs/14d (~30/day) and reduce MongoDB Atlas connection churn. This is moderate noise at current volume but would compound under higher load.
- `build_gather_response` logs the full AWS event object including the Twilio POST body (confirmed in DD). This is both PII (see finding #1) and unnecessary — ~40 large log entries per 14 days.
- Total production volume: 2103 logs / 14d ≈ 150/day. Low absolute volume; cost is negligible. No log spam emergency.

### Monitor & alerting coverage

| Monitor | Current state | Coverage gap |
|---------|--------------|--------------|
| `Callbox-Automation (PROD): Error Rate Elevated` | OK | Covers Lambda errors |
| _(none)_ | — | DLQ depth for callboxInstalled/Changed/Removed queues |
| _(none)_ | — | `callbox_call_multiple_accesses_found_for_code_and_building` alert (data integrity) |
| _(none)_ | — | Door-unlock rate anomaly (sudden drop to 0 = callboxes broken) |

**Gap:** The `callbox_call_multiple_accesses_found_for_code_and_building` event fired 3 times on June 13 with no alert. This is a silent data corruption symptom. A log alert on this message would catch duplicate code creation.

### Scheduled jobs inventory

No cron/EventBridge/scheduled Lambdas in this service. Purely event-driven. N/A for forgotten-automation check.

### Dead API surface

`/autorespond-9` (`autoRespond9` function): 0 traffic in 14d in production logs. This endpoint plays the door-unlock DTMF tone without any code validation. It appears to be a testing/alternative-building-type endpoint. No Twilio HMAC verification is applied to it (it doesn't go through `handlerWrapper`). If it is no longer used, it should be removed; if still in use for specific building types, it should be documented and have Twilio signature verification added.

---

## Cost

**Deployment:** AWS Lambda, all functions `us-west-2`, Node.js 24.x runtime.

**Lambda cost (estimated):**
- ~150 log entries/day → ~50-80 Lambda invocations/day (accounting for multi-log-per-invocation)
- Lambda at default 1024 MB, <1s duration: ~50 invocations/day × 0.001s × 1GB = negligible (<$0.01/month)
- Cold starts frequent (103 `INIT_START` events in 14d = ~7.4/day) due to low traffic — not a cost issue, but adds latency for callers.

**MongoDB Atlas:** Single `callbox-automation` database on shared cluster. Two small collections. Negligible cost. Connection-per-request pattern (closing on every invocation) causes higher connection rate than necessary — could be optimized but cost impact is zero at current scale.

**Datadog log ingestion:** ~2103 logs/14d ≈ 4.5k logs/month. At typical $0.10/GB, total is well under $1/month. The full-event-body logging (finding #1) should be tightened regardless — it's both PII and wasteful.

**Top savings levers:**
1. Remove dead deps (`moment`, `moment-timezone`) — reduces Lambda cold-start bundle size slightly.
2. Tighten logging (remove full event body, remove code from logs) — reduces Datadog ingestion and addresses PII findings.
3. No right-sizing opportunity: Lambda is already minimal. No container to resize.

---

## Skipped / caveats

- **git fetch origin** failed (SSH key auth unavailable); audited local `master` branch (HEAD `c77f42c`, 2026-02-02). The user's current checkout is on `chore/add-production-release-summary`; content audited is from `master`.
- **DLQ status**: AWS creds were valid (SSO PowerUser) but explicit SQS DLQ depth check was skipped — queue names are generated by the `@kasadev/serverless-sns-sqs-lambda` plugin and not directly listed in serverless.yml. Manual queue discovery would be needed. Recommend adding DLQ monitors (see monitor gap above).
- **ConfigCat feature-flags**: `lib/feature-flags.ts` is present but has no callers in master — not audited further (appears to be dead code).
- **Cost Step 5** (ECS sizing): Service is Lambda-only; no ECS tasks to right-size. CloudWatch/Lambda utilization metrics were not pulled (would require AWS SDK or CloudWatch console access; low priority given the service's scale).
