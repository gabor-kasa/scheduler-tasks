---
id: pr-review-queue
icon: arrow.triangle.pull
title: Morning PR review queue — triage, dependabot, /review
type: recurring
schedule: "30 6 * * 1-5"
next_run: 2026-06-01T06:30:00+02:00
last_run: 2026-05-29T15:14:26+02:00
created: 2026-05-29T18:00:00+02:00
status: active
---

## Instructions

You build Gabor's morning pull-request review queue. GitHub login is
`gabor-kasa`, org is `kasadev`, the relevant GitHub team is
`kasadev/hospitality`. Local timezone Europe/Budapest. All local repo
clones live as siblings of this scheduler tree under
`/Users/balazsgabor/Documents/workspace/kasa/<repo>` (i.e. `../<repo>`
from the project root).

The task does three things, in priority order:

1. **Triage** every PR where Gabor is a requested reviewer **by name**,
   splitting human-authored PRs (→ run `/review`) from dependabot PRs
   (→ build-check + safe-to-merge / fix / comment, **never** `/review`).
2. **Exclude** PRs where Gabor is only pulled in via the `hospitality`
   team (not requested by name) — list them so he knows, take no action.
3. For **dependabot** PRs by name: classify safe-to-merge, or when CI is
   red, fix it in an isolated worktree and **auto-push when CI goes green
   locally** (metadata or source edits alike — a source edit is pushed
   but loudly flagged and never merged), else comment a diagnosis.

Everything routes into one log Gabor reads with his coffee.

### Step 0 — Load review state

Read `logs/pr-review-state.json` (JSON; create `{ "reviewed": {},
"dependabot": {} }` if missing or unparseable). Shape:

```json
{
  "reviewed":   { "kasadev/<repo>#<num>": { "sha": "<head sha>", "at": "<iso>" } },
  "dependabot": { "kasadev/<repo>#<num>": { "sha": "<head sha>", "action": "commented|pushed|pushed-source|safe|rebase|recreate", "at": "<iso>" } }
}
```

This is how the task avoids re-reviewing unchanged PRs and re-commenting
/ re-pushing the same dependabot PR every morning. Write it back in
Step 7.

### Step 1 — Build the queue

One search gets the union of by-name and team-requested PRs (GitHub's
`review-requested:` includes PRs you're pulled into via team
membership):

```bash
gh api -X GET /search/issues \
  --raw-field q='is:open is:pr review-requested:gabor-kasa archived:false' \
  --jq '.items[] | {repo:(.repository_url|split("/")|last), num:.number, title:.title, author:.user.login, url:.html_url}'
```

`archived:false` drops archived repos (e.g. `pms-api-client`) — those
are safe to skip entirely. Paginate (`&page=2…`) if `total_count`
exceeds the page size.

### Step 2 — Classify each PR

For every PR from Step 1, fetch detail:

```bash
gh api /repos/kasadev/<repo>/pulls/<num> --jq '{
  reviewers:[.requested_reviewers[].login],
  teams:[.requested_teams[].slug],
  author:.user.login, draft:.draft, head:.head.sha,
  headRef:.head.ref, adds:.additions, dels:.deletions, files:.changed_files,
  mergeable:.mergeable, mergeable_state:.mergeable_state
}'
```

`mergeable_state` of `dirty` means merge conflicts; `behind` means the
branch trails its base. When `../<repo>` exists, both are best fixed by
**resolving the conflict locally** (Step 6-resolve) — a rebase onto master
in a worktree + lockfile regen. Only fall back to asking dependabot to
rebase (Step 6a) when there's no local clone.

Then bucket:

- **by_name** = `gabor-kasa` ∈ `reviewers`. These are Gabor's to act on.
- **group_only** = NOT by_name (he's only in via the `hospitality` team
  or another team). → Step 3 (list and exclude, no action).

Within **by_name**, split on author:

- `author == "dependabot[bot]"` → **dependabot** bucket → Step 5.
- otherwise → **human** bucket → Step 4.

**Exclude drafts:** if `draft == true`, drop the PR entirely — no
triage, no `/review`, no dependabot handling. Collect it only for a
compact "Drafts (skipped)" line in the log so Gabor knows it exists.
Apply this before the by_name / group_only split, so drafts never reach
Steps 3–6.

### Step 3 — Group-assigned PRs (exclude, no action)

For every `group_only` PR, collect `{repo#num, title, author, url, teams}`
for the "Group-assigned" section of the log. **Do not** run `/review`,
do not comment, do not touch reviewers — Gabor decided these are not his
to act on. (Removing himself isn't individually possible when the team
is the reviewer; dismissing would drop the request for the whole team.)

### Step 4 — Human PRs → /review

For each human by-name PR:

1. **Skip-if-unchanged:** if `reviewed["kasadev/<repo>#<num>"].sha`
   equals the current `head` sha, do **not** re-review. Record it for the
   compact "Previously reviewed — no new commits" list and move on.
2. Otherwise spawn an inner Claude to review it. Build the inner prompt
   from `## Inner review prompt template` below, write it to
   `/tmp/pr-review-<repo>-<num>.md`, then run with the repo as cwd and a
   5-minute timeout:

   ```bash
   (cd ../<repo> && claude -p --output-format text < /tmp/pr-review-<repo>-<num>.md)
   ```

   Capture stdout. Delete the temp file.
3. If the call errors / times out / returns empty, record a
   `(review failed: <reason>)` placeholder and continue.
4. On success, set `reviewed["kasadev/<repo>#<num>"] = { sha: <head>, at: <now> }`.

The inner review is for **Gabor's eyes only** — it must NOT post anything
to GitHub. Its stdout goes verbatim into the log.

### Step 5 — Dependabot PRs (never /review)

For each dependabot by-name PR, get CI status:

```bash
gh pr checks <num> --repo kasadev/<repo>
```

Output is tab-separated `name⇥status⇥duration⇥url`; `status` is
`pass` / `fail` / `pending` / `skipping`. Treat the PR as **failing** if
any required check is `fail`, **green** if none fail and none pending,
**pending** otherwise (record pending as "CI still running", no action).

Classify the bump from the title (`bump X from a.b.c to a.b.d`, or
"…group with N updates"):

- **patch** / **minor**, single package → eligible for safe-to-merge.
- **major** bump, or a **group** update (multiple packages) → never
  safe-to-merge; list under "green — eyeball the changelog".

Then:

**5a. Green + single patch/minor →** add to **✅ Safe to merge**. Do NOT
merge it (Gabor merges). Record `dependabot[...] = {sha, action:"safe"}`.

**5b. Green + major/group →** add to **🟡 Green, review changelog**.
No mutation.

**5c. Failing →** attempt a fix, else comment. See Step 6.

Skip entirely if `dependabot["kasadev/<repo>#<num>"].sha == head` AND its
prior `action` was `commented`, `pushed`, `pushed-source`, or `safe` —
already handled at this exact SHA; just note "already handled (no new
commits)".

A prior `action` of `rebase` or `recreate` at the **same** head sha is
**not** "handled" — it means we issued a `@dependabot` command and are
waiting for it to land. A command the bot *refuses* (e.g. "can't rebase")
leaves the head sha unchanged forever, so blindly skipping would strand
the PR as permanently dirty. Route these to **Step 6a-verify** first.

### Step 6 — Failing dependabot: rebase, fix + verify + push, or comment

Only ever do this for **dependabot** PRs requested **by name**. Never
touch a human-authored PR's branch. Pick the **first** path that applies:

- **6a-verify — A bot command is already outstanding →** if state shows
  `action:"rebase"`/`"recreate"` at this same sha, check whether it landed
  or was refused. If refused and `../<repo>` exists, prefer **6-resolve**
  over another bot command. Do this before anything else so a refused
  command can't strand the PR.
- **6-resolve — Dirty / behind branch + local clone exists →** rebase onto
  master in a worktree, resolve the (mechanical) conflicts yourself,
  verify the full suite, force-push. **Preferred** fix for dirty PRs —
  don't wait on dependabot when the conflict is mechanical.
- **6a — Dirty / behind but NO local clone →** ask dependabot to rebase
  (a bare bot command). Fallback only when we can't resolve locally.
- **6b/6c — CI failure on a mergeable branch with a determinable fix →**
  fix it in an isolated worktree, verify, and push (never merge).
- **6d — Non-mechanical conflict, no verifiable fix, or no local clone →**
  post a `[Claude]` diagnosis / hand-off comment.

**What the fix may touch.** Whatever it takes to make CI green —
including source files (`.ts`/`.tsx`/`.js`), config, and tests. There is
no longer a "mechanical-only" file restriction. The change is instead
**categorized**, which sets the push gate and how loudly it's surfaced:

1. **Metadata-only fix** — touches ONLY lockfiles (`package-lock.json`,
   `yarn.lock`, `pnpm-lock.yaml`), the `package.json` dependency stanza,
   and/or a missing `client/CHANGELOG.md` entry (see 6c-ii). No runtime
   behavior changes. **Push gate:** the originally-failing check(s) go
   green locally. Surfaced under **🔧 Fixed automatically (lockfile/dep
   sync)**.
2. **Source-touching fix** — edits any other file (`.ts`/`.js`/config/
   test) to satisfy the bump. Allowed even for **major** bumps, but the
   bar is higher (6c-iii): the **entire** build + lint + test suite must
   pass locally — not just the check that was failing — and the push MUST
   carry the diff + a "review-the-semantics" banner (6e). Surfaced under
   **🛠️ Fixed automatically — source edit (review semantics)**, never
   mixed in with metadata fixes.

A note on the changelog gate (metadata case): the
`dangoslen/dependabot-changelog-helper` action only runs on PRs that
touch `client/**`, so root-only bumps (typescript, eslint, release-it, …)
skip it and a `client/CHANGELOG.md` gate then fails — add the missing
entry (6c-ii).

**The push is never a merge.** Whatever the category, the task pushes to
the PR's own head branch and leaves it green for Gabor to merge. It never
merges, and never pushes to `master`/`main`/`dev`.

**6a-verify. Did a previously-issued bot command land?**

Reach here when state shows `action:"rebase"` or `action:"recreate"` for
this PR at the **same** head sha (no new commit since we issued the
command). A successful rebase/recreate **always** produces a new head
commit — so an unchanged sha means the command either hasn't run yet or
the bot refused it. Read dependabot's **latest** reply to decide:

```bash
gh pr view <num> --repo kasadev/<repo> --json comments \
  --jq '[.comments[] | select(.author.login=="dependabot")] | last | .body'
```

Decide by the **content** of that latest dependabot reply (do **not** gate
on the state `at` timestamp — `at` is the run-*end* time, while dependabot
replies within seconds of the command, so the refusal usually predates
`at`). Because a successful command would have moved the head sha (and we
wouldn't be here), an unchanged sha + a refusal reply means it's stuck:

- **Latest reply is not a refusal** (an acknowledgement, or no dependabot
  comment at all) → the command is still queued. Note "rebase/recreate
  pending — awaiting dependabot", keep the existing state entry, take no
  further action this run.
- **Bot refused the rebase** — reply contains "can't rebase" or "edited by
  someone other than Dependabot". This happens when a `github-actions[bot]`
  commit sits on top of dependabot's commit (the most common cause in this
  org is the changelog-helper's "Updated Changelog" commit), so the branch
  is no longer pure-dependabot and rebase is blocked. **If `../<repo>`
  exists, go to 6-resolve** — resolve the conflict locally instead of
  asking dependabot again (`recreate` only re-triggers the changelog action
  and the ladder churns). Only if there's **no local clone** and we have
  **not** already tried recreate (`action != "recreate"`), post the bare
  command:

  ```bash
  gh pr comment <num> --repo kasadev/<repo> --body '@dependabot recreate'
  ```

  `recreate` rebuilds the PR from scratch against current `master`,
  overwriting the bot-blocking commits. Post it **bare, no `[Claude]`
  marker** (machine command — same exception as 6a). Add the PR to "♻️
  Rebase refused → asked dependabot to recreate" and record
  `dependabot[...] = {sha, action:"recreate"}`. Stop here for this PR.
- **Bot refused the recreate too**, OR `action` was already `recreate` and
  the sha still hasn't moved, OR any other terminal bot failure → the bot
  can't self-resolve this branch. Fall through to **6d** and post one
  `[Claude]` diagnosis comment: branch is stale + conflicted, dependabot
  can't rebase or recreate it, needs a manual rebase or a close-and-let
  -dependabot-reopen. Record `action:"commented"` so it surfaces under
  "💬 Commented — needs you" and isn't retried at this sha. (Respect the
  6d idempotency rule — don't double-post at the same sha.)

**6a. Stale or conflicted branch → ask dependabot to rebase (no-clone fallback):**

Use this **only when `../<repo>` is not available locally** — otherwise
resolve the conflict yourself in 6-resolve. If `mergeable_state` is
`dirty` (conflicts) or `behind` (trails base), or the failing checks are
clearly a stale-branch artifact, comment the bare bot command and stop
here for this PR:

```bash
gh pr comment <num> --repo kasadev/<repo> --body '@dependabot rebase'
```

**No `[Claude]` marker on this comment** — dependabot parses the comment
body for its command (`@dependabot rebase`, or `@dependabot recreate` to
also regenerate the lockfile), and the marker prefix would break parsing.
This is the one exception to the marker rule; it's a machine command, not
a human-facing note. Add the PR to "🔄 Asked dependabot to rebase" and
record `dependabot[...] = {sha, action:"rebase"}`. Idempotency: don't
re-issue `@dependabot rebase` for the same `head` sha twice — if state
already shows `action:"rebase"` at this sha, do **not** silently skip;
go to **Step 6a-verify** to check whether the rebase landed or the bot
refused it (and escalate to `recreate` / a comment accordingly).

**6-resolve. Dirty / conflicted branch → resolve it locally (preferred):**

The primary path for a dependabot PR whose `mergeable_state` is `dirty`
(conflicts) or `behind` (trails base), **whenever `../<repo>` exists.** Do
NOT default to `@dependabot rebase` for these — a changelog-helper
"Updated Changelog" commit usually blocks the bot's rebase, and `recreate`
just re-triggers the same action, so the ladder churns without ever
landing the PR. Resolve it yourself: the conflict in a dependabot bump is
almost always confined to **mechanical** files (`package-lock.json`, the
`package.json` dependency stanzas, `client/CHANGELOG.md`).

Prepare the worktree (6b), then in `/tmp/pr-fix-<repo>-<num>`:

1. `git fetch origin master` then `git rebase origin/master`.
2. Resolve each conflict, but ONLY in mechanical files:
   - **`package.json` (any workspace):** keep BOTH sides' dependency
     changes; where the SAME package conflicts, take the **higher** semver;
     where one side added/removed a dep the other didn't touch, keep that
     change. Never touch non-dependency stanzas (scripts/config).
   - **lockfile** (`package-lock.json`/`yarn.lock`/`pnpm-lock.yaml`): don't
     hand-merge — take either side, then regenerate it with a fresh install
     after the `package.json` files are reconciled.
   - **`client/CHANGELOG.md`:** keep both entries, preserving the template
     block (6c-ii rules).
   - `git add -A && git rebase --continue` until the rebase completes.
3. **Bail to 6d if** a conflict lands in ANY non-mechanical file
   (`.ts`/`.js`/config logic/tests), or a `package.json` conflict is
   structural rather than a plain version difference (needs human
   judgment). `git rebase --abort`, clean the worktree (6f), and post a
   `[Claude]` hand-off comment naming the file(s) that need manual
   resolution. Record `action:"commented"`.
4. Run the **full** suite — **build AND lint AND test, all three** (as in
   6c-iii). Rebasing onto master frequently surfaces NEW failures the bump
   didn't have before — a stricter `typescript-eslint` flagging fresh
   `no-unnecessary-type-assertion` errors is exactly what slipped through
   on css-api#136 when only `build` was run, leaving the branch CI-red
   after the push. **Never push on a build-only check.** If lint/test now
   fail on auto-fixable issues, fix them too (e.g. `eslint --fix`) and
   re-run until all three are green; if a fix needs a non-mechanical edit,
   treat it as a source-touching fix (6c-iii) but keep the same full-suite
   gate. All three green?
5. Force-push the rewritten branch:

   ```bash
   git -C /tmp/pr-fix-<repo>-<num> push --force-with-lease origin HEAD:<headRef>
   ```

   Record `dependabot[...] = {sha, action:"pushed"}`. Post a `[Claude]`
   confirmation comment (6e): conflict resolved, lockfile regenerated, full
   suite green locally. Add to "🔧 Fixed automatically (lockfile/dep sync)"
   with a "(resolved merge conflict)" note. Clean the worktree (6f).

If `../<repo>` does **not** exist locally → fall back to **6a**.

**6b. Prepare an isolated worktree (never disturb Gabor's clone):**

If `../<repo>` doesn't exist locally → skip the repro, go straight to
6d (comment) with a "no local clone to reproduce" note.

Otherwise, in the local clone, fetch the PR head and add a throwaway
worktree under `/tmp` — this never changes the branch or working tree of
Gabor's clone:

```bash
git -C ../<repo> fetch origin "pull/<num>/head:pr-<num>-fix"
git -C ../<repo> worktree add -f /tmp/pr-fix-<repo>-<num> pr-<num>-fix
```

**6c. Reproduce + attempt the fix in the worktree:**

Working in `/tmp/pr-fix-<repo>-<num>`:

**6c-i. Install + reproduce:** Detect the package manager by lockfile and
run a fresh install (`npm install` / `yarn install` / `pnpm install`) —
this regenerates the lockfile if it was out of sync. Then reproduce the
failing check locally — infer the command from the failing check names in
Step 5 (e.g. `lint-app`, `tests`, `Client Build`, `typecheck`) and the
repo's `package.json` scripts (common: `npm run build`, `npm run lint`,
`npm test`, `npm run typecheck`). If a fresh install alone clears the
check and `git diff --name-only` shows only metadata files, it's a
**metadata-only fix** → go to the push decision below. If the check still
fails and the cause is in source/config/tests, go to 6c-iii.

**6c-ii. Missing changelog entry:** If a changelog check is failing (a
check whose name contains `changelog`) and `client/CHANGELOG.md` exists,
add an entry — following the file's existing Keep-a-Changelog style:

- Entries live under a `## [Unreleased-patch]` section (matching the
  `version: Unreleased-patch` the repo's `dependabot-changelog.yml`
  configures). If that section doesn't exist yet, create it as the FIRST
  release section — i.e. immediately **after** the template block, before
  the newest dated `## [x.y.z]` section. If it exists, append under it.
- Use the category line `updated:` and a bullet matching the PR. For a
  single package: `- bump <package> from <old> to <new>`. For a group
  update: `- dependency updates`. Mirror the punctuation/casing of
  existing bullets in that file.
- **🚨 NEVER remove or rewrite the template block.** The top of every
  `client/CHANGELOG.md` is:

  ````
  # Changelog

  ```md
  ## [Unreleased-{major|minor|patch}]

  added:

  - comment about what was added
  ```
  ````

  That fenced ` ```md ` example block is a permanent template, not a real
  entry — it must survive untouched. Insert new content strictly **below**
  it. Before committing, assert the literal template block is still
  present in the file; if it isn't, you broke it — restore it and re-do
  the edit. (This is a known failure mode: editors tend to "tidy up" the
  example away. Don't.)

**6c-iii. Source-touching fix (incl. major bumps):** If turning CI green
needs a code/config/test edit, **understand the bump before editing**:
read the dependency's changelog / migration notes across the version
range (`bump X from <old> to <new>`) and the actual usage in the repo,
then reason about whether the breakage is a pure type/signature
adjustment or a real behavioral change. Make the **minimal** edit that
both compiles and preserves the existing runtime contract — do not just
silence the compiler. (Real example: sqs-consumer v15 widened
`handleMessage`'s return type from `void` to `Message | undefined`; code
that signals failure by *throwing* and returns `undefined` on success is
unaffected at runtime, so the correct fix is a type adjustment, not a
rewrite of message handling.)

After 6c-i / 6c-ii / 6c-iii, decide the push by category:

- **Metadata-only & green:** `git diff --name-only` shows ONLY lockfiles,
  the `package.json` dep stanza, and/or `client/CHANGELOG.md`, AND the
  originally-failing check now passes locally → commit + push (below),
  record `dependabot[...] = {sha, action:"pushed"}`, post a short
  `[Claude]` confirmation comment (6e), add to "🔧 Fixed automatically
  (lockfile/dep sync)".

- **Source-touching & FULL suite green:** the diff includes a source/
  config/test file AND the **entire** build + lint + test suite passes
  locally — run them all, not just the originally-failing check
  (`npm run build && npm run lint && npm test`, or the repo's
  equivalents; for nx monorepos like seam-sync that's
  `npx nx run-many --target=build|lint|test --all`). All green → commit +
  push (below), record `dependabot[...] = {sha, action:"pushed-source"}`,
  post a `[Claude]` comment that **includes the diff and the
  review-semantics banner** (6e), add to "🛠️ Fixed automatically —
  source edit (review semantics)". If it's a **major** bump, say so
  explicitly in both the comment and the log line.

- **Still red, suite not fully green, or no determinable fix →** go to 6d.

Commit + push (both categories — to the PR's own head branch, never
merge, never `master`/`main`/`dev`):

```bash
git -C /tmp/pr-fix-<repo>-<num> add -A
# Message names what was actually done, e.g.
#   "chore: regenerate lockfile to fix CI"
#   "chore: add changelog entry"
#   "fix: adjust handleMessage typing for sqs-consumer v15"
git -C /tmp/pr-fix-<repo>-<num> commit -m "<accurate message>

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git -C /tmp/pr-fix-<repo>-<num> push origin HEAD:<headRef>
```

**6d. Comment a diagnosis (no push):**

When no fix can be verified green (the suite won't pass, the fix is
ambiguous, or there's no local clone to reproduce in), post one `[Claude]`
comment (6e) with: the failing check(s), the root-cause one-liner, and a
concrete suggested patch. Add to "💬 Commented — needs you". Record
`dependabot[...] = {sha, action:"commented"}`.

Idempotency: before posting in 6d (or 6c's confirmation comment), if
`dependabot["kasadev/<repo>#<num>"].sha == head` and a prior `[Claude]`
comment already exists on the PR at this SHA, do NOT re-comment.

**6e. Comment format — ALWAYS mark Claude-authored comments.**

Every comment this task posts MUST be clearly distinguishable from
Gabor's own comments. Lead with the marker line, verbatim:

```
🤖 **[Claude]** — automated note from Gabor's scheduled PR-triage task (not posted by Gabor).

<body: failing checks, root cause, suggested patch OR what was pushed>
```

**When the push was a source-touching fix (6c-iii):** the comment body
MUST additionally include (a) the pushed diff in a fenced ` ```diff `
block, (b) which checks now pass locally (the full build+lint+test
suite), and (c) this banner verbatim (drop the "on a MAJOR version bump"
clause when the bump isn't major):

> ⚠️ This pushed a **source-code** change to satisfy the bump, on a MAJOR version bump — green CI confirms it compiles and tests pass locally, but **review the runtime semantics before merging**, not just the green check.

Post with `gh pr comment <num> --repo kasadev/<repo> --body-file <tmp>`.
(The `@dependabot rebase` command in 6a is the **only** exception — it is
posted bare, with no marker, so dependabot can parse it.)

**6f. Clean up the worktree (always, even on failure):**

```bash
git -C ../<repo> worktree remove --force /tmp/pr-fix-<repo>-<num>
git -C ../<repo> branch -D pr-<num>-fix 2>/dev/null
```

Leave Gabor's clone exactly as it was — verify with
`git -C ../<repo> status --short` and `git -C ../<repo> branch --show-current`
afterward; if either changed, note it loudly in the log.

### Step 7 — Write the log + persist state

Write the run log in this structure (omit a section's items but keep the
heading with `_None._` if empty, for a stable shape):

```
# PR review queue — <TODAY local>

<headline: e.g. "3 need your review · 2 dependabot fixed · 1 commented · 4 safe to merge · 5 group-assigned (excluded)">

## ⚠️ Needs your review
### <repo>#<num> — <title>  ·  by <author>  ·  +<adds>/-<dels>, <files> files
<url>
**What it does:** <2–3 sentences>
**Context:** <what Gabor should know — related tickets, blast radius, why now>
**Findings:**
- [blocker] …
- [concern] …
- [nit] …
<new commits since last review: <short sha> | first review>

## 🔁 Previously reviewed — no new commits
- <repo>#<num> <title> <url>

## 🤖 Dependabot (by name)
### 🔄 Asked dependabot to rebase (stale/conflicted branch)
- <repo>#<num> <title> — <dirty|behind>. <url>
### ♻️ Rebase refused → asked dependabot to recreate
- <repo>#<num> <title> — bot couldn't rebase (branch edited by github-actions). <url>
### 🔧 Fixed automatically (lockfile/dep sync pushed, CI re-running)
- <repo>#<num> <title> — pushed: <one line>. <url>
### 🛠️ Fixed automatically — source edit (review semantics before merging)
- <repo>#<num> <title> — <MAJOR?> pushed source fix: <one line>; full build+lint+test green locally. <url>
### 💬 Commented — needs you
- <repo>#<num> <title> — <root-cause one-liner>. <url>
### ✅ Safe to merge (green, single patch/minor)
- <repo>#<num> <title> <url>
### 🟡 Green — review changelog (major or group bump)
- <repo>#<num> <title> <url>
### ⏳ CI still running
- <repo>#<num> <title> <url>

## 👥 Group-assigned via hospitality (excluded — not yours by name)
- <repo>#<num> <title> by <author> <url>

## ✏️ Drafts (skipped)
- <repo>#<num> <title> by <author> <url>

## Outcome
- **Status:** <success | failure>
- **Severity:** <ok | attention | failure>
- **Finished:** <ISO timestamp with local offset>
- **Summary:** <one line with the counts>
```

Then write the updated state object back to `logs/pr-review-state.json`.
Prune entries for PRs no longer in today's open queue so the file
doesn't grow forever.

### Step 8 — Severity + Notification

Severity:

- `failure` — the `gh` search / auth failed and the queue couldn't be
  built. Put the error text in the log.
- `attention` — any of: ≥1 human PR needs review, ≥1 dependabot fix was
  pushed, ≥1 dependabot PR was commented (needs Gabor), or ≥1 safe-to
  -merge PR is waiting. (The normal weekday state.)
- `ok` — nothing actionable: no human PRs needing review, no failing
  dependabot, nothing safe-to-merge waiting (only group-assigned /
  already-reviewed / pending).

If `attention` or `failure`, append a `## Notification` block:

```
## Notification

- title: PR review queue
- subtitle: <N review · M dependabot · K safe-to-merge>
- body: <single most important item, ~90 chars. Prefer a source-edit
        auto-push (esp. a major — needs a semantics check before merge);
        else a human PR needing review; else a commented/failing
        dependabot; else "K PRs safe to merge">
- sound: default
```

Skip the notification on `ok` runs — silence is the success state.

## Inner review prompt template

Verbatim — the outer task fills `{{REPO}}`, `{{NUM}}`, `{{TITLE}}`,
`{{AUTHOR}}` and writes the result to a temp file before piping to
`claude -p` with `../{{REPO}}` as cwd.

```
You are reviewing a GitHub pull request for an engineering manager (Gabor) who
will read your output instead of opening the PR cold. Repo: kasadev/{{REPO}}.
PR #{{NUM}} — "{{TITLE}}" by {{AUTHOR}}.

# Do this
1. If a `/review` skill is available to you (a "review" skill that reviews a
   pull request), invoke it against PR #{{NUM}}. Otherwise review manually using
   `gh pr view {{NUM}}` (+ `--json title,body`), `gh pr diff {{NUM}}`, and reading
   the surrounding source files in this repo for context.
2. Do NOT post anything to GitHub — no comments, no review, no approval. This is
   for Gabor's eyes only; your entire output is your stdout.
3. Do NOT check out the PR or change the working tree / branch of this clone.

# Output exactly three sections, terse and specific
## What it does
2–3 sentences: the change and its intent. If the title/body references a ticket
(HSP-XXXX etc.), include the ticket title alongside the key, never the bare key.

## Context
What Gabor should know before approving: linked tickets (with titles), blast
radius / which services or guests this touches, migration or rollout concerns,
anything surprising. Skip if genuinely nothing.

## Findings
A list, each prefixed [blocker] / [concern] / [nit], most severe first. Cite
file:line. Be concrete — a real bug, a missing test, an edge case, a security
or data-handling issue. If the PR is clean, say "No blocking issues" and list
only nits (or none). No padding, no restating the diff.
```

## Context

This is Gabor's highest-frequency activity — reviewing PRs across HSP
repos — plus the toil around dependabot churn. It fires at 06:30 on
weekdays, before standup and alongside [[slack-digest]] (06:00).

No AWS SSO needed (unlike [[one-on-one-prep]]) — this task only needs
`gh` (persistent token) and the local repo clones. It does not wait in a
poll loop.

### What counts as "by name" vs "group"

GitHub `review-requested:gabor-kasa` returns PRs where he's requested
directly **and** PRs where the `hospitality` team is the reviewer (he's
a team member). The task keeps only the ones where `gabor-kasa` is in
`requested_reviewers` individually ("by name" / code owner). The rest
are listed-and-excluded — Gabor only wants to act on by-name requests.

### Dependabot rules

- Never run `/review` on a dependabot PR.
- Safe-to-merge is **listed, never auto-merged**.
- Auto-push (never auto-merge) of a failing dependabot PR goes only to its
  own `head` branch — never `master`/`main`/`dev`, never a human branch:
  - **Metadata-only fix** (lockfile / dep-manifest / `client/CHANGELOG.md`)
    → push when the failing check goes green locally.
  - **Source-touching fix** (any other file, **including major bumps**) →
    push only when the **entire** build+lint+test suite passes locally,
    and only with a `[Claude]` comment carrying the diff + a "review-the
    -semantics" banner. The fixer reads the bump's migration notes and
    preserves runtime behavior — it does not just silence the compiler.
- All build/repro work happens in a throwaway `/tmp` worktree so Gabor's
  working clone (which may hold WIP) is never disturbed.
- **Dirty / behind branches are resolved locally when a clone exists**
  (Step 6-resolve): rebase onto master in the worktree, reconcile the
  mechanical conflicts (lockfile regen + `package.json` version union +
  changelog), verify the full suite, and `--force-with-lease` push. This
  is preferred over `@dependabot rebase` because of the refusal loop below.
- **Why rebase gets refused:** dependabot won't rebase a branch whose top
  commit isn't its own. In this org the usual culprit is the
  `dependabot-changelog-helper` action, which adds a `github-actions[bot]`
  "Updated Changelog" commit on top of the bump — and `recreate` just
  re-triggers that action, so the bot can never durably land the PR.
  Resolving locally sidesteps it entirely.
- The `@dependabot rebase`/`recreate` ladder is now only the **no-clone**
  fallback. When issued, a command is **pending**, not "handled": verify it
  landed on the next run (Step 6a-verify). A *successful* command pushes a
  new head commit; an unchanged sha means it's still queued or refused.

### PRE-AUTHORIZED actions

- **Read-only `gh`:** `gh api -X GET /search/issues`,
  `gh api /repos/.../pulls/...`, `gh pr view`, `gh pr diff`,
  `gh pr checks`.
- **For failing dependabot PRs requested by name only:** `git fetch`,
  `git worktree add`/`remove`, `git rebase origin/master` (to resolve a
  dirty/behind branch in the worktree — Step 6-resolve), package-manager
  `install`, build/lint/test, `git commit`, and `git push` to the
  dependabot head branch — including `git push --force-with-lease
  origin HEAD:<dependabot head branch>` after a local rebase rewrites
  history. The fix may edit **any** file needed to make CI green
  (source/config/tests included). Push gate by category: a
  **metadata-only** fix (lockfile / `package.json` dep stanza /
  `client/CHANGELOG.md`, preserving the template block) — and a local
  conflict resolution, which is metadata by nature — is pushed when the
  relevant checks/suite pass locally; a **source-touching** fix (incl.
  major bumps) is pushed only when the full build+lint+test suite passes
  locally, always with the 6e diff + review-semantics comment. Never a
  merge.
- **PR comments** via `gh pr comment` on dependabot-by-name PRs only:
  diagnosis/confirmation comments always prefixed with the `🤖 **[Claude]**`
  marker (Step 6e) so they're never mistaken for Gabor's own comments;
  plus the bare `@dependabot rebase` / `@dependabot recreate` bot command
  (Step 6a) which is posted **without** the marker so dependabot can parse
  it.
- **Spawning `claude -p`** in `../<repo>` for the human-PR `/review` is
  the core mechanic (same pattern as [[one-on-one-prep]]).

### Explicitly NOT authorized

- **Merging any PR** — push-to-fix is fine, the merge is always Gabor's.
- Dismissing / editing the `hospitality` team review request, or removing
  any reviewer (the "removal" idea was dropped in favour of excluding).
- Pushing to any non-dependabot branch, or to `master`/`main`/`dev`.
- Posting review output of human-authored PRs to GitHub — that stays in
  the local log for Gabor only.
- Pushing a **source-touching** fix without the full build+lint+test suite
  green locally, or without the 6e diff + review-semantics comment. A
  green typecheck alone is never enough — run the whole suite.
- Removing or rewriting the `client/CHANGELOG.md` template block, ever.
- Touching a **human-authored** PR's branch (source fixes are for
  dependabot-by-name branches only).
