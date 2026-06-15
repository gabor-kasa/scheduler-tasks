# Fable audit — salto-sync (2026-06-13)

## TL;DR

salto-sync is a focused Serverless Lambda service in reasonable structural shape — clear handler pattern, good rate limiting, proper SSM-backed secrets. However it carries three high-severity issues demanding immediate action: a scan-inventory loop that exits entirely on the first DB failure (silently skipping all remaining devices); IQ secret/pin fields being logged at debug level (OTP generation materials in Datadog); and a catastrophic log-noise bug where `more_than_one_lock_found_for_unit` fires ~1,340 times per 30-minute run, accounting for 2.7M warn-level log lines in 14 days (~70% of total service volume). The noise issue is also a data-quality gap: all multi-lock units are silently excluded from battery/status updates. Zero test coverage and a single Datadog monitor are the main operational risks beyond the above.

## Findings (ranked)

| # | Sev | Area | Finding | Evidence | Recommendation |
|---|-----|------|---------|----------|----------------|
| 1 | high | Bug | `scanInventory` for-loop uses `return` instead of `continue` on device DB failure — exits entire handler, silently skips all remaining devices | `scan-inventory.ts:83` | Change `return` → `continue` so one DB error doesn't abort the whole run |
| 2 | high | Log noise / Data quality | `more_than_one_lock_found_for_unit` fires ~1,340×/run at `warn` level → 2.7M lines in 14d; those units are silently excluded from device status updates | DD: 2,699,442 hits / 14d on `service:salto-sync-production-scanInventory` | Fix root cause (multi-lock units in DB) or implement "pick primary lock" logic; change log to `info` or drop entirely once fixed |
| 3 | high | Security | `saltoIq.repository.ts` logs the full IQ document at `debug` level, including `secret` and `pin` fields used to generate OTP codes for remote unlock | `saltoIq.repository.ts:19` | Redact sensitive fields from the log: log `iqId` only, not the full `iq` object |
| 4 | high | Dependencies | `mongoose` vulnerable to NoSQL injection via `$nor` operator in `sanitizeFilter` (GHSA-wpg9-53fq-2r8h, CVSS 7.5, affects >=9.0.0 <=9.1.5) | `npm audit` | Upgrade mongoose (transitive via `@kasadev/db-schemas-ts`) to ≥9.1.6 |
| 5 | medium | Bug | `remote-unlock/utils.ts` accesses `lock.data.iqId` without checking that `lock.data` is non-null. If a lockId is valid but not in the DB, `findSaltoLockById` returns `{success:true, data:undefined}` → TypeError crash | `utils.ts:10` | Guard: `if (!lock.success \|\| !lock.data) throw new Error('Lock not found')` |
| 6 | medium | Security / PII | `handle-http-lambda-wrapper.ts` logs the full `APIGatewayEvent` at `info` level on every invocation — includes Authorization headers (Bearer token) and the full request body (lockId, requestedBy, requestedByService) | `handle-http-lambda-wrapper.ts:36` | Log `eventName` and `requestId` only; strip headers and body from the startup log |
| 7 | medium | Prod signals | `retrying_on_rate_limit` fires 570× in 14d on scan-inventory — Salto API rate limits are being hit regularly; each retry adds 1–8s latency per lock | DD: 570 warn events | Consider increasing `minTime` from 125ms to 200ms (5 req/s) or reducing Lambda memory/concurrency to natural throttle simultaneous runs |
| 8 | medium | Prod signals | `remoteUnlock` returns `internal_error` (Salto 404 "Cannot find pin for accessor") — user has no PIN provisioned in Salto IQ, causes silent remote-unlock failure for guests | DD sample: 2026-06-10 14:23, ErrorCode 3104 | Detect this specific error code and return a structured "pin_not_found" error to the caller; alert on repeated failures for same lock |
| 9 | medium | Architecture | `command` field is extracted from `remoteUnlock` body (`const { lockId, command } = body`) and logged but never passed to `api.remoteUnlock()`, which always sends `locked_state: 'unlocked'`. Dead or incomplete code — cannot lock via this endpoint | `remote-unlock.ts:10`, `schema.ts` | Either add `locked_state: command` to the Salto API call or remove the `command` param from schema and logging |
| 10 | medium | Monitoring | Only 1 Datadog monitor covers salto-sync ("Salto user created as SUSPENDED"). No monitor for: error rate spike, scan-inventory not running, remoteUnlock failure rate, rate-limit retries | DD monitor search | Add: cron-missed monitor for scanInventory (no log in >35 min), error-rate monitor for `internal_error`, rate-limit storm monitor |
| 11 | low | Log noise | `update_not_needed_because_there_were_no_changes` logs at `info` level per device per run → 324K lines in 14d; `no_units_were_found_with_the_provided_salto_lock_device_id` → 165K lines in 14d | DD aggregate | Downgrade to `debug` or drop; per-device logs inside a cron loop dominate ingestion |
| 12 | low | Architecture | Variable `isDataChanged` in scan-inventory holds the return of `compareDeviceData()` which returns `true` when data is **unchanged** (keys.every equals) — inverted semantics create maintenance hazard | `scan-inventory.ts:73`, `compare-device-data.ts` | Rename to `isDataUnchanged` or invert the comparison return and fix the condition |
| 13 | low | Dependencies | `lodash` high-severity code injection via `_.template` key names (GHSA-r5fr-rjxr-66jc); `flatted` DoS in parse() (GHSA-25h7-pfq9-p65f); `esbuild` RCE in Deno context (GHSA-gv7w-rqvm-qjhr) | `npm audit` | These are devDep transitives; run `npm audit --production` to confirm prod exposure; update serverless/esbuild toolchain |
| 14 | low | Runtime | `strict: false` in tsconfig.json; zero test files; CI runs only lint + typecheck + sls-build — no unit or integration tests | `tsconfig.json`, `.github/workflows/test.yml` | Enable `strict: true` incrementally; add at minimum handler-level unit tests for the OTP logic and scan-inventory loop |

## Architecture notes

### What salto-sync does

salto-sync is a Serverless Framework (v4) Lambda service acting as Kasa's Salto KS smart-lock integration adapter. It provides two surfaces:

1. **Scheduled cron (every 30 min)** — `scanInventory`: fetches all sites and locks from Salto Connect API, maps battery levels, updates MongoDB `Devices` collection.
2. **HTTP endpoint** — `remoteUnlock` (POST `/remote-unlock`, IAM-authed via API GW): looks up IQ/secret/pin from Mongo, generates an MD5-based OTP, and calls Salto to unlock the lock.
3. **14 direct-invoke Lambda handlers** — CRUD for users, access groups, roles, sites, locks — invoked by other Kasa services, not HTTP.

**Component list:**
- `ConnectAPI` — Salto OAuth2 token client + Bottleneck rate limiter (8 req/s, max 5 concurrent) + async-retry (3× on 429)
- Mongo collections: `salto-locks`, `salto-iqs`, `Devices`, `Unit` (shared via db-schemas-ts)
- Shared libs: `@kasadev/logger`, `@kasadev/db-schemas-ts`, `@kasadev/code-api-types`, `@kasadev/eslint-config-typescript`
- Deployment: Serverless Framework v4 via Seed CI; Node 24.x, TypeScript 6.0.3; per-Lambda bundling; 128 MB default / 256 MB for scanInventory and remoteUnlock; 29s timeout

**Preflight:** Local checkout on `fix/HSP-3601-content-type-header` (1 commit ahead of master). Audit on origin/master (HEAD `20ee384`, "Bump @kasadev/db-schemas-ts from 12.7.1 to 13.1.0"). A `salto-sync-ts6` worktree exists (TypeScript 6.0 trial, already in production per package.json).

**Structural positives:** No hand-rolled secrets (all via SSM/Secrets Manager references in serverless.yml), good Zod input validation on schemas, Bottleneck rate limiter protects against Salto API abuse, pagination handled correctly in `callAPIWithPagination`, retry-only-on-429 avoids retry storms for 4xx errors.

### Bus-factor table (2-year git window)

| Author | Commits | Notes |
|--------|---------|-------|
| Zoltan Feher (two git identities) | 31 | Core logic: ConnectAPI, scan-inventory, remote-unlock OTP |
| dependabot[bot] | 22 | Dep bumps only |
| Norbert Pospischek (two identities) | 16 | Access groups, named Dependabot maintainer |
| Gabor Balazs | 10 | Infra / CI / pipeline |
| markszavin-kasa | 5 | Minor fixes |
| Others | ~8 | Scattered |

**Assessment:** Zoltan Feher is the effective sole author of the production-critical path (OTP generation, scan-inventory loop, ConnectAPI client). Norbert is the maintenance owner. If either leaves, the service has no natural second owner. The OTP algorithm in particular (`generateRemoteUnlockOTP`, `validtateOTPFormat`) is undocumented and has no tests.

## Production signals

**Log retention window used:** 14 days (Kasa Datadog retention).

### Chronic errors (14-day window)

| Error key | Count (14d) | Service | Root cause | Monitor? |
|-----------|-------------|---------|-----------|----------|
| `retrying_on_rate_limit` | 570 | scanInventory (9), various handlers | Hitting Salto 429 during bulk site/lock fetches | No |
| `internal_error` (Salto 404, "Cannot find pin for accessor") | ~12 | remoteUnlock | User provisioned in Salto but has no PIN in the IQ; OTP attempt fails | No |
| `internal_error` (Salto 403, "User does not have permission") | ~15 | updateUser | Cross-site user update attempted | No |
| `internal_error` (Salto 503) | Burst (2026-06-10 12:35) | getUsers, getAccessGroupUsers | Salto API briefly unavailable | No |

**Root-cause analysis for top errors:**
- **retrying_on_rate_limit**: The scan-inventory fetches locks for all sites concurrently via `Promise.all(sites.items.map(...getLocksForSite...))`, which can saturate the 8 req/s limiter. With Bottleneck queuing and the 125ms minTime, parallel site fetches are serialized but if there are >8 sites the queue fills up and Salto's side still sees bursts. The 570 retries over 14 days at 3× retries each ≈ ~190 rate-limit hits — manageable but not zero.
- **remoteUnlock 404 (pin not found)**: Users are created in Salto but `createPinForUser` may not have been called, or the PIN expired. The handler throws a generic error; the caller has no way to distinguish "lock mechanically failed" vs "user has no pin". No alerting in place.

### Log noise summary

| Message | Volume (14d) | Level | Source | Action |
|---------|-------------|-------|--------|--------|
| `more_than_one_lock_found_for_unit` | 2,699,442 | warn | scanInventory | Fix data + drop/debug log |
| `update_not_needed_because_there_were_no_changes` | 324,487 | info | scanInventory | Downgrade to debug |
| `no_units_were_found_with_the_provided_salto_lock_device_id` | 165,433 | warn | scanInventory | Downgrade to debug; expected for Salto locks not yet mapped |
| `update_needed_because_there_were_changes_in_device_data` | 1,253 | info | scanInventory | Keep; low volume, useful signal |

**Top savings opportunity:** `more_than_one_lock_found_for_unit` at 2.7M warn logs dominates the service's Datadog bill. Fixing the underlying data model (or implementing "pick-primary-lock" logic) and dropping this to a debug or silent operation could eliminate ~70% of total service log volume. Rough estimate: if Kasa pays ~$0.10/GB ingested and average log line is ~0.5KB, 2.7M × 0.5KB = 1.35GB → ~$0.14/14d → ~$3.60/month savings — small in absolute terms but the ratio (eliminating noise that masks real errors) is the real gain.

### Monitor coverage gaps

Only 1 monitor exists for salto-sync: **"Salto user created as SUSPENDED"** (log alert, status OK).

Gaps vs. failure modes found in this audit:

| Failure mode | Monitor needed | Proposed query |
|---|---|---|
| scanInventory not running (cron missed) | Log alert: no `scan_inventory_finished` in 35 min | `service:salto-sync-production-scanInventory message:scan_inventory_finished` count < 1 in last 35 min |
| Error rate spike | Log alert: `internal_error` > N/15min | `service:salto-sync-production* status:error message:internal_error` |
| Rate-limit storm | Log alert: retrying_on_rate_limit > 50/hour | `service:salto-sync-production* message:retrying_on_rate_limit` |
| remoteUnlock pin-not-found | Log alert on ErrorCode 3104 | `service:salto-sync-production-remoteUnlock "3104"` |

### Scheduled-job inventory

| Job | Schedule | Logs confirm running? | Dry-run / kill switch? |
|-----|---------|----------------------|----------------------|
| `scanInventory` | EventBridge `rate(30 minutes)` | Yes (`lambda_execution_started` ~2015× in 14d for camelCase service name alone) | No dry-run, no kill switch — mutates `Devices` MongoDB collection on every run |

**Finding:** `scanInventory` has no dry-run mode or feature flag. It writes to MongoDB on every invocation. If the code has a bug (as finding #1 identifies), there is no way to pause mutations without a code deploy. A `DRY_RUN=true` env-var guard on the write path would allow safe testing.

### Dead API surface

The HTTP surface has one endpoint (`/remote-unlock`). No traffic data showing zero-hit routes; all other handlers are direct-invoke (no HTTP). N/A.

## Cost

**Lambda sizing:**
- Default functions: 128 MB, 29s timeout — appropriate for simple pass-through handlers.
- scanInventory: 256 MB, 29s timeout — runs every 30 min; median duration unclear from available data but likely 5–15s for 2015 runs at ~1340 logs each. 256 MB may be oversized; 128 MB likely sufficient given no CPU-intensive work.
- remoteUnlock: 256 MB — OTP generation (MD5, trivial) + 2 Mongo queries + 1 HTTP call. 128 MB likely sufficient.

**Rough monthly cost estimate (Lambda):**

scanInventory at 256 MB, 10s avg duration, ~1440 invocations/month:
- Compute: 1440 × 10s × 256/1024 GB = 3,600 GB-s × $0.0000166667 = ~$0.06/month — negligible.

**Datadog ingestion:**

3.86M log events in 14d → ~8.25M/month. At typical $0.10/GB and ~0.3KB/event average:
- 8.25M × 0.3KB = ~2.5GB/month → ~$0.25/month nominal, but Kasa pricing may differ.
- **Top savings lever**: Eliminating the 2.7M `more_than_one_lock_found_for_unit` warn logs (which carry full `lockData` objects — likely 1–3KB each) could reduce ingestion significantly: 2.7M × 1.5KB avg = 4GB/14d ≈ ~8.5GB/month → **$0.85–$1.70/month saved** depending on tier pricing.

**Recommendations:**
1. Fix the `more_than_one_lock_found_for_unit` root cause — largest cost lever.
2. Downgrade per-device "no change" info logs to debug — eliminates another 324K lines/14d.
3. Right-size scanInventory and remoteUnlock to 128 MB (test first — if OOM, keep 256 MB).

## Skipped / caveats

- **AWS DLQ checks**: No SQS queues in this service; DLQ check not applicable.
- **Git history secret scan**: Bounded to config/env files in last 2 years — no hardcoded secrets found in serverless.yml or committed files (all credentials correctly reference SSM/Secrets Manager).
- **CloudWatch metrics / Lambda utilization**: AWS creds available but `shared-kasa-dlq-status` skill not needed (no queues); Lambda utilization metrics not pulled (Step 5 estimate is based on schedule math only).
- **Datadog message facet aggregation**: The message facet aggregate returned empty for the generic 14d volume query (API quirk); service-level breakdown used instead, which is more actionable.
- **salto-sync-ts6 worktree**: Not audited — it's a TS6 trial branch, not in production. The main audit branch (master) already uses TypeScript 6.0.3 per package.json, so the trial appears to have been merged.
