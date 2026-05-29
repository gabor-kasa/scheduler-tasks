# Example task (not active — sits at scheduler root, not in tasks/)

Copy this into `tasks/dlq-morning-check.md` (or similar) to activate.

```yaml
---
id: dlq-morning-check
title: Check DLQ status every weekday morning
type: recurring
schedule: "0 9 * * 1-5"         # 09:00 local time, Mon–Fri
next_run: 2026-05-12T09:00:00+02:00
last_run: null
created: 2026-05-11T16:36:00+02:00
status: active
---
```

## Instructions

Use the `shared-kasa-dlq-status` skill to check all DLQs in the kasa project.

If every DLQ has 0 messages: log "all clear" and finish.

If any DLQ has >0 messages: log the queue name, message count, and the first
two messages (truncated to 500 chars each) for context. Don't drain or
modify anything — read-only.

## Context

This is a routine production health check. I want a passive record in
`logs/` so I can scroll back and see whether the morning DLQs have been
trending up or down. No notifications needed.

---

# Another example — one-off

```yaml
---
id: review-hsp-1234-pr
title: Skim HSP-1234 PR before standup
type: oneoff
schedule: 2026-05-12T08:30:00+02:00
next_run: 2026-05-12T08:30:00+02:00
last_run: null
created: 2026-05-11T16:36:00+02:00
status: active
---
```

## Instructions

Fetch PR `https://github.com/kasadev/hsp/pull/1234` via `gh pr view 1234
--repo kasadev/hsp --json title,body,files,additions,deletions`. Write a
3-bullet summary to the log: what changed, anything that looks risky, and
which files I should look at first.

Do NOT leave a PR review comment. This is just for my own prep.

## Context

I'll look at the log right before standup. Today is sprint demo day so I
want to come in informed.
