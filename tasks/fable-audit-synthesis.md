---
id: fable-audit-synthesis
icon: chart.bar.doc.horizontal
title: "Fable audit: cross-repo synthesis"
type: oneoff
schedule: 2026-06-15T08:00:00+02:00
next_run: 2026-06-15T08:00:00+02:00
created: 2026-06-11T17:30:00+02:00
status: active
---

## Instructions

All 17 `fable-audit-*` runs should be done by now. Synthesize their reports
into the one artifact that outlives the Fable window.

### Step 1 — Inventory

List `reports/fable-audit-*.md` (excluding `SYNTHESIS`). 17 are expected
(15 services + hsp-libraries + jira). If any are missing or contain no
findings section, list them in the output under "Missing/failed audits" —
do not re-run them yourself.

### Step 2 — Synthesize

Read every report in full. Produce
`reports/fable-audit-SYNTHESIS.md`:

1. **Portfolio top 10** — the highest-impact findings across all repos,
   re-ranked against each other (a medium in css-api may outrank a high in
   simulator-service — weight by service criticality and guest impact).
   Each entry: repo, finding, evidence pointer, patch vs root-cause fix.
2. **Systemic patterns** — issues appearing in ≥ 2 repos (the four vendor
   sync services are the prime suspects). For each: which repos, the shared
   root cause, and whether the fix belongs in a shared lib /
   template-domain-mono-repo rather than per-repo patches.
3. **Cost rollup** — total estimated monthly savings across all reports,
   itemized, ordered by $ and effort.
4. **Chronic-error hit list** — the longest-running production errors found,
   with age, volume, and root cause.
5. **Draft ticket batch** — for each portfolio-top-10 and systemic finding,
   a ready-to-file HSP Jira ticket draft (title, description, suggested
   priority) **in the report only** — do not create tickets.
6. **Audit retro** — one short section: which playbook checks earned their
   cost, which produced noise, what a future audit round should change.

PRE-AUTHORIZED: write/overwrite `reports/fable-audit-SYNTHESIS.md`. Do not
create Jira tickets, PRs, or Slack messages; do not commit.

### Step 3 — Outcome

`Status: success` (or `failure` if fewer than 10 reports exist to
synthesize). `Severity: attention` always — this one Gabor should read.
Append a `## Notification` block: title "Fable audit synthesis ready",
body = top finding + total estimated monthly savings in one line.

## Context

Finale of the June 2026 Fable audit series (see `AUDIT_PLAYBOOK.md`). Gabor
has Fable 5 until June 22 — this lands the morning of June 15, leaving a
week to act on the findings interactively. The draft ticket batch is
deliberately report-only: he triages and files after cross-checking.
