---
id: fable-audit-salto-sync
icon: magnifyingglass
title: "Fable audit: salto-sync"
type: oneoff
schedule: 2026-06-13T03:00:00+02:00
next_run: 2026-06-13T03:00:00+02:00
created: 2026-06-11T17:30:00+02:00
status: done
---

## Instructions

Run the audit defined in `AUDIT_PLAYBOOK.md` (this folder, read it first)
with:

- REPO_DIR: `/Users/balazsgabor/Documents/workspace/kasa/salto-sync`
- REPO_NAME: `salto-sync`
- DD_SERVICE_QUERY: `service:salto-sync-production*`

PRE-AUTHORIZED: write/overwrite `reports/fable-audit-salto-sync.md`.
Everything else is read-only toward the world per the playbook ground rules.

## Context

Salto lock vendor sync (Serverless Lambdas). One of four vendor sync
services (with remotelock-sync, smartthings-sync, seam-sync) — note shared
structural issues for the synthesis task.

The local checkout may be mid-TS-upgrade (a separate `salto-sync-ts6`
checkout exists) — the playbook's preflight handles auditing
`origin/<default-branch>` regardless of local state.
