---
id: fable-audit-css-api
icon: magnifyingglass
title: "Fable audit: css-api"
type: oneoff
schedule: 2026-06-11T22:00:00+02:00
next_run: 2026-06-11T22:00:00+02:00
created: 2026-06-11T17:30:00+02:00
status: active
---

## Instructions

Run the audit defined in `AUDIT_PLAYBOOK.md` (this folder, read it first)
with:

- REPO_DIR: `/Users/balazsgabor/Documents/workspace/kasa/css-api`
- REPO_NAME: `css-api`
- DD_SERVICE_QUERY: `service:css-api`

PRE-AUTHORIZED: write/overwrite `reports/fable-audit-css-api.md`. Everything
else is read-only toward the world per the playbook ground rules.

## Context

Code Setting Service API — Kasa's lock-code management service (Express on
Fargate). The most critical service in the HSP lock cluster, and the
migration target for the legacy `code-setting-service` Lambdas. The
`shared-kasa-css-api` skill has codebase background if useful.

Special focus: on June 1, 2026 a dark-launched `codeAuditQueueFiller` fired
with `dryRun=false` and revoked active guest lock codes. Beyond the normal
playbook passes, review the guard rails around destructive/batch jobs:
dry-run defaults, dark-launch config plumbing, and whether other jobs share
the same failure shape.
