# Fable audit — seam-sync (2026-06-14)

> **Audited:** HEAD `7789fbb` (2026-06-04) on branch `chore/HSP-3368-graceful-seam-error-logging`
> Local checkout was on a feature branch (dirty vs master). Audited in-place; master may differ slightly.
> `git fetch` failed (SSH key not available overnight).

## TL;DR

seam-sync is a cleanly structured lock-platform sync service with good shared-lib adoption, no database, and current Node/TS versions. However, it has several urgent issues found in production signals. **Access PIN codes (guest door codes) are being logged in plain text to Datadog** — confirmed via live log inspection; every `access_code.set_on_device` webhook body is stored in Datadog with a `code` field visible. Separately, Seam is emitting `access_grant.could_not_create_requested_access_methods` events at 22,800/day (319K in 14 days), indicating frequent access method creation failures that likely affect guests getting their door codes. No Datadog monitors exist for this service. Total log volume is 11.6 million in 14 days — 4 redundant info lines per event drive most of that volume. Estimated monthly savings from log consolidation: ~30–40% log cost reduction.

---

## Findings (ranked)

| # | Sev | Area | Finding | Evidence | Recommendation |
|---|-----|------|---------|----------|----------------|
| 1 | high | Security / Compliance | Access PIN codes (door codes) logged in plain text to Datadog | `webhook.service.ts:42` `logger.info('processing_webhook', { body })` — Datadog query confirmed `code` field in `body_keys` for `access_code.set_on_device` events (1.2M webhook logs in 14d, ~86K/day) | **Immediate:** strip `code`/`pin` fields before logging. Add `sanitizeWebhookPayload()` that redacts sensitive keys. Root cause: no log-sanitization layer for Seam webhook bodies. `event_payload` (line 66) also logs the enriched body — same fix needed. |
| 2 | high | Security | API Gateway prod/dev auth tokens committed in `infra/cdk.context.json` | `infra/cdk.context.json` lines: `ssm:/config/apigw/dev/token` and `ssm:/config/apigw/production/token` — 96-char token values present in git history (token values redacted from this report) | **Flag for rotation** — rotate both tokens in SSM. To prevent recurrence: either exclude the token SSM entries from cdk.context.json (delete from file + re-synth with `--no-previous-cdk-context`), or move to `--context` flag at synth time for these sensitive entries. |
| 3 | high | Ops / Reliability | Seam fails to create access methods 22,800×/day — guests may not get door codes | Datadog 14d: `handling_failed_to_create_access_method` = 319,112 info logs; event_type = `access_grant.could_not_create_requested_access_methods`. Seam fires this when it cannot create the physical lock code after an access grant is set up. | Investigate root cause: which devices/device-types fail, is it transient or permanent. The worker handler correctly publishes `seamFailedToCreateAccessMethodEvent` — verify downstream consumers (CSS API?) retry or alert. Add a Datadog error-rate monitor on this event type. Consider logging at `warn` not `info`. |
| 4 | high | Ops / Bug | `error_getting_access_grant_code` fires 28,000×/day — callers polling deleted grants | Datadog 14d: 393,815 `warn` logs, error = `"Access grant not found"` (SeamHttpApiError). CSS API is calling `GET /access-grant/:id/code` after the access grant has already been deleted from Seam. | Likely a stale-reference or race-condition bug in the caller: either (a) callers poll for the code after deletion, or (b) grant is deleted while in-flight. Short-term: the controller correctly returns 404 — callers must handle it. Root-cause fix: investigate CSS API / device-service for stale grant IDs. |
| 5 | medium | Bug | `error_deleting_code` — 180×/day, `access_code_managed_by_access_grant` | Datadog 14d: 2,530 errors. Seam returns `access_code_managed_by_access_grant` (HTTP 400). Callers invoke `POST /code/remove-access-codes` on codes owned by access grants. | Fix in caller (CSS API): use `DELETE /access-grant/:id` instead of `POST /code/remove-access-codes` for access-grant-managed codes. Alternatively, add a passthrough in the service: detect `access_code_managed_by_access_grant` and re-route to `seamClient.accessGrants.delete`. |
| 6 | medium | Security / AuthZ | All `/access-grant` routes and 3 other routes absent from `auth0-routes.ts` | `infra/config/auth0-routes.ts` has no entries for: `POST /access-grant`, `DELETE /access-grant/:id`, `GET /access-grant/:id/code`, `GET /access-grant/unit/:unitId`, `GET /code/:deviceId/unmanaged-codes`, `POST /code/convert-unmanaged-code/:accessCodeId`, `GET /device/:deviceId/unlock-availability` | Add all missing routes with correct `permissions` entries. Service is internal-only (VPC, `internetFacing: false`) so exploitability is low, but write operations on access grants should have explicit auth. |
| 7 | medium | Ops / Cost | No Datadog monitors for seam-sync | Monitors API: 0 monitors found for `seam-sync`. Failures like the 22,800/day access-method failures and 2,530 code-delete errors are silent. | Create at minimum: (1) error rate monitor on `service:seam-sync`, (2) warn rate on `error_getting_access_grant_code` and `handling_failed_to_create_access_method`, (3) DLQ depth on `seam-webhook-listener-queue`. |
| 8 | medium | Cost / Log noise | 11.6M log lines in 14 days — 4–5 redundant info lines per webhook event | Datadog 14d top messages: `processing_webhook` 1.2M, `event_payload` 1.2M, `publishing_seam_device_event` 1.2M, `seam_device_event_published_to_worker_for_processing` 1.2M. Worker adds 4+ more per message. | Consolidate the 4-line webhook publish sequence into one structured log with outcome. Same for worker. Estimated reduction: ~8M → ~2.5M lines/14d (~68% volume drop). |
| 9 | medium | Bug | `deleteCodesFromDevices` partial-state on failure | `code.service.ts:63`: `Promise.all(ids.map(id => delete(id)))` — if one fails after others succeed, those deletions are permanent; caller gets an error but partial state remains | Return partial-success response `{ deleted: string[], failed: string[] }` so callers can retry only failed IDs. Or document that this is fire-and-forget and each deletion is idempotent from the caller's perspective. |
| 10 | medium | Resilience | No HTTP timeout on general Seam API calls | `seam.client.ts:13-21`: only `waitForActionAttempt.timeout: 15000` is set. List/get/create calls have no timeout; a hung Seam connection blocks Express indefinitely | Set `timeout` on the Seam SDK constructor (or use `AbortSignal` per call). A 30s global timeout is reasonable. Prevents cascade when Seam degrades. |
| 11 | medium | Resilience | Seam `getDeviceById` call on every webhook with a `device_id` | `webhook.service.ts:53-57`: calls Seam API to fetch `display_name` on every event. At 86K events/day this is 86K Seam API calls/day just for enrichment | Decouple enrichment: let downstream consumers look up `display_name`, or cache device names by ID with a TTL. Removes failure point from the webhook hot path. |
| 12 | low | Bug | `convertUnmanagedCode` TOCTOU — convert then immediate GET may return stale | `code.service.ts:85-95`: `unmanaged.convertToManaged()` then immediately `accessCodes.get()` — Seam convert is async; GET may 404 briefly | Use the `waitForActionAttempt` SDK option for the convert call if available, or add short retry loop (2-3 attempts with 500ms delay) on the subsequent GET. |
| 13 | low | Resilience | SQS consumer `visibilityTimeout` not set — default 30s may cause duplicate delivery | `queue-consumer.service.ts:71`: no `visibilityTimeout` in `Consumer.create`. Processing `access_method.issued` (2 SNS publishes + Seam call + all logging) could exceed 30s under slow Seam | Set `visibilityTimeout: 60` (or 90s) in Consumer options. |
| 14 | low | Deps | `esbuild` high-severity CVE in dev/build tooling | `npm audit`: `tsup` in client/infra workspace pulls vulnerable `esbuild`. No runtime impact. | Update `tsup` in client and infra to a version with patched `esbuild`. |

---

## Architecture notes

### Service map

```
Seam Platform ──POST /webhook──► APP (Express)
                                    │
                              validateWebhookMiddleware (svix signature)
                                    │
                              processWebhook()
                                    │
                              getDeviceById() ◄── Seam API (enriches display_name)
                                    │
                              publishSeamDeviceEvent ─────► seamDeviceEvent SNS
                                                                    │
                                                         seam-webhook-listener-queue (SQS)
                                                                    │
                                                         WORKER (sqs-consumer)
                                                         webhookListenerHandler
                                                                    │
                                    ┌───────────────────────────────┼───────────────────────────────┐
                                    ▼                               ▼                               ▼
                           deviceStateChanged SNS    seamFailedToSetCodeOnDevice SNS    seamAccessMethodIssued SNS
                                    (+ 3 more SNS topics)

CSS-API ──► APP (/device/*, /code/*, /access-grant/*, /webhook)
         Internal only (VPC, internetFacing: false, internalApiGateway: true)
```

**Components:**
- **APP**: Express 5, Auth0 JWT via internal API Gateway, Seam SDK singleton, no DB
- **WORKER**: sqs-consumer v15, subscribes to seamDeviceEvent SNS → fans out to 6 downstream SNS topics
- **Infra**: ECS Fargate — 3 APP + 3–5 WORKER tasks in production, kasa-cdk-patterns CDK
- **Secrets**: SEAM_API_KEY and SEAM_WEBHOOK_SECRET from SSM (correct pattern)
- **Queue**: `seam-webhook-listener-queue` with 14-day retention, DLQ + Slack alerts configured

### Bus-factor table

| Area | Primary | Secondary | Risk |
|------|---------|-----------|------|
| All service src | Kristóf Iváncza | Gabor Balazs | Medium — 2 active maintainers |
| Infra CDK | Kristóf + Gabor | Norbert, Zoltan (5 each) | Medium |
| Client package | Kristóf + Gabor | — | Medium |

No single-author areas. Devin AI (28 commits) is an AI assist tool, not a human maintainer. Relatively healthy.

---

## Production signals

**Log retention window used:** 14 days (full Datadog retention).

### Error archaeology

| Message | Count (14d) | Level | Root cause | Status |
|---------|-------------|-------|------------|--------|
| `error_getting_access_grant_code` | 393,815 | warn | Callers polling `GET /access-grant/:id/code` after the grant is deleted from Seam — "Access grant not found" (SeamHttpApiError) | Chronic; 28K/day; stale ref bug in caller |
| `handling_failed_to_create_access_method` | 319,112 | info | Seam fires `access_grant.could_not_create_requested_access_methods` — Seam cannot create the physical lock code after grant setup | Chronic; 22.8K/day; possible guest impact |
| `error_deleting_code` | 2,530 | error | `access_code_managed_by_access_grant` HTTP 400 — caller using wrong delete endpoint | Chronic; 180/day; callers sending codes to wrong API |
| `failed_to_publish_seam_device_event` | 9 | error | SNS publish failures | Sporadic; low |
| `error_getting_device_from_seam` | 37 | error | Seam device lookup failure | Sporadic |
| `error_creating_access_grant` | 15 | error | Seam API error | Sporadic |
| `error_deleting_access_grant` | 15 | error | Seam API error | Sporadic |

### Log noise summary

Total volume: **11.6 million lines in 14 days** (≈830K/day).

Top 4 messages (all from webhook publish path in APP) account for **4.84 million** lines:

| Message | 14d count | Fix |
|---------|-----------|-----|
| `processing_webhook` | 1,211,065 | Consolidate |
| `event_payload` | 1,211,059 | Consolidate |
| `publishing_seam_device_event` | 1,211,059 | Consolidate |
| `seam_device_event_published_to_worker_for_processing` | 1,211,059 | Consolidate |

Worker adds similar redundancy: `handling_sqs_queue_message` + `successfully_handled_sqs_queue_message` = 2.4M more lines.

**Opportunity**: collapsing the 4-line APP sequence and 2-line WORKER sequence to 1 line each would cut ~6.5M lines/14d from this service (~56% reduction).

### Monitor coverage gaps

**Zero monitors found for seam-sync.** Proposed monitors:

| Failure mode | Proposed monitor | Urgency |
|---|---|---|
| Chronic `access_grant.could_not_create_requested_access_methods` | Warn-rate monitor: `service:seam-sync message:handling_failed_to_create_access_method` | High |
| Code-delete mismatch | Error-rate monitor: `message:error_deleting_code` | Medium |
| Access grant not found storm | Warn-rate: `message:error_getting_access_grant_code` | Medium |
| DLQ depth | `seam-webhook-listener-queue` ApproximateNumberOfMessagesNotVisible > 0 | High |
| ECS task health | CPU/memory utilization + task count < desired | Medium |
| Webhook endpoint 5xx | HTTP 500 rate on `/webhook` | High |

### Scheduled-job inventory

No cron/EventBridge jobs defined. Entirely event-driven (webhook push → SNS → SQS).

### Dead API surface

N/A — no route-level traffic data available for internal ALB; service has no HTTP analytics indexing.

---

## Cost

**Infra footprint estimate (rough):**
- APP: 3 tasks × 0.5 vCPU + 1 GB RAM = ~$45–60/month (Fargate pricing)
- WORKER: 3–6 tasks × 0.5 vCPU + 1 GB RAM = ~$45–90/month
- Datadog log indexing: 11.6M events/14d × 30/14 = ~25M/month. At ~$1.70/million (14-day retention) = **~$42/month for this service alone**

**Top savings levers:**
1. **Consolidate log lines per webhook/worker message** (finding #8) — from ~10 lines/event to ~2. Estimated reduction: ~68% of volume → **saves ~$28/month** in Datadog indexing.
2. **Remove `getDeviceById` enrichment from webhook hot path** (finding #11) — eliminates 86K Seam API calls/day, reduces latency, and indirectly reduces error volume from Seam API failures.
3. AWS right-sizing: no CloudWatch data available (SQS creds failed). Worker scaling at `desiredCount: 3` is reasonable for the event volume but should be reviewed against actual CPU utilization.

---

## Skipped / caveats

- **git fetch failed** (SSH key not available overnight). Audited HEAD `7789fbb` (2026-06-04). Local checkout is on `chore/HSP-3368-graceful-seam-error-logging` branch, not master.
- **AWS SQS/CloudWatch checks skipped** — `aws sqs list-queues` returned `InvalidClientTokenId` (SQS region credential scope mismatch with overnight SSO session). DLQ depth and ECS CloudWatch metrics not retrieved.
- **CDK pattern auth0 behavior for unlisted routes** — could not confirm whether `kasa-cdk-patterns` blocks or passes through requests for routes not in `auth0Routes`. Finding #6 assumes undefined/potentially unprotected behavior; actual enforcement depends on the shared pattern.
- **`handling_failed_to_create_access_method` impact** — 22,800/day is large but unclear what fraction represents actual guest-impact (some may be retried successfully by Seam or are for property-testing grants). Further investigation in CSS API or reservation data needed to determine blast radius.
- **Datadog log volume counted only `@env:production` subset** — total (all envs) is higher.
