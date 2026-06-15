---
id: fable-audit-device-service
icon: magnifyingglass
title: "Fable audit: device-service"
type: oneoff
schedule: 2026-06-11T22:00:00+02:00
next_run: 2026-06-11T22:00:00+02:00
created: 2026-06-11T17:30:00+02:00
status: done
---

## Instructions

Run the audit defined in `AUDIT_PLAYBOOK.md` (this folder, read it first)
with:

- REPO_DIR: `/Users/balazsgabor/Documents/workspace/kasa/device-service`
- REPO_NAME: `device-service`
- DD_SERVICE_QUERY: `service:device-service-*`

PRE-AUTHORIZED: write/overwrite `reports/fable-audit-device-service.md`.
Everything else is read-only toward the world per the playbook ground rules.

## Context

Smart-lock device domain service (NestJS). Sits in the lock cluster with
css-api and the vendor sync services.

Known and already planned — don't report as a new finding, but note anything
that raises its urgency: Jest keeps breaking on ESM-only deps; a Jest→Vitest
migration is agreed to happen in a separate PR (Zoli, device-service #146).
