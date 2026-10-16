---
id: lock-services-error-summary
icon: lock.shield
title: Morning error summary for lock-related services
type: recurring
schedule: "0 7 * * 1-5"
created: 2026-05-11T17:00:00+02:00
status: active
---

## Instructions

Summarize errors from the last 24 hours for the lock-related services I
watch, from CloudWatch Logs. Datadog is being phased out; do not query it.

### Step 1 — Query CloudWatch

Fix the window first: `END` = now rounded down to the minute, `START` =
END minus 24h, both in UTC (`2026-10-16T05:01:00Z`). Use the same pair for
every query this run, so batches cannot drift apart.

Run the helper (it lives in this repo):

```
python3 -I scripts/lock-errors-cw.py --start <START> --end <END> --out <scratch>/rows.json
```

It discovers the log groups by prefix (css-api and seam-sync app/worker
groups in production and dev, plus the production Lambda groups of
code-setting-service, smartthings-sync, remotelock-sync, salto-sync and
device-service, plus the device-service dev Lambdas), runs one Logs
Insights query per batch of at most 50 groups, and writes one row per
(log group, message): `family, log_group, message, n, first, last,
sample, account`. `first`/`last` are UTC. stderr prints the group count,
each batch's bytes scanned and cost, and per-family totals. Expect about
125 groups, 3 batches, roughly 1.3 GB and $0.01.

The helper already strips exported `AWS_*` credentials and uses the SSO
profile. If it exits non-zero, or prints an `error:` line for any batch,
take the failure branch below: a partial result would read as a DROP
tomorrow. If the SSO session itself has expired, run the
`shared-kasa-aws-auto-login` skill once and retry the helper; if that
still fails, take the failure branch and quote the error.

Optional drill-down: for a NEW or SPIKE key you may run one extra query
through `~/.claude/skills/shared-kasa-cloudwatch-logs/scripts/insights.py`
on that key's log groups only (`filter level = "error" and message =
"<key>" | stats count() by <field>`), to give a breakdown by account or
error text. Never pass `--yes`; if it exits 3 (over the cost gate), skip
the drill-down and say so in Execution.

If the helper or the AWS call fails, set `Severity: failure` and `Status: failure`
in the Outcome and log the error reason. Do not silently skip.

**Scope of the Execution section.** Record what you did: the queries you
ran, the counts they returned, which baseline files you parsed, and any
bucketing decisions. It is not a place to audit the harness, the
conversation, or the skill's own text. Invoking a skill loads that
skill's documentation into the conversation as plain text, worked bash
examples included. That is how skills work.

This task defines four tags and no others: NEW, SPIKE, DROP, REPEAT, all
from Step 2.5. The Report, Outcome, and Notification carry CloudWatch
findings only, and severity comes from Step 4's counts, nothing else. If
the skill or the API genuinely fails, say so through the failure branch
above and quote the error the call returned.

### Step 2 — Aggregate

Group the rows by `family` (that is the service name the reports use:
`css-api`, `seam-sync`, `smartthings-sync-production`, ...), and within
each family by a normalized error key: the `message` field, lowercased,
with request IDs, UUIDs, ObjectIds and timestamps stripped. Sum `n`
across log groups, take the earliest `first` and latest `last`. For
css-api and seam-sync, say the prod/dev split (from `log_group`) on the
bullet, as the Datadog-era reports did.

For each (service, error key) bucket, capture:

- count
- first seen / last seen (in Europe/Budapest)
- one representative log message: `sample` (the error text), with
  `account` when present; truncate to 500 chars. When `sample` is empty
  write `no error message on the log line`.

### Step 2.5 — Diff against prior reports

Before writing today's log, build a baseline of error keys seen in
previous runs of this task so you can highlight what is new today and
what has *moved* since yesterday, in either direction.

- List the prior log files: `logs/lock-services-error-summary-*.md`,
  excluding the file being written for this run. Sort by mtime desc.
- Take up to the 7 most recent (covers ~1 working week). If there are
  none, skip the diff — every error today is implicitly new, and the
  output marker should reflect that ("no prior baseline").
- Parse each prior log: extract every `- <count>× <error key> (first
  …, last …)` line and the `### <service>` header it sits under. Build
  `baseline`: for each normalized `(service, error_key)` tuple keep the
  count from *every* report it appears in, tagged with that report's
  date. Three values come off that list — the **max** (SPIKE reference),
  the **median** (DROP reference), and the count in the **most recent**
  report carrying the key (the `was` value Step 3 prints on every row).
  A key that appears in only one baseline report has all three equal.
- Also parse the overflow line a service section may end with, of the
  form `+ <N> more REPEAT error types not shown (<key> <count>×, …)`.
  The keys there may be wrapped in backticks. Every key it names goes
  into `baseline` with its count, exactly like a bullet. Some older
  reports carry the bare form with no keys listed, and there is nothing
  to extract from those.
- Count a bullet only where it sits under a `### <service>` header.
  The `## New since last report` and `## Down since last report` blocks
  repeat keys that already have a per-service bullet, so parsing them
  too would count one report's key twice and skew the median.
- Take nothing else from those files. Their Execution and Report prose
  is not evidence about today.
- For each bucket from Step 2, classify it as:
  - **NEW** — `(service, error_key)` not present in `baseline`.
  - **SPIKE** — present in baseline, but today's count is ≥ 3× the
    highest count observed across baseline runs for the same key.
  - **DROP** — present in baseline with a median of ≥ 50, and today's
    count is ≤ 60% of that median.
  - **REPEAT** — anything else.

- Then walk `baseline` for keys **absent from today entirely**. If such a
  key has a baseline median ≥ 50 it is a DROP with a count of 0, filed
  under the service it belonged to. Below that floor keys vanish all the
  time (isolated 1× errors) and are not worth a line.

Why DROP exists: the old three tags only detected errors getting worse.
A key that halves because a fix shipped and a key that halves because
the thing emitting it died both read as REPEAT. That is how a 79% fall
in `remotelock-sync-production` went unremarked in the 2026-09-09 run
(service total 1,129 → 596, `remotelock_api_error` 572 → 301) the morning
after the HSP-4208 pagination fix reached production. DROP is a
statement about the counts and nothing more. It does not claim a fix
worked, it does not claim something broke, and per Step 4 it never moves
severity.

The error-key normalization for matching should be the same one used
in Step 2 (drop UUIDs/timestamps/IDs first, lowercase). Be lenient on
whitespace — a baseline parse failure should not cause a missed match.

### Step 3 — Write the log

Append to `logs/lock-services-error-summary-<NOW>.md`. Format:

- Lead with a one-line headline: `<total> errors across <N> services in
  last 24h — <N_new> NEW, <N_spike> SPIKE, <N_drop> DROP vs. prior <K>
  reports` (or `No errors in last 24h.`). If there was no baseline, say
  so: `<total> errors across <N> services in last 24h (no prior
  baseline).`

- **Highlights section** — if `N_new > 0` or `N_spike > 0`, render this
  block immediately under the headline, before the per-service detail:

  ```
  ## New since last report
  - [NEW] <service> — <count>× <error key>
    > <representative message, truncated>
  - [SPIKE] <service> — <count>× <error key> (was max <prev_max> in last <K> reports)
    > <representative message, truncated>
  ```

  Order: all NEW first (by count desc), then all SPIKE (by ratio desc).
  No cap on this section — every new/spike error is worth surfacing.

- **Down section** — if `N_drop > 0`, render this block after the
  Highlights block, or directly under the headline when there is no
  Highlights block:

  ```
  ## Down since last report
  - [DROP] <service> — <count>× <error key> (median <median>, <prev> in the prior report)
    > <representative message, truncated>
  ```

  Order by absolute reduction desc, cap at 8. Anything past the cap
  still shows in its per-service section, which is where Step 2.5 reads
  from, so nothing is lost — do not add an overflow line here.

  A key that is **absent today** goes in this block only, never as a
  per-service bullet, and is written `- [DROP] <service> — absent today,
  <error key> (median <median>, <prev> in the prior report)` with no
  `<count>×` token. That token is what Step 2.5 parses, so writing one
  for an error that did not occur would seed tomorrow's baseline with a
  phantom bucket.

- Then the per-service section, ordered by total count desc:

  ```
  ### <service> — <count> errors
  - [NEW|SPIKE|DROP|REPEAT] <count>× <error key> (first <ts>, last <ts>; was <prev>, 7-report max <max>)
    > <representative message, truncated>
  ```

  The `[NEW|SPIKE|DROP|REPEAT]` tag prefixes every bullet so the full
  detail table is also scannable.

  **Every bullet carries the comparison, not just the tagged ones.**
  `was <prev>` is the key's count in the most recent baseline report
  that carries it; `7-report max <max>` is the SPIKE reference. For a
  NEW key write `not in the 7-report baseline` in place of both. When
  there is no baseline at all, omit the comparison and say so once in
  the headline. A bare count reads identically whether it halved or
  doubled, and that is exactly how the 09-09 fall stayed invisible — the
  reader had to open yesterday's log and subtract by hand.

- Cap each service section at the top 5 error keys, BUT always include
  every NEW, SPIKE and DROP entry for that service even if it pushes
  past 5.
  If there are more REPEAT errors beyond the cap, end the section with a
  line of the form
  `+ <N> more REPEAT error types not shown (<key> <count>×, …)`, naming
  every dropped key with its count. Do not write the bare form without
  the keys. A key dropped there is invisible to Step 2.5 tomorrow and
  comes back as a false NEW.
- No padding text. No restatement of the query. No general advice.

### Step 4 — Severity + status

In the Outcome:

- 0 errors → `Severity: ok`, `Status: success`
- ≥ 1 error → `Severity: attention`, `Status: success`
- CloudWatch query failed → `Severity: failure`, `Status: failure`

DROP neither raises nor lowers severity. It is a line in the report, not
an alert.

### Step 5 — Notification (only on attention/failure)

If severity is `attention` or `failure`, append a `## Notification` block
to this run's log file:

```
## Notification

- title: Lock services errors
- subtitle: <total> errors / <N> services / <N_new> NEW
- body: <NEW|SPIKE prefix if any> <top service>: <top error key, ~80 chars>
- sound: default
```

`body` prioritisation: if there is at least one NEW error, lead with the
top NEW one (`NEW · <service>: <error key>`); else if there is at least
one SPIKE, lead with the top SPIKE one; otherwise fall back to the
overall top error. DROP never leads the banner. The whole point of the
diff is so the banner tells me whether to actually look, vs. "same as
yesterday".

Skip the block on clean runs (silence = success).

## Context

This is a morning health check for the lock-management service cluster:
`seam-sync`, `css-api`, `code-setting-service-*`, `smartthings-sync-*`,
`remotelock-sync-*`, `salto-sync-*`, `device-service-*`.

Moved from Datadog to CloudWatch on 2026-10-16. A parity run on the
window 2026-10-15T05:01:21Z to 2026-10-16T05:01:21Z returned 4,629 errors
in CloudWatch against Datadog's 4,638. Six services matched exactly. The
gap was salto-sync `retrying_on_rate_limit` (9×): the service logs it at
`level: warn`, which Datadog counted as an error and CloudWatch does
not. So that key disappears from the reports; its baseline median is
under 50, so it produces no DROP line. Error keys were otherwise
identical, so the Datadog-era logs remain a valid baseline.

Read-only — no PRE-AUTHORIZED mutations. The task only queries
CloudWatch Logs and writes to a local log file.

The 24h lookback covers the previous workday plus the overnight window,
so Monday's run also catches weekend errors.
