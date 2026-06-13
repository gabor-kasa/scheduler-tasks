---
id: fable-audit-hsp-libraries
icon: magnifyingglass
title: "Fable audit: HSP libraries batch"
type: oneoff
model: claude-opus-4-8
effort: high
schedule: 2026-06-18T22:00:00+02:00
next_run: 2026-06-18T22:00:00+02:00
created: 2026-06-11T17:30:00+02:00
status: active
---

## Instructions

Run the static parts of `AUDIT_PLAYBOOK.md` (this folder, read it first) —
Steps 0–2 and 6–7 — against each of these five small HSP-owned libraries.
Steps 3–5 (Datadog/AWS/cost) don't apply to npm packages; skip them with a
note.

All under `/Users/balazsgabor/Documents/workspace/kasa/`:

1. `code-api-types`
2. `file-utils`
3. `lambda-utils`
4. `url-shortener-api-client`
5. `css-debugger`

Write **one combined report**, `reports/fable-audit-hsp-libraries.md`, with
a section per library. For libraries, additionally cover:

- **Consumer reality check** — who actually depends on each package (search
  the other audited repos' package.json files under the same workspace
  folder). A published lib with zero consumers is a finding.
- **API surface drift** — exported-but-unused symbols, types out of sync
  with the services that consume them (code-api-types especially: compare
  against css-api and code-setting-service).
- **Publish health** — Node engines, TS version, build/publish CI state.
  Note: `@kasadev` is a private scope on npmjs.org; the local `~/.npmrc`
  token covers reads. Treat npm-registry auth failures as a skip-with-note,
  not a task failure.

PRE-AUTHORIZED: write/overwrite `reports/fable-audit-hsp-libraries.md`.
Everything else is read-only toward the world per the playbook ground rules.

## Context

These are too small to deserve a night-slot each, but they're load-bearing
for the lock cluster (lambda-utils and code-api-types especially). Findings
that say "fold this into an existing shared lib" or "archive this" are
welcome.
