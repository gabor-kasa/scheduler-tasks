---
id: hospitality-bug-triage
icon: ladybug
title: Weekday bug triage — new reports in #hospitality-bugs
type: recurring
model: claude-opus-5-5
effort: high
schedule: "30 6 * * 1-5"
next_run: 2026-10-15T06:30:00+02:00
created: 2026-10-14T08:46:20+02:00
status: active
---

## Instructions

Run the `/triage` skill (Skill tool, skill `triage`, no arguments) and follow it to the end. It lives
in the pipeline repo, `gabor-kasa/gabors-workspace`, under `triage/`. `~/.claude/skills/triage` links
to it. The skill holds the whole procedure, the forbidden list and the verdict rules. This file only
schedules it, grants its two writes, and says how to report.

If `~/.claude/skills/triage/SKILL.md` does not exist, stop: `Status: failure`, summary "triage skill
not installed (run install.sh in gabors-workspace)".

> PRE-AUTHORIZED: add an HSP ticket to the active Hospitality sprint (board 48), only when the
> skill's Step 5 sprint gate passes.

> PRE-AUTHORIZED: run `~/.claude/skills/triage/triage.sh start` and `finish`, which push a
> `triage/<stamp>` branch to `gabor-kasa/gabors-workspace`, open a PR with the `triage/<KEY>.md`
> files, and squash-merge it once gitleaks is green.

Nothing else may be written: no Slack messages, no other Jira change, no production write, no
change to any other repo. The skill says the same.

### Report

Append the skill's Step 7 summary to the run log as `## Report`, unchanged.

`## Outcome`:
- **Status:** `success` if the skill completed, even with some tickets `unverified`. `failure` if
  Slack or Jira reads failed and no ticket list could be built, if `triage.sh finish` failed, or if
  anything outside the two pre-authorized writes happened.
- **Severity:**
  - `ok`: nothing waiting for triage.
  - `attention`: anything added to the sprint, anything under "Needs your decision", an
    `add-failed`, or a broken sprint state on board 48.
  - `failure`: as above.
- **Summary:** counts. For example "3 new bugs: 1 added to sprint, 1 RC-owned, 1
  works-as-expected."

On `attention`, append:

```
## Notification

- title: Bug triage — <A> added, <N> need you
- body: <the single most important item, ~90 chars>
- sound: default
```

## Context

- Requested by Gabor on 2026-10-14 and refined in a grilling session the same day. The procedure
  moved into the pipeline repo as `/triage` the same day, so its verdicts (`triage/<KEY>.md`) live
  next to the `/ticket` runs whose closeout grades them. Change the procedure there, through a PR,
  not here.
- Gabor's corrections go into `triage/rulings.md` in that repo.
- Testing phase. The sprint add and the triage PR are the only writes. Output is the run log. Once
  the closeout grades show a good hit rate, likely next steps are commenting the corrected RCA on
  the ticket, reassigning RC-owned tickets, and replying in the Slack thread. Each needs its own
  `PRE-AUTHORIZED:` line here first.
- The scheduler runs this as `claude -p` with no one to answer questions. Skills that say "ask the
  user" do not apply. Take the read-only path and record the open question in the report.
