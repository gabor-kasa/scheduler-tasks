---
id: fable-audit-stripe-sync
icon: magnifyingglass
title: "Fable audit: stripe-sync"
type: oneoff
schedule: 2026-06-15T22:00:00+02:00
next_run: 2026-06-15T22:00:00+02:00
created: 2026-06-11T17:30:00+02:00
status: active
---

## Instructions

Run the audit defined in `AUDIT_PLAYBOOK.md` (this folder, read it first)
with:

- REPO_DIR: `/Users/balazsgabor/Documents/workspace/kasa/stripe-sync`
- REPO_NAME: `stripe-sync`
- DD_SERVICE_QUERY: unknown — discover it (try `service:stripe-sync*`)

PRE-AUTHORIZED: write/overwrite `reports/fable-audit-stripe-sync.md`.
Everything else is read-only toward the world per the playbook ground rules.

## Context

Syncs Stripe data into Kasa systems. Money-adjacent, so the bug hunt should
weight idempotency, integer-vs-decimal amount handling, and webhook
ordering/replay handling especially heavily. Read-only as always — never
touch the Stripe API itself, only the repo and Datadog.
