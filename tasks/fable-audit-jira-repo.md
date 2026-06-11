---
id: fable-audit-jira-repo
icon: magnifyingglass
title: "Fable audit: jira (personal tooling repo)"
type: oneoff
schedule: 2026-06-15T00:00:00+02:00
next_run: 2026-06-15T00:00:00+02:00
created: 2026-06-11T17:30:00+02:00
status: active
---

## Instructions

Run the static parts of `AUDIT_PLAYBOOK.md` (this folder, read it first) —
Steps 0–2 and 6–7 — with:

- REPO_DIR: `/Users/balazsgabor/Documents/workspace/kasa/jira`
- REPO_NAME: `jira`

Steps 3–5 don't apply (personal tooling, no Datadog/AWS footprint); skip
them with a note.

PRE-AUTHORIZED: write/overwrite `reports/fable-audit-jira.md`. Everything
else is read-only toward the world per the playbook ground rules.

## Context

Gabor's personal Jira tooling repo (`gabor-kasa/jira`, not a kasadev
service). Audit it as a tool: correctness of the Jira interactions, error
handling on API failures, hardcoded values that will rot (transition IDs,
board/sprint IDs, usernames), and any credentials committed or logged —
flag those for rotation, never reproduce them in the report. Also note
where existing shared skills (`shared-kasa-jira`, `shared-kasa-review-sprint`)
overlap with what this repo hand-rolls.
