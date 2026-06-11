---
id: fable-audit-remotelock-sync
icon: magnifyingglass
title: "Fable audit: remotelock-sync"
type: oneoff
schedule: 2026-06-12T22:00:00+02:00
next_run: 2026-06-12T22:00:00+02:00
created: 2026-06-11T17:30:00+02:00
status: active
---

## Instructions

Run the audit defined in `AUDIT_PLAYBOOK.md` (this folder, read it first)
with:

- REPO_DIR: `/Users/balazsgabor/Documents/workspace/kasa/remotelock-sync`
- REPO_NAME: `remotelock-sync`
- DD_SERVICE_QUERY: `service:remotelock-sync-production*`

PRE-AUTHORIZED: write/overwrite `reports/fable-audit-remotelock-sync.md`.
Everything else is read-only toward the world per the playbook ground rules.

## Context

RemoteLock vendor integration — syncs devices, access persons, and accesses
(Serverless Lambdas). One of four vendor sync services (with salto-sync,
smartthings-sync, seam-sync); when you find a structural issue here, note
whether the siblings likely share it — the synthesis task clusters these.
