---
id: <slug-with-no-spaces>
icon: <optional SF Symbol name, e.g. calendar, lock.shield, chart.bar>
title: <human-readable title>
type: <oneoff | recurring>
schedule: <see options below>
next_run: <ISO 8601 datetime in LOCAL time, e.g. 2026-05-12T09:00:00+02:00>
last_run: null
created: <ISO 8601 datetime when this task was authored, local time>
status: active   # active | paused | done | failed
---

## Instructions

What Claude should do when this task fires. Be specific: which command, which
file, which API, what to look for, what to log. Remember Claude has no chance
to ask you clarifying questions during a cron run.

If the task involves mutating shared state (PRs, Slack, prod data), say so
explicitly with a "PRE-AUTHORIZED:" prefix, e.g.:

> PRE-AUTHORIZED: post the summary to Slack #hsp-leads as me.

## Context

Background info, links, prior conversations, expected output format, etc.
Anything that helps Claude do this well without having to figure it out fresh
each invocation.

---

## Optional: desktop notification

If you want the user alerted in real time when this task fires, append
a `## Notification` block to the run's log file (not to this task file).
The desktop app reads it and fires a native banner — tasks never invoke
shell commands for notifications. Schema:

```
## Notification

- title: <required, short>
- subtitle: <optional>
- body: <required, one line>
- sound: default        # optional, or e.g. Glass / Ping
```

The block is independent of `Severity:` and fires once per unique log
content. See `CRON_PROMPT.md` → "Step 3.5 — Optional desktop notification".

---

## Schedule field — what to put

**One-off**

```
type: oneoff
schedule: 2026-05-15T09:00:00+02:00
next_run: 2026-05-15T09:00:00+02:00
```

**Recurring — cron expression** (local time, standard 5-field cron)

```
type: recurring
schedule: "0 9 * * 1-5"    # 09:00 local time, Mon–Fri
next_run: <first fire time, ISO 8601 with local offset>
```

**Recurring — interval**

```
type: recurring
schedule: every 24h        # also: every 30m, every 2d, every 1w
next_run: <first fire time, ISO 8601 with local offset>
```
