---
id: weekly-insights-review
icon: chart.bar
title: Weekly Claude Code usage review + personalised tips
type: recurring
schedule: "0 9 * * 1"
created: 2026-05-13T12:00:00+02:00
status: active
---

## Instructions

You are producing a weekly retrospective on Gabor's Claude Code usage and
turning it into one concrete behaviour change for the coming week.

### Step 1 — Gather usage data from local transcripts

(`/insights` is interactive-only — it doesn't work under `claude -p`,
so we read local state directly.)

Scan `~/.claude/projects/` for session transcript JSONL files modified
in the last 7 days. Each file is one session; the project directory
name maps to a repo path (slashes encoded as dashes). For each session
aggregate:

- model field per turn (Opus / Sonnet / Haiku, and exact version)
- tool names used and their counts
- `is_error:true` tool results
- raw transcript size (proxy for session length / compaction risk)
- `Skill` invocations and which skill IDs

Roll the per-session numbers up to per-project totals and weekly
totals. `~/.claude/stats-cache.json` and `~/.claude/usage-data/` are
usually stale — only use them if their mtime is within the window.

If `~/.claude/projects/` has no files modified in the last 7 days,
set `Severity: failure` and stop — don't fabricate numbers.

### Step 2 — Summarise the week

Write a short summary (≤ 8 bullets) covering:

- Total Claude Code usage volume (session count and aggregate turn
  count from Step 1). Call out if it looks like a spike or a dip
  compared to prior weekly log files for this task, if any exist.
- Top 3 projects / repos by activity (the project paths under
  `~/.claude/projects/` map to repo paths).
- Model mix (Opus vs Sonnet vs Haiku) — note if Gabor used the wrong
  tier for the task (e.g. Opus on trivial edits, or Sonnet on a hard
  debugging session that took many turns).
- Tool-use patterns worth flagging: e.g. heavy Bash usage where Read
  would do, repeated Grep retries, lots of failed Edits, etc.
- Anything notable about session length, interrupt frequency, or
  re-prompts (signals of unclear initial instructions).

Keep it terse — this is a personal dashboard, not a report.

### Step 3 — The single best improvement

Pick **one** behaviour change that would have the highest leverage based
on what you saw in Step 2. Not a list — one. State it as a concrete
action, e.g.:

> "Switch to Sonnet 4.6 for the kontrol-ui frontend tweaks — last week
> you burned ~40% of your Opus tokens on tasks that Sonnet would have
> finished in fewer turns."

Avoid generic advice ("write better prompts"). It must be tied to
something you actually observed in this week's data.

### Step 4 — 3–5 personalised tips for the week ahead

Tips should be:

- Specific to patterns in *this* week's data — name the repo, the tool,
  the task type.
- Actionable in a single session (not "refactor your whole workflow").
- Ranked by expected impact (most valuable first).

If you can't find 3 grounded tips, give fewer — don't pad.

### Step 5 — Write the log

The scheduler creates `logs/weekly-insights-review-<NOW>.md` for this
run. Structure:

```
## Summary
<bullets from Step 2>

## Best improvement this week
<the single recommendation from Step 3>

## Tips for the week ahead
1. <tip>
2. <tip>
...

## Outcome
Status: success
Severity: <ok | attention | failure>
```

Severity rules:
- `ok` — usage was light or perfectly tuned; no meaningful change to
  suggest.
- `attention` — you identified a real improvement worth surfacing (the
  default for an active week).
- `failure` — `~/.claude/projects/` had no fresh transcripts, so there
  was no data to analyse.

### Step 6 — Notification

If `Severity: attention`, append a `## Notification` block to this
run's log file:

```
## Notification

- title: Weekly Claude Code insights
- subtitle: 1 improvement + <N> tips
- body: <one-line teaser of the best improvement, ~90 chars>
- sound: default
```

Skip the notification on `ok` runs — silence is the success state.

## Context

This is read-only: the task only reads local Claude Code state files
and writes to the run log. No PRE-AUTHORIZED actions required.

The goal is a *personal* coaching loop, not a generic Claude Code
tutorial. Tips that don't reference Gabor's actual recent work are
noise — prefer "fewer but grounded" over "more but generic".

Why Monday 09:00: it's early enough in the week that any behaviour
change can compound across the next 5 days, and it follows the existing
[[hospitality-calendar-audit]] task which fires at 08:00 — same morning
rhythm.
