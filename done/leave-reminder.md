---
id: leave-reminder
title: Reminder to leave
type: oneoff
schedule: 2026-05-12T15:41:00+02:00
next_run: 2026-05-12T15:41:00+02:00
last_run: 2026-05-12T15:41:09+02:00
created: 2026-05-12T15:33:00+02:00
status: done
---

## Instructions

Fire a desktop notification reminding Gabor to leave. Append the following
block to this run's log file (so the desktop app picks it up):

```
## Notification

- title: Time to leave
- body: Heads up — it's 15:45. Time to head out.
- sound: default
```

No other work. Set Severity to `ok`.

## Context

One-off reminder. After firing, this task should be archived to `done/`
automatically per the standard one-off lifecycle.
