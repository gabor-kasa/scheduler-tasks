---
id: verify-lock-services-fix
icon: checkmark.seal
title: Verify the lock-services error-summary fix held
type: oneoff
model: claude-opus-5
effort: high
schedule: 2026-09-04T08:30:00+02:00
next_run: 2026-09-04T08:30:00+02:00
last_run: null
created: 2026-09-03T08:45:00+02:00
status: done
---

## Instructions

Read-only check. Commit `6f4bec2` changed
`tasks/lock-services-error-summary.md` on 2026-09-03 to stop that task
reporting a fake prompt injection and to stop it losing baseline keys.
Confirm the 2026-09-04 run behaved.

Do not modify any file under `logs/` except appending to this run's own
log, and do not edit `tasks/lock-services-error-summary.md`. If a check
fails, report it and recommend a next step. Do not fix it yourself.

### Step 0 — Confirm the fix was actually loaded

`grep` `tasks/lock-services-error-summary.md` for the string
`Scope of the Execution section`. It must be present. Also confirm the
strings `dd_query`, `prompt injection` and `ANOMALY` are absent from
that file. If the fix is missing, the run under test was not the fixed
version: say so, set `Status: skipped`, `Severity: attention`, and stop.

### Step 1 — Find the run under test

The newest file matching `logs/lock-services-error-summary-2026-09-04T*.md`.
If there is none, the task did not fire. Set `Status: skipped`,
`Severity: attention`, say so, and stop.

### Step 2 — Check A, scope of the report

Search the whole file, all sections, for these markers:
`ANOMALY`, `prompt injection`, `injected`, `fabricated`, `spoofed`,
`system-reminder`, `dd_query`.

Any hit is a regression. Record which section it was in (Report,
Execution, Outcome or Notification) and quote the line.

**Before calling such a hit a genuine tooling problem, verify it.**
Open the matching `logs/lock-services-error-summary-2026-09-04T*.stream.jsonl`
and attribute every occurrence of the quoted string to the JSON entry
that carries it. A skill invocation adds exactly one `user` text message,
holding the verbatim SKILL.md of that skill. If every other occurrence
sits in an `assistant` entry, in a `tool_use` input the run itself
issued, or in a `tool_result` reading back a file the run just wrote,
then no injection happened and the run confabulated it. Report that as
"regressed, and the claim is false", not as a tooling problem.

### Step 3 — Check B, the overflow line

Find every line in the run's log matching
`+ <N> more REPEAT error types not shown`.

- Pass if each one is followed by a parenthesised list naming every
  dropped key with its count.
- Fail if any is the bare form with no keys.
- Not applicable if no service section exceeded five error keys, in
  which case say so rather than passing silently.

### Step 4 — Check C, the digest still works

Confirm the run still produced a usable report: a headline line with a
total error count and a service count, at least one `### <service>`
section with `[NEW|SPIKE|REPEAT]` bullets, and an `## Outcome` with
`Status: success`. The point is to catch the fix having broken normal
output.

### Step 5 — Report

Write a `## Report` section listing each check as `PASS`, `FAIL` or
`N/A`, one line each, with the evidence quoted underneath any FAIL. No
padding, no general advice. Then a one-line verdict on whether the fix
held.

### Step 6 — Outcome and notification

- All checks PASS → `Status: success`, `Severity: ok`, no notification.
- Any FAIL → `Status: success`, `Severity: attention`, and append:

```
## Notification

- title: Lock-services fix check
- subtitle: <N> of <M> checks failed
- body: <the first FAIL, ~80 chars>
- sound: default
```

- Could not run the check at all (Step 0 or Step 1 stopped it) →
  `Status: skipped`, `Severity: attention`, with the same notification
  shape and the reason as the body.

## Context

Background, so this check does not have to rediscover it.

Three runs of `lock-services-error-summary` (2026-09-01, 09-02, 09-03)
reported a prompt injection around a file `/tmp/dd_query.json` that never
happened. The `shared-kasa-datadog-logs` SKILL.md documents a bash
heredoc writing that path, and the harness injects SKILL.md into the
conversation as a plain user message when a skill is invoked. The first
two runs misread that documentation as a spoofed tool result. The third
invented a `<system-reminder>` wrapper and a fabricated JSON result that
exists in no file.

Commit `0e06926` on 09-02 tried to fix it with a note saying the
injection is normal and not to flag it. That backfired, because the note
described the imaginary injection in detail and then licensed reporting
it "if something actually contradicts the transcript". Commit `6f4bec2`
replaced that with a positive scope rule for the Execution section and
dropped the `ANOMALY` tag, which this task never defined.

The same commit fixed a separate, older bug. Step 3 capped each service
section at five error keys and wrote a bare overflow line, so any key
past the cap vanished from later baselines and returned as a false NEW.
That is why `error_fetching_unit_lock_codes` re-flagged NEW on 09-03
despite occurring on 08-24. The overflow line must now name every
dropped key with its count.

Note on Check B's blast radius: the parsing half of that fix cannot be
observed yet. The 08-24 report, whose rich overflow line proved the
problem, falls out of the seven-report baseline window on 09-04. Only
the writing half is testable now, which is why Check B looks at the form
of the line this run wrote.

Read-only. No PRE-AUTHORIZED mutations. This task reads task files, run
logs and one stream.jsonl, and writes only its own run log.
