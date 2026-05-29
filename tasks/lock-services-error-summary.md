---
id: lock-services-error-summary
icon: lock.shield
title: Morning Datadog error summary for lock-related services
type: recurring
schedule: "0 7 * * 1-5"
next_run: 2026-06-01T07:00:00+02:00
last_run: 2026-05-29T07:46:48+02:00
created: 2026-05-11T17:00:00+02:00
status: active
---

## Instructions

Summarize Datadog errors from the last 24 hours for the lock-related
services I watch. Use the `shared-kasa-datadog-logs` skill.

### Step 1 — Query Datadog

Run a logs search with:

- Query string (verbatim):
  ```
  @level:error service:(seam-sync OR css-api OR code-setting-service-production-* OR code-setting-service-production* OR smartthings-sync-production* OR remotelock-sync-production* OR salto-sync-production* OR device-service-*)
  ```
- Time range: `now-24h` → `now`
- Source view (for reference): saved view ID `4015487` in Datadog
  (https://app.datadoghq.com/logs?saved-view-id=4015487)

If the skill / API call fails, set `Severity: failure` and `Status: failure`
in the Outcome and log the error reason. Do not silently skip.

### Step 2 — Aggregate

Group the matching logs by `service`, and within each service group by a
normalized error key (error class + first line of message, ~120 chars).
Drop request IDs, UUIDs, timestamps, and other high-cardinality bits when
building the key so similar errors collapse.

For each (service, error key) bucket, capture:

- count
- first seen / last seen (in Europe/Budapest)
- one representative log message (truncate to 500 chars)
- a Datadog link scoped to that service + the 24h window if easy to
  construct; otherwise just include the service name

### Step 2.5 — Diff against prior reports

Before writing today's log, build a baseline of error keys seen in
previous runs of this task so you can highlight what's *new* today.

- List the prior log files: `logs/lock-services-error-summary-*.md`,
  excluding the file being written for this run. Sort by mtime desc.
- Take up to the 7 most recent (covers ~1 working week). If there are
  none, skip the diff — every error today is implicitly new, and the
  output marker should reflect that ("no prior baseline").
- Parse each prior log: extract every `- <count>× <error key> (first
  …, last …)` line and the `### <service>` header it sits under. Build
  a set of normalized `(service, error_key)` tuples — `baseline`.
- For each bucket from Step 2, classify it as:
  - **NEW** — `(service, error_key)` not present in `baseline`.
  - **SPIKE** — present in baseline, but today's count is ≥ 3× the
    highest count observed across baseline runs for the same key.
  - **REPEAT** — anything else.

The error-key normalization for matching should be the same one used
in Step 2 (drop UUIDs/timestamps/IDs first, lowercase). Be lenient on
whitespace — a baseline parse failure should not cause a missed match.

### Step 3 — Write the log

Append to `logs/lock-services-error-summary-<NOW>.md`. Format:

- Lead with a one-line headline: `<total> errors across <N> services in
  last 24h — <N_new> NEW, <N_spike> SPIKE vs. prior <K> reports` (or
  `No errors in last 24h.`). If there was no baseline, say so:
  `<total> errors across <N> services in last 24h (no prior baseline).`

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

- Then the per-service section, ordered by total count desc:

  ```
  ### <service> — <count> errors
  - [NEW|SPIKE|REPEAT] <count>× <error key> (first <ts>, last <ts>)
    > <representative message, truncated>
  ```

  The `[NEW|SPIKE|REPEAT]` tag prefixes every bullet so the full detail
  table is also scannable.

- Cap each service section at the top 5 error keys, BUT always include
  every NEW and SPIKE entry for that service even if it pushes past 5.
  If there are more REPEAT errors beyond the cap, add a final line:
  `+ <N> more REPEAT error types not shown`.
- No padding text. No restatement of the query. No general advice.

### Step 4 — Severity + status

In the Outcome:

- 0 errors → `Severity: ok`, `Status: success`
- ≥ 1 error → `Severity: attention`, `Status: success`
- Datadog query failed → `Severity: failure`, `Status: failure`

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
overall top error. The whole point of the diff is so the banner tells
me whether to actually look, vs. "same as yesterday".

Skip the block on clean runs (silence = success).

## Context

This is a morning health check for the lock-management service cluster:
`seam-sync`, `css-api`, `code-setting-service-*`, `smartthings-sync-*`,
`remotelock-sync-*`, `salto-sync-*`, `device-service-*`. The query matches
the Datadog saved view I use manually (ID `4015487`).

Read-only — no PRE-AUTHORIZED mutations. The task only queries Datadog
and writes to a local log file.

The 24h lookback covers the previous workday plus the overnight window,
so Monday's run also catches weekend errors.
