---
id: fable-audit-sns-events
icon: magnifyingglass
title: "Fable audit: sns-events"
type: oneoff
schedule: 2026-06-17T03:00:00+02:00
next_run: 2026-06-17T03:00:00+02:00
created: 2026-06-11T17:30:00+02:00
status: active
---

## Instructions

Run the audit defined in `AUDIT_PLAYBOOK.md` (this folder, read it first)
with:

- REPO_DIR: `/Users/balazsgabor/Documents/workspace/kasa/sns-events`
- REPO_NAME: `sns-events`
- DD_SERVICE_QUERY: unknown — discover it, and if it has no runtime
  Datadog presence (it may be event definitions/infra rather than a
  service), skip Step 3 with a note

PRE-AUTHORIZED: write/overwrite `reports/fable-audit-sns-events.md`.
Everything else is read-only toward the world per the playbook ground rules.

## Context

SNS event definitions / event-bus glue for HSP services. If it turns out to
be mostly a shared package + infra, focus on the architecture pass: event
schema versioning/compat, consumers' contract drift, and dead event types
nobody publishes or consumes anymore.
