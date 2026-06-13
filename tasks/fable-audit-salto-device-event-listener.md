---
id: fable-audit-salto-device-event-listener
icon: magnifyingglass
title: "Fable audit: salto-device-event-listener"
type: oneoff
model: claude-opus-4-8
effort: high
schedule: 2026-06-14T22:00:00+02:00
next_run: 2026-06-14T22:00:00+02:00
created: 2026-06-11T17:30:00+02:00
status: active
---

## Instructions

Run the audit defined in `AUDIT_PLAYBOOK.md` (this folder, read it first)
with:

- REPO_DIR: `/Users/balazsgabor/Documents/workspace/kasa/salto-device-event-listener`
- REPO_NAME: `salto-device-event-listener`
- DD_SERVICE_QUERY: unknown — discover it (try
  `service:salto-device-event-listener*`)

PRE-AUTHORIZED: write/overwrite
`reports/fable-audit-salto-device-event-listener.md`. Everything else is
read-only toward the world per the playbook ground rules.

## Context

Ingests device events from Salto. Adjacent to salto-sync (audited the night
before — its report may already exist in `reports/`; skim it for shared
patterns worth cross-checking here).
