---
id: fable-audit-seam-sync
icon: magnifyingglass
title: "Fable audit: seam-sync"
type: oneoff
model: claude-opus-4-8
effort: high
schedule: 2026-06-14T03:00:00+02:00
next_run: 2026-06-14T03:00:00+02:00
created: 2026-06-11T17:30:00+02:00
status: done
---

## Instructions

Run the audit defined in `AUDIT_PLAYBOOK.md` (this folder, read it first)
with:

- REPO_DIR: `/Users/balazsgabor/Documents/workspace/kasa/seam-sync`
- REPO_NAME: `seam-sync`
- DD_SERVICE_QUERY: `service:seam-sync`

PRE-AUTHORIZED: write/overwrite `reports/fable-audit-seam-sync.md`.
Everything else is read-only toward the world per the playbook ground rules.

## Context

Seam lock-platform sync. One of four vendor sync services (with
remotelock-sync, salto-sync, smartthings-sync) — note shared structural
issues for the synthesis task.
