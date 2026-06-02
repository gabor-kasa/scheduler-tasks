---
id: unreleased-changes-digest
icon: shippingbox
title: Unreleased changes digest
type: recurring
schedule: "30 7 * * 1"
created: 2026-06-01T12:00:00+02:00
status: active
---

## Instructions

Build Gabor a weekly digest of changes that are merged into each repo's
default branch on GitHub but **not yet released** (no release tag points at
them yet) — for every `kasadev` repo where Gabor (`gabor-kasa`) is a
CODEOWNER. Org is `kasadev`, GitHub login `gabor-kasa`, local timezone
Europe/Budapest. This run only needs `gh` (persistent token) — no AWS SSO.

The repo clones live as siblings of this scheduler tree at
`/Users/balazsgabor/Documents/workspace/kasa/<repo>` (i.e. `../<repo>` from
the project root, and the workspace root is `..`).

This is **read-only**. No mutations, no PRE-AUTHORIZED actions — only `gh`
read calls (`gh repo view`, `gh release view`, `gh api .../compare`,
`gh api .../tags`) and a local `rg` over the sibling CODEOWNERS files.

### Step 1 — Discover the CODEOWNER repos (dynamically, every run)

Do **not** hardcode the repo list — it drifts as repos are added, archived,
or ownership changes. Discover it fresh by scanning the local sibling
clones' CODEOWNERS files for `@gabor-kasa`:

```bash
rg --hidden -g 'CODEOWNERS' -g '!node_modules/**' -l '@gabor-kasa' .. \
  | cut -f2 -d/ | sort -u
```

Notes:
- `--hidden` is required — CODEOWNERS usually lives in the hidden `.github/`
  dir, and plain `rg` skips hidden dirs (this is the classic gotcha).
- `-g '!node_modules/**'` drops vendored copies (the published
  `code-api-types` package ships its own CODEOWNERS into many
  `node_modules/@kasadev/code-api-types/.github/CODEOWNERS`).
- For each candidate dir `<repo>`, **skip it unless `../<repo>/.git`
  exists** — directories like `css-api-ts6`, `salto-sync-ts6`,
  `smartthings-sync-ts6` are local migration working copies, not repos.
- **Archived repos are also excluded**, but archive status is a GitHub
  property not visible in the local clone, so that skip happens in Step 2
  once `gh repo view` runs (see Step 2.1). Known archived repos as of
  2026-06-01: `css-api-client`, `seam-sync-api-client`, `risk-score-service`
  — don't hardcode this list, it's just the current snapshot; the `gh`
  `isArchived` check is the source of truth.

### Step 2 — Per repo: compute unreleased commits + a compare link

For each discovered repo:

1. Default branch + archive status (one call):

   ```bash
   gh repo view kasadev/<repo> --json isArchived,defaultBranchRef \
     -q '{archived: .isArchived, branch: .defaultBranchRef.name}'
   ```

   If `archived == true` → **skip the repo entirely**: no compare, no
   staleness/anomaly classification, no digest section. Record it in the
   Execution narrative under "Skipped (archived)" (same as the non-`.git`
   skips in Step 1). An archived repo is frozen and will never cut another
   release, so unreleased commits sitting on it are expected, not a hygiene
   problem — listing them only generates false STALE noise. Otherwise use
   `.branch` as the default branch (most are `master`; handle `main` too).
2. Latest published release tag: `gh release view --repo kasadev/<repo> --json tagName -q '.tagName'`. If empty → the repo has **no releases**; record it under "No releases/tags" and move on (don't guess a baseline).
3. Compare the release tag to the default branch:

   ```bash
   gh api "repos/kasadev/<repo>/compare/<tag>...<defaultBranch>" \
     --jq '{status, ahead_by, behind_by, commits: [.commits[] | {sha: .sha[0:7], date: .commit.author.date, author: .commit.author.name, msg: (.commit.message|split("\n")[0])}]}'
   ```

   The compare link to put in the digest is:
   `https://github.com/kasadev/<repo>/compare/<tag>...<defaultBranch>`

   Interpret `status`:
   - `identical` / `ahead_by == 0` → **fully released** (tip == latest tag).
   - `ahead` → `ahead_by` unreleased commits sit on the default branch.
     `.commits` is ordered **oldest → newest**, so `commits[0].date` is the
     **oldest** unreleased commit (used for staleness in Step 3).
   - `diverged` or `behind` → the latest *release object* is **not on the
     default-branch line**. This is a versioning anomaly (a repo running two
     release schemes, or a release cut off a side branch). Flag it, and
     re-baseline against the highest semver **tag** that is reachable:

     ```bash
     hi=$(gh api "repos/kasadev/<repo>/tags?per_page=100" --jq '.[].name' \
            | grep -E '^v?[0-9]' | sort -V | tail -1)
     gh api "repos/kasadev/<repo>/compare/$hi...<defaultBranch>" --jq '{status, ahead_by}'
     ```

     Report the count vs `$hi` and use
     `https://github.com/kasadev/<repo>/compare/$hi...<defaultBranch>` as the
     link. (Known case: `css-api` publishes both an old `vNN.0.0` scheme — up
     to `v36.0.0` — and a newer `1.0.x` autorelease, so its "Latest" release
     object diverges from the `vNN` line.)

A note on the small `*-api-client` / `code-api-types` repos: a single
unreleased commit that is itself a `Merge pull request … from
kasadev/release-…` or `chore: release …` commit means an **autorelease PR is
merged but the tag hasn't been cut yet** — i.e. a release is in-flight rather
than net-new feature work. Note that inline when the lone unreleased commit's
subject starts with `Merge pull request` from a `release-*` branch or matches
`chore: release`.

### Step 3 — Staleness + anomaly classification (drives severity)

Compute the 14-day cutoff once: `cutoff=$(date -u -v-14d +%Y-%m-%dT%H:%M:%SZ)`.

For each repo with unreleased commits, classify:
- **STALE** — the oldest unreleased commit (`commits[0].date`, UTC ISO) is
  earlier than `cutoff` (string compare is valid for same-format UTC
  timestamps). Means work has been sitting un-released for >14 days —
  possibly forgotten or a stuck deploy.
- **ANOMALY** — the latest release tag was `diverged`/`behind` (Step 2).
- otherwise **FRESH** — recently merged, normal churn.

### Step 4 — Write the digest

Write the run log to `logs/unreleased-changes-digest-<NOW>.md`. The run's
stdout IS the log. Emit the report **exactly once**, then stop. Structure
(keep a heading with `_None._` if its section is empty, for a stable shape):

```
# Unreleased changes — CODEOWNER repos — <TODAY local>

<headline: e.g. "8 of 15 repos have unreleased commits on master · 1 stale (>14d) · 1 versioning anomaly">

## ⚠️ Needs attention
- [STALE] <repo> — <N> unreleased since <tag>, oldest <date> (<age>d ago) → <compare url>
- [ANOMALY] <repo> — release tag `<tag>` <diverged|behind> vs <branch>; vs `<hi>`: <N> unreleased → <compare url>

## 📦 Unreleased on default branch (merged, not yet released)
### <repo> — <N> since <tag>  → <compare url>
- <sha7>  <date>  <author>  <subject>
  ... (list every unreleased commit; if >15, list the 15 newest and add "+ <K> older")
  (if the lone commit is a pending autorelease, append "  ← release in-flight, not yet tagged")

## ✅ Fully released (default branch == latest tag)
- <repo> (<tag>)

## ❔ No releases/tags
- <repo>

## Outcome
- **Status:** <success | failure>
- **Severity:** <ok | attention | failure>
- **Finished:** <ISO timestamp with local offset>
- **Summary:** <one line: N repos scanned, M with unreleased, K stale, A anomalies>
```

### Step 5 — Severity + notification

In the `## Outcome`:
- `failure` — `gh` auth failed / a `gh api` call errored so the digest is
  incomplete. Put the error text in the log.
- `attention` — **only** if ≥1 repo is STALE or ≥1 is an ANOMALY.
- `ok` — everything that has unreleased commits is FRESH (normal churn, all
  <14 days), or nothing is unreleased. Silence is the success state here:
  there's almost always *some* recent merge waiting on a release, and that is
  not worth a banner.

If (and only if) severity is `attention`, append a `## Notification` block:

```
## Notification

- title: Unreleased changes
- subtitle: <K stale · A anomalies>
- body: <single most important item, ~90 chars — prefer the longest-stale repo: "<repo>: <N> commits unreleased <age>d (since <tag>)"; else the anomaly>
- sound: default
```

Skip the notification on `ok`/`failure`-without-attention runs.

## Context

These are the lock/code/device-management repos Gabor owns as a CODEOWNER
(seam-sync, css-api, code-setting-service, smartthings-sync, remotelock-sync,
salto-sync, device-service, sensor-service, the `*-api-client` packages,
etc.). The digest answers "what's merged to master but not yet released/
deployed?" — release hygiene, so nothing valuable sits un-shipped and
forgotten.

Built from a one-off analysis on 2026-06-01. The list is discovered fresh
each run (Step 1) rather than pinned, because releases move fast — within the
same afternoon that day, four repos went from "ahead" to released
(callbox-automation, remotelock-sync, salto-sync, smartthings-sync). A
hardcoded list would rot immediately.

Pairs with the weekday morning tasks ([[pr-review-queue]] 06:30,
[[lock-services-error-summary]] 07:00) but runs **weekly** on Monday 07:30 —
the list changes little day-to-day, so daily would be noise. Read-only; no
PRE-AUTHORIZED mutations.
