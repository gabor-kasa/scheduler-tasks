---
id: fable-audit-url-shortener
icon: magnifyingglass
title: "Fable audit: url-shortener"
type: oneoff
schedule: 2026-06-17T22:00:00+02:00
next_run: 2026-06-17T22:00:00+02:00
created: 2026-06-11T17:30:00+02:00
status: active
---

## Instructions

Run the audit defined in `AUDIT_PLAYBOOK.md` (this folder, read it first)
with:

- REPO_DIR: `/Users/balazsgabor/Documents/workspace/kasa/url-shortener`
- REPO_NAME: `url-shortener`
- DD_SERVICE_QUERY: unknown — discover it (try `service:url-shortener*` or
  `service:kurl*`)

PRE-AUTHORIZED: write/overwrite `reports/fable-audit-url-shortener.md`.
Everything else is read-only toward the world per the playbook ground rules.

## Context

URL shortener service (guest-facing short links, e.g. in SMS). Guest-facing
availability matters more than feature depth here — weight the bug hunt
toward link-resolution failure modes, expiry/collision handling, and
abuse/enumeration exposure.
