---
id: fable-audit-simulator-service
icon: magnifyingglass
title: "Fable audit: simulator-service"
type: oneoff
schedule: 2026-06-16T22:00:00+02:00
next_run: 2026-06-16T22:00:00+02:00
created: 2026-06-11T17:30:00+02:00
status: active
---

## Instructions

Run the audit defined in `AUDIT_PLAYBOOK.md` (this folder, read it first)
with:

- REPO_DIR: `/Users/balazsgabor/Documents/workspace/kasa/simulator-service`
- REPO_NAME: `simulator-service`
- DD_SERVICE_QUERY: unknown — discover it (try `service:simulator-service*`)

PRE-AUTHORIZED: write/overwrite `reports/fable-audit-simulator-service.md`.
Everything else is read-only toward the world per the playbook ground rules.

## Context

Device/lock simulator used for testing the lock cluster. Lower production
criticality — Datadog signals may be sparse; if so, say so and lean on the
static passes. Cost still matters: a test service quietly running
production-sized infra is exactly the kind of finding to surface.
