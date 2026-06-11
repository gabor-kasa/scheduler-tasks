---
id: fable-audit-code-setting-service
icon: magnifyingglass
title: "Fable audit: code-setting-service (legacy / migration status)"
type: oneoff
schedule: 2026-06-14T06:00:00+02:00
next_run: 2026-06-14T06:00:00+02:00
created: 2026-06-11T17:30:00+02:00
status: active
---

## Instructions

Run the audit defined in `AUDIT_PLAYBOOK.md` (this folder, read it first)
with:

- REPO_DIR: `/Users/balazsgabor/Documents/workspace/kasa/code-setting-service`
- REPO_NAME: `code-setting-service`
- DD_SERVICE_QUERY: `service:code-setting-service-production*`

**Scope override — this repo is legacy.** It is being migrated to css-api
(the `shared-kasa-css-api-migration` skill describes the effort). Skip the
refactor-oriented parts of the static pass — do not propose improvements to
code that is slated for deletion. Instead the report should answer:

1. **What's left** — which handlers/functions/models are still live here vs
   already ported to css-api (compare against the css-api repo).
2. **What's still receiving traffic** — from 90 days of Datadog
   logs/metrics, which Lambdas still fire, how often, and triggered by what.
3. **Chronic errors** — playbook Step 3.1 still applies; if a chronic error
   lives in already-ported code, the fix recommendation is "finish the
   migration for X", not a patch here.
4. **Cost of keeping it** — monthly footprint, and what decommissioning
   would save.
5. **Decommission blockers** — ranked list of what must move before this
   can be turned off.

PRE-AUTHORIZED: write/overwrite
`reports/fable-audit-code-setting-service.md`. Everything else is read-only
toward the world per the playbook ground rules.

## Context

Legacy Serverless-Lambda lock-code service, predecessor of css-api. The
css-api audit report from night 1 (`reports/fable-audit-css-api.md`) should
already exist — read it for the receiving side's state.
