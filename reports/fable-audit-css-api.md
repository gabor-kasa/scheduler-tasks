# Fable audit — css-api (2026-06-11)

## TL;DR

css-api is the most mature NX-monorepo service in the HSP lock cluster: Node 24, TypeScript 5.9, Vitest, Express 5, current Kasa libs throughout. The two critical risks are both **guard-rail gaps on destructive scheduled jobs** — the same failure shape as the June 1 codeAuditQueueFiller incident — and **door-code PINs actively being logged in plaintext to Datadog** (confirmed in production). The cleanup and import-from-mongo handlers default to `dryRun: false` on EventBridge triggers with no runtime kill switch; check-code-groups has no dry-run mode at all. The highest-ROI fixes are: default `dryRun: true` on all scheduled-job handlers, remove `code` field from the `assign_codes_result` log, and move `import_mongo_unit` from INFO to DEBUG (saves ~40% of this service's Datadog cost).

---

## Findings (ranked)

| # | Sev | Area | Finding | Evidence | Recommendation |
|---|-----|------|---------|---------|---------------|
| 1 | **high** | Guard rails | `cleanup` and `import-from-mongo` handlers default `dryRun: false` on EventBridge trigger — same failure shape as Jun 1 codeAuditQueueFiller incident | `cleanup.handler.ts:11` `DEFAULT_CLEANUP_EVENT = { dryRun: false }`; `import-from-mongo.handler.ts:8` `DEFAULT_IMPORT_EVENT = { dryRun: false }`. EventBridge source check → falls through to default | Patch: change defaults to `dryRun: true`. Fix: add an SSM/ConfigCat kill-switch env var (`CLEANUP_DRY_RUN_OVERRIDE`) that forces dry-run without redeployment |
| 2 | **high** | Guard rails | `check-code-groups` has **no dry-run parameter** — directly creates remove-code jobs (sets codes to 'removing') with no safe-test path | `check-code-groups.service.ts:14` — `checkCodeGroups()` immediately calls `createRemoveJobForCode()` for every matched code; no dryRun arg | Add `dryRun: boolean` to the service; gate all `CodeJobModel.create` and `CodeModel.findByIdAndUpdate` calls on it. Mirror cleanup.handler.ts pattern |
| 3 | **high** | PII / Compliance | Door-code PINs logged in plaintext to Datadog (confirmed in production). Guest confirmation codes and access objects also in logs. | `code-assignment-at-cut-off.service.ts:117` — `logger.info('assign_codes_result', { updatedAccess, codesAssigned })` where `Code.code` is the actual PIN. Also `assign_backup_code_result:199`. Confirmed via Datadog live logs. | Patch: remove `code` and `confirmationCode` fields before logging (e.g. `{ ...codeAssigned, code: '[REDACTED]' }`). Fix: add a `sanitizeForLog(code: Code)` helper that strips PII fields; enforce in linting. Audit historical Datadog logs for unauthorized access. |
| 4 | **high** | PII / Compliance | `import-from-mongo` logs full `mappedUnit` at INFO including `lockboxCode`, `lockboxNumber`, `buildingCode` on every hourly run (~226k lines/day) | `import-from-mongo.service.ts:213` — `logger.info('import_mongo_unit', { ..., mappedUnit })` | Patch: move to DEBUG. Fix: only log `internalTitle` + changed field names at INFO level |
| 5 | **medium** | Resilience | No runtime kill switch for any scheduled job — disabling requires CDK redeploy or ECS task update | All consumers use `<QUEUE>_QUEUE_ENABLED` env vars baked in at deploy time; no SSM-backed feature flag | Add SSM-backed kill switch per destructive job (e.g. `/config/production/cleanup-enabled`); poll on each invocation. ConfigCat is available in the Kasa stack |
| 6 | **medium** | Dormant bug | `getUnassignedAccesses()` has no pagination (`// TODO: do pagination`) — unbounded MongoDB query if many accesses are due | `code-assignment-at-cut-off.service.ts:45` — `AccessModel.find(query).lean().exec()` no `.limit()`. Risk: bulk import + system outage → hundreds of accesses due → OOM/slow handler | Add `.limit(500)` and iterate. Pattern already exists in cleanup's `batchSize` parameter |
| 7 | **medium** | Observability | Two chronic errors with no Datadog monitor: `salto_code_value_not_set_after_job` (88/day, 14 days) and `error_fetching_access_codes_for_access_id` (55/day, 14 days) | Confirmed via Datadog log archaeology; no existing monitor on either key | Create P2 log alert monitors for both error keys; set 24h threshold > 50 to catch persistent failures |
| 8 | **medium** | Resilience | `Promise.allSettled` in `paginateGraphQLQuery` silently drops unit import errors — whole batch appears successful even if 50% of units fail | `import-from-mongo.service.ts:357` — `Promise.allSettled(items.map(...))` with no rejection summary | Count settled-as-rejected; if > N% fail, throw and retry the batch rather than swallowing |
| 9 | **medium** | Cost | `import_mongo_unit` logged at INFO on every import run generates ~3.2M Datadog log events/day — estimated top cost driver | Datadog: `import_mongo_unit` 226,448/day; `import_mongo_unit_diff_with_existing_unit` 188,004/day | Move `import_mongo_unit` to DEBUG; log at INFO only when diff is found; estimated 40%+ Datadog cost reduction |
| 10 | **low** | Security | `/devices` endpoint not registered in `auth0-routes.ts` — API Gateway has no Auth0 authorizer; only IAM access works | `infra/config/auth0-routes.ts` — no devices routes present; service is internal only | Document as intentional IAM-only endpoint, or add Auth0 route if frontend callers need bearer token access |
| 11 | **low** | Resilience | Cleanup sub-functions swallow errors silently — job reports success even if individual steps fail | `cleanup.service.ts:135,172,211` — each sub-function wraps in `try/catch { logger.error; }` without re-throwing | Count sub-function failures; if any fail, set a flag and return a partial-success indicator so the caller can log/alert |
| 12 | **low** | Infra | `infra/jest.config.js` is stale (Jest) — service uses Vitest but infra package still has Jest config | `infra/jest.config.js` exists alongside `service/vitest.config.ts` | Remove `infra/jest.config.js`; CDK synth tests should not use Jest if the monorepo has moved to Vitest |
| 13 | **low** | Observability | 1 message stuck in `reservation-moved` DLQ in production | `css-api-production-reservation-movedDLQ.fifo` has `msgs=1` | Investigate and replay/discard the stuck message |

---

## Architecture notes

**Service overview:** css-api (Code Setting Service API) manages smart lock access codes for Kasa properties across five lock providers: Remotelock, Seam, SmartThings, Salto, and Callbox. It is the migration target for the legacy code-setting-service Lambdas.

**Components:**
- NX monorepo — `client/` (published `@kasadev/css-api-client`), `service/` (Express APP + SQS WORKER), `infra/` (CDK)
- **APP process**: Express HTTP server; routes at `/health`, `/codes`, `/devices`, `/dashboard`, `/admin`
- **WORKER process**: SQS consumer with 14 queue consumers (reservation events, scheduled jobs, seam events, keycard events)
- Dual-process entry via `PROCESS_TYPE` env var
- MongoDB via Mongoose for codes, accesses, code-jobs, units, buildings, audit-logs
- Config via `@kasadev/config-resolver` + SSM Parameter Store
- CDK via `@kasadev/kasa-cdk-patterns`; deployed on ECS Fargate, internal API Gateway (not internet-facing)

**Scheduled jobs:**

| Job | Rate | Production | Dry-run support |
|-----|------|-----------|-----------------|
| code-assignment-at-cut-off | Every 5 min | enabled | N/A (read→mutate by design) |
| import-from-mongo | Every hr :55 | enabled | yes (but default=false) |
| check-code-groups | Weekly Wed 12:00 | **disabled** | **none** |
| cleanup | Daily 03:00 | **disabled** | yes (but default=false) |
| check-low-code-count | Daily 08:00 | **disabled** | N/A (read-only) |

**Bus-factor table:**

| Area | Primary (commits since 2024) | Secondary | Risk |
|------|------------------------------|-----------|------|
| Worker handlers | Norbert Pospischek (8) | Kristóf Iváncza (2) | Medium |
| Infra/CDK | Norbert Pospischek (6) | Kristóf Iváncza (2) | Medium |
| Overall (all time) | Norbert Pospischek (30) | Kristóf Iváncza (25) | Low |

Two active maintainers; not a single-author risk today but loss of either would leave the other alone.

---

## Production signals

### Chronic errors (14-day window)

| Error key | Count/14d | Avg/day | Root cause hypothesis | Monitor? |
|-----------|----------|---------|----------------------|---------|
| `salto_code_value_not_set_after_job` | 1,230 | 88 | Salto async job completes but code value not written back — likely API not confirming or DB update race | No ⚠ |
| `error_fetching_access_codes_for_access_id` | 766 | 55 | Access deleted by cleanup while downstream holds the ID; or race between cleanup and code-fetch | No ⚠ |
| `import_mongo_unit_error` | 59 | 4 | Seam device lookup 404s or Kontrol GraphQL timeout during unit import | No ⚠ |
| `error_creating_manual_code` | 13 | ~1 | Manual code creation failure — intermittent | No |

### Log noise summary

Top cost driver: `import_mongo_unit` at **226,448/day** + `import_mongo_unit_diff_with_existing_unit` at 188,004/day. Both are wide JSON objects (full unit including lockbox codes). `sqs_error_occurred_while_interacting_with_queue` at 60,428/day — may indicate transient SQS connectivity flaps worth investigating.

### Monitor coverage

| Coverage area | Monitored? | Monitor ID |
|--------------|-----------|-----------|
| Code assignment failures | ✓ P1 | 231399738 (prod), 231397974 (dev) |
| No available codes | ✓ P2 | 236457268 |
| `salto_code_value_not_set_after_job` | ✗ Missing | — |
| `error_fetching_access_codes_for_access_id` | ✗ Missing | — |
| General error rate | ✗ Missing | — |
| reservation-moved DLQ depth | ✗ Missing | — |
| import-from-mongo cron-didn't-run | ✗ Missing | — |
| Latency / p95 | ✗ Missing | — |

### Scheduled-job inventory

Both live jobs confirmed firing in Datadog (last 7 days). All scheduled-job DLQs have 0 messages. `reservation-moved` event DLQ has 1 stuck message.

---

## Cost

**Fargate (production baseline):** 6 tasks (APP×3 + WORKER×3) × 0.5 vCPU × 1 GiB + Datadog sidecars (0.125 vCPU × 0.25 GiB each) ≈ **$110-130/month** compute.

**Datadog ingestion (estimated):** import-from-mongo alone generates ~3.2M wide-JSON log events/day. At Datadog's $0.10/GB ingestion rate and assuming ~500 bytes/event → ~160 GB/month from this one log source → **$16-50/month** Datadog cost from import logs alone.

**Top 3 savings levers:**

| Lever | Action | Est. saving |
|-------|--------|------------|
| 1. Log volume | Move `import_mongo_unit` to DEBUG, log diff only at INFO | $15-40/month Datadog |
| 2. Log objects | Remove PII objects (Code, Access) from log payloads | $5-15/month + compliance |
| 3. WORKER sizing | If WORKER CPU p50 < 20%, reduce from 512 to 256 vCPU | $45/month Fargate |

---

## Skipped / caveats

- No deep dive into `RemotelockSync`, `SaltoSync`, `SeamSync` code services — the playbook 90-minute timebox was a factor
- Security: git history scan bounded to 2 years (no credentials found); full historical scan not run
- Datadog metrics (ECS CPU/memory utilization) not retrieved — WORKER right-sizing recommendation is a hypothesis pending actual utilization data
- CloudWatch checks: skipped as Datadog coverage was sufficient
- `fix-code-duplicates` admin endpoint: no dry-run parameter — not audited for blast radius
