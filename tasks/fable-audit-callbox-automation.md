---
id: fable-audit-callbox-automation
icon: magnifyingglass
title: "Fable audit: callbox-automation"
type: oneoff
schedule: 2026-06-15T03:00:00+02:00
next_run: 2026-06-15T03:00:00+02:00
created: 2026-06-11T17:30:00+02:00
status: active
---

## Instructions

Run the audit defined in `AUDIT_PLAYBOOK.md` (this folder, read it first)
with:

- REPO_DIR: `/Users/balazsgabor/Documents/workspace/kasa/callbox-automation`
- REPO_NAME: `callbox-automation`
- DD_SERVICE_QUERY: unknown — discover it (try `service:callbox*`)

PRE-AUTHORIZED: write/overwrite `reports/fable-audit-callbox-automation.md`.
Everything else is read-only toward the world per the playbook ground rules.

## Context

Building callbox/intercom automation for guest entry. Establish the actual
scope from the repo (Step 1) — likely telephony-provider integration, which
makes external-call error handling and retry behavior a priority in the bug
hunt.
