# Fable audit playbook

Shared instructions for the one-off `fable-audit-*` tasks (June 2026 Fable 5
window). Each task file names a target repo and gives repo-specific context,
then points here. Follow this playbook top to bottom. You are running
overnight with no user available — never block on a question; degrade
gracefully and record what you skipped.

## Parameters (set by the task file)

- **REPO_DIR** — absolute path to the repo checkout
- **REPO_NAME** — repo slug (also the default Datadog service name guess)
- **DD_SERVICE_QUERY** — Datadog `service:` filter hint, if known
- Per-repo context / special focus, if any

## Ground rules

- **Read-only toward the world.** No commits, pushes, PRs, Jira tickets,
  Slack messages, and absolutely no writes to production databases, APIs, or
  AWS resources. The only files you create are the report (below) and this
  run's log file.
- Allowed local side effects (these are expected, not violations):
  `git fetch` in the target repo; a temporary worktree under
  `/tmp/fable-audit-<repo>` (remove it when done); `npm audit` /
  `npm outdated` style registry reads.
- PRE-AUTHORIZED: write/overwrite `reports/fable-audit-<REPO_NAME>.md` in
  this folder. Do **not** commit it — Gabor commits reports himself.
- Do not edit anything under `logs/` except appending this run's own log.
- Depth: this is a deep audit, not a daily check. Use a multi-agent workflow —
  fan the static review dimensions out to parallel subagents and
  adversarially verify bug findings before reporting them. Prefer ~10 strong,
  verified findings over 40 maybes. Keep total subagent count reasonable
  (≤ ~15); 17 of these runs share one weekly token budget.
- **Write the report incrementally.** Create the report file after Step 0
  and append/update each section as its step completes — do not save the
  whole write-up for the end. A run that dies mid-audit must still leave a
  partial report (the synthesis treats a missing report as a failed audit).
- **Timebox.** Runs fire ~5 hours apart (2/night) and contend for the same
  token budget. If you are ~90 minutes in, stop opening new threads: write up
  what you have, list what was cut under "Skipped / caveats", and finish.
- Redaction applies to PII too: any Datadog log line quoted in the report
  or run log must have guest contact info, door codes, and tokens redacted
  — reports are tracked files.

## Step 0 — Preflight

1. `git -C REPO_DIR fetch origin` (tolerate network/auth failure — note it
   and continue with the local state).
2. If a stale worktree from a previous attempt exists (the
   `/tmp/fable-audit-<repo>` path, or a dangling entry in
   `git -C REPO_DIR worktree list`), clean it up first:
   `git worktree remove --force` then `git worktree prune` — otherwise the
   `git worktree add` below fails.
3. If the checkout is on the default branch and clean, audit it in place.
   Otherwise create a temp worktree of `origin/<default-branch>` at
   `/tmp/fable-audit-<repo>` and audit that instead; remove it at the end.
   Never switch branches, pull, stash, or otherwise touch the user's checkout.
4. Note in the report: branch audited, HEAD sha, commit date, and whether the
   local checkout was dirty/behind.

## Step 1 — Orient

Read README, CLAUDE.md, package.json, and the infra definition
(serverless.yml / CDK / Dockerfile / .github workflows). Establish: what the
service does, how it deploys (Lambda vs Fargate), its queues/topics/cron
schedules, its datastores, and which shared Kasa libs it already uses.
Produce a short architecture map (one paragraph + component list) for the
report.

## Step 2 — Static audit (parallel dimensions)

Run these as parallel subagents over the audited tree, then adversarially
verify anything reported as a bug (a finding only ships if a skeptical
re-check against the actual code confirms it):

1. **Architecture & boundaries** — layering violations, god modules,
   copy-pasted logic that duplicates Kasa shared libs (`api-client*`,
   `nest-common`, `queue-patterns`, `lambda-utils`, `logger`, `enums`,
   `ts-utils`…), dead code/handlers/flags, drift from current Kasa service
   patterns. Flag where an existing Kasa tool already covers something the
   repo hand-rolls (resourcefulness principle).
2. **Dormant bug hunt** — the high-value pass. Hunt specifically for:
   race conditions and missing idempotency in queue/event handlers;
   swallowed errors and unhandled promise rejections; retry storms /
   missing backoff; integer-vs-decimal scale bugs; timezone handling;
   Mongoose strict-mode silently stripping fields; pagination that misses
   tail records; off-by-one date-range logic. Every finding needs
   file:line evidence and a trigger scenario.
3. **Runtime & dependency health** — Node/TS versions vs Kasa current,
   `npm audit` highlights (prod deps first), notably stale deps, Jest/ESM
   friction, CI gaps (no tests on PR, no typecheck, etc.).
4. **Security** — hunt for:
   - **Secrets** — credentials/API keys/tokens committed in the tree or in
     config files; also scan git history (`git log -p` over likely files /
     `git grep` across recent revisions) for secrets that were "removed"
     but still live in history. Bound the history scan to the last ~2
     years — old repos have deep histories and this pass must not eat the
     subagent's whole budget. Never reproduce a found secret in the
     report or run log — name the file:line/commit, redact the value, and
     mark it **flag for rotation**.
   - **AuthN/AuthZ gaps** — endpoints missing the IAM/bearer authorizer
     the rest of the service uses, internal routes exposed publicly,
     missing tenant/ownership checks on id-based lookups (IDOR), webhook
     handlers that skip signature verification.
   - **Injection & input handling** — un-validated input reaching Mongo
     queries (operator injection via objects), shell exec, template
     strings into URLs/headers (SSRF), unsafe deserialization.
   - **Infra posture** (from serverless.yml/CDK) — wildcard IAM actions or
     resources, public S3 buckets, permissive CORS, secrets passed as
     plain env vars instead of Parameter Store/Secrets Manager references,
     missing encryption settings on queues/buckets.
   - **PII in logs** — guest contact info, door codes, or tokens being
     logged (they end up in Datadog); this is both a compliance and a
     cost finding.

   Severity-rank security findings on exploitability × blast radius, and
   verify them like bug findings — a security finding that doesn't survive
   a skeptical re-read of the code doesn't ship. This is an authorized
   internal audit of Kasa-owned code; if you find evidence of *active*
   compromise (not just a weakness), say so prominently in the report and
   set `Severity: attention` regardless of other findings — Gabor routes
   incidents to TechOps.
5. **Resilience posture** — for every outbound dependency (vendor APIs,
   other Kasa services, Mongo, queues): is there a timeout, a bounded
   retry with backoff, and a defined behavior when it's down anyway?
   Also: SIGTERM/drain handling on ECS services, SQS redrive policies and
   poison-message handling, and whether partial-batch failures poison the
   whole batch. The *absence* of a defense is a finding even when no bug
   is triggered today — say what incident shape it invites.
6. **Bus-factor map** — no subagent needed, plain git stats
   (`git shortlog -sn`, per-directory blame concentration over the last
   ~2 years): which areas have effectively a single author, and who.
   Report it as a short table; the synthesis rolls these up into
   "areas with no living maintainer".

## Step 3 — Production signals (Datadog — works overnight, API-key auth)

Use the `shared-kasa-datadog-logs` and `shared-kasa-datadog-metrics` skills.
If DD_SERVICE_QUERY wasn't given, discover the service name first; if the
service genuinely has no Datadog presence, say so and move on.

1. **Error archaeology** — window: 90 days or the log index's actual
   retention, whichever is shorter (probe with a quick count query first;
   retention is likely well under 90 days). State the window actually used
   in the report. Aggregate `@level:error` (and warns if errors are sparse)
   by normalized error key (strip UUIDs/timestamps/IDs). Identify the
   *chronic* errors: present for weeks+, high count, never fixed. For the
   top ~5, trace each back to the code, identify root cause, and propose
   both the patch and the structural fix.
2. **Log noise & cost** — top log emitters by volume over 14 days; flag
   spammy loops, per-item logging inside batch loops, duplicate
   logger calls for one event, and debug/info logs that dominate volume.
   Datadog ingestion is real money — call out the top reduction opportunity.
3. **Monitor & alerting coverage** — list the Datadog monitors that
   actually target this service (monitors API is key-auth, works
   overnight). Map them against the failure modes found in this audit:
   error-rate, latency, DLQ depth, cron-didn't-run, deploy regressions.
   Every chronic error from 3.1 gets the question "which monitor should
   have caught this, and does it exist?" — gaps are findings with a
   concrete proposed monitor each.
4. **Forgotten-automation check** — inventory every scheduled job the repo
   defines (cron/EventBridge/scheduled Lambdas/queue fillers). For each:
   what it does, does Datadog show it actually running on schedule, does
   it fail silently (errors but nothing alerts), and does it have a
   dry-run/kill switch if it mutates data. A job that mutates data with
   no dry-run default and no off switch is at least a medium finding
   regardless of its current behavior.
5. **Dead API surface** (conditional) — only if the service has an HTTP
   surface *and* Datadog has route-level traffic data for it (most of the
   audited repos are queue-driven workers — skip with one line in that
   case). Endpoints/handlers defined in code with zero traffic in the
   error-archaeology window get a "remove or document why it stays"
   recommendation — dead endpoints are free maintenance burden and attack
   surface.

## Step 4 — AWS-dependent checks (expect expired creds; degrade gracefully)

Overnight the SSO session is almost certainly expired, and the scheduler
freezes env creds at spawn. Check with
`env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN aws sts get-caller-identity`
(the `env -u` strips frozen env creds so the SSO profile is actually tried).
If creds work: run DLQ status for the repo's queues (`shared-kasa-dlq-status`
approach) and any CloudWatch/SQS checks that add signal. If not: **skip
silently into the report** — add a "Skipped: AWS checks (expired
credentials)" line, keep `Status: success`, and do not retry-loop.

## Step 5 — Cost picture & right-sizing

Pull CPU/mem utilization vs reserved over 30 days (ECS task size/count, or
Lambda memory/duration) and recommend concrete sizing changes. Combine with
the infra definitions and Step 3 log volume to estimate the service's
monthly AWS + Datadog footprint (task sizes × count, Lambda invocations ×
memory, log volume, retention settings). Rough numbers are fine — the goal
is ranking savings opportunities, not an invoice. List the top 1–3 savings
levers with estimated $/month each.

## Step 6 — Finalize the report

You have been building `reports/fable-audit-<REPO_NAME>.md` incrementally
since Step 0 (ground rules). Now finish it: write the TL;DR last, rank the
findings, and make sure it matches this shape:

```
# Fable audit — <repo> (<date>)

## TL;DR
3–6 sentences: overall health, the single most important finding, total
estimated savings.

## Findings (ranked)
| # | Sev | Area | Finding | Evidence | Recommendation |
Sev: high / medium / low. Evidence: file:line or a Datadog query/link.
Recommendation: patch AND root-cause fix where they differ.

## Architecture notes
The Step 1 map + Step 2.1 observations worth keeping, and the bus-factor
table from Step 2.6.

## Production signals
Chronic errors table (with the log window actually used), log-noise
summary, monitor coverage gaps, scheduled-job inventory, dead endpoints
(if applicable).

## Cost
Utilization vs reserved, estimated footprint, savings levers.

## Skipped / caveats
Anything not checked and why (expired creds, no Datadog presence, dirty
checkout, etc.).
```

Findings must be self-contained — written for Gabor reading it cold a week
later, and for the synthesis task that parses all of these.

## Step 7 — Outcome & notification

In the run log's `## Outcome`:

- `Status: success` even when AWS checks were skipped; `failure` only if the
  audit itself couldn't run (repo missing, report unwritable).
- `Severity: attention` if there is ≥ 1 high-severity finding, else `ok`.

Append a `## Notification` block **only** when severity is `attention`:
title `Fable audit: <repo>`, body = the top finding in one line.
