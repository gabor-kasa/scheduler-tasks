---
id: <slug-with-no-spaces>
icon: <optional SF Symbol name, e.g. calendar, lock.shield, chart.bar>
title: <human-readable title>
type: <oneoff | recurring>
model: <optional — e.g. claude-opus-4-8; omit for the app default (claude-sonnet-4-6)>
effort: <optional — low | medium | high | xhigh | max; omit for the model default>
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

## Optional: model & effort

By default a task runs on the app's default model (`claude-sonnet-4-6`) at
the model's default effort. Pin a stronger model and/or a thinking (effort)
level per task in the frontmatter:

```
model: claude-opus-4-8      # any valid `claude --model` value
effort: high                # low | medium | high | xhigh | max
```

Put heavy review/audit work on a more capable model (`claude-opus-4-8`,
effort `high`) while leaving simple digests on the cheaper default — or pin
those to `claude-haiku-4-5` to save cost. Omit either key to fall back to the
default. The resolved model is recorded in each run's log header
(`- **Model:**`), so a run is never ambiguous about which model produced it.

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
