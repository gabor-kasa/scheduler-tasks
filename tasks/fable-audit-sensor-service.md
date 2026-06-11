---
id: fable-audit-sensor-service
icon: magnifyingglass
title: "Fable audit: sensor-service"
type: oneoff
schedule: 2026-06-12T03:00:00+02:00
next_run: 2026-06-12T03:00:00+02:00
created: 2026-06-11T17:30:00+02:00
status: active
---

## Instructions

Run the audit defined in `AUDIT_PLAYBOOK.md` (this folder, read it first)
with:

- REPO_DIR: `/Users/balazsgabor/Documents/workspace/kasa/sensor-service`
- REPO_NAME: `sensor-service`
- DD_SERVICE_QUERY: unknown — discover it (try `service:sensor-service*`)

PRE-AUTHORIZED: write/overwrite `reports/fable-audit-sensor-service.md`.
Everything else is read-only toward the world per the playbook ground rules.

## Context

Sensor domain service (HSP team). Establish what it actually does from the
repo itself (Step 1 of the playbook) — likely in-unit sensor data
(noise/occupancy) ingestion and alerting.
