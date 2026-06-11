---
id: fable-audit-smartthings-sync
icon: magnifyingglass
title: "Fable audit: smartthings-sync"
type: oneoff
schedule: 2026-06-13T22:00:00+02:00
next_run: 2026-06-13T22:00:00+02:00
created: 2026-06-11T17:30:00+02:00
status: active
---

## Instructions

Run the audit defined in `AUDIT_PLAYBOOK.md` (this folder, read it first)
with:

- REPO_DIR: `/Users/balazsgabor/Documents/workspace/kasa/smartthings-sync`
- REPO_NAME: `smartthings-sync`
- DD_SERVICE_QUERY: `service:smartthings-sync-production*`

PRE-AUTHORIZED: write/overwrite `reports/fable-audit-smartthings-sync.md`.
Everything else is read-only toward the world per the playbook ground rules.

## Context

SmartThings hub/lock vendor sync (Serverless Lambdas) — hubs, locks, codes,
device health. One of four vendor sync services (with remotelock-sync,
salto-sync, seam-sync) — note shared structural issues for the synthesis
task. A separate `smartthings-sync-ts6` checkout exists locally; audit
`origin/<default-branch>` per the playbook preflight.
