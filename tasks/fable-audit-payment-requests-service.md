---
id: fable-audit-payment-requests-service
icon: magnifyingglass
title: "Fable audit: payment-requests-service"
type: oneoff
schedule: 2026-06-13T22:00:00+02:00
next_run: 2026-06-13T22:00:00+02:00
created: 2026-06-11T17:30:00+02:00
status: active
---

## Instructions

Run the audit defined in `AUDIT_PLAYBOOK.md` (this folder, read it first)
with:

- REPO_DIR: `/Users/balazsgabor/Documents/workspace/kasa/payment-requests-service`
- REPO_NAME: `payment-requests-service`
- DD_SERVICE_QUERY: unknown — discover it (try
  `service:payment-requests-service*`)

PRE-AUTHORIZED: write/overwrite
`reports/fable-audit-payment-requests-service.md`. Everything else is
read-only toward the world per the playbook ground rules.

## Context

Payment requests domain service. Money-handling: weight idempotency,
double-charge/double-send races, and integer-vs-decimal amount handling
heavily in the bug hunt.
