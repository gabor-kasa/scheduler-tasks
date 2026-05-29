---
id: pr-review-queue
icon: arrow.triangle.pull
title: Morning PR review queue — triage, dependabot, /review
type: recurring
schedule: "30 6 * * 1-5"
next_run: 2026-06-01T06:30:00+02:00
last_run: 2026-05-29T09:31:03+02:00
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
3. For **dependabot** PRs by name: classify safe-to-merge, auto-push
   *mechanical* fixes when CI is red, or comment a diagnosis.

Everything routes into one log Gabor reads with his coffee.

### Step 0 — Load review state

Read `logs/pr-review-state.json` (JSON; create `{ "reviewed": {},
"dependabot": {} }` if missing or unparseable). Shape:

```json
{
  "reviewed":   { "kasadev/<repo>#<num>": { "sha": "<head sha>", "at": "<iso>" } },
  "dependabot": { "kasadev/<repo>#<num>": { "sha": "<head sha>", "action": "commented|pushed|safe", "at": "<iso>" } }
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
branch trails its base. Both are best fixed by asking dependabot to
rebase (Step 6a), not by a local lockfile push.

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

**5c. Failing →** attempt a mechanical fix, else comment. See Step 6.
Skip entirely if `dependabot["kasadev/<repo>#<num>"].sha == head` AND its
prior `action` was `commented`, `pushed`, or `rebase` — already handled
at this exact SHA; just note "already handled (no new commits)".

### Step 6 — Failing dependabot: rebase, mechanical fix, or comment

Only ever do this for **dependabot** PRs requested **by name**. Never
touch a human-authored PR's branch. Pick the **first** path that applies:

- **6a — Stale / conflicted branch →** ask dependabot to rebase (a bare
  bot command comment). Cheapest; no checkout.
- **6b/6c — Mechanical CI failure →** regenerate the lockfile in an
  isolated worktree and push to the PR branch.
- **6d — Anything else →** post a `[Claude]` diagnosis comment.

Define **mechanical** narrowly — exactly three allowed change classes,
any combination of which may be needed to turn CI green:

1. **Lockfile regeneration / dependency-manifest sync**
   (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, or the
   `package.json` dependency stanza).
2. **A missing changelog entry** in `client/CHANGELOG.md` (see 6c-ii).
   This is a very common dependabot failure — the
   `dangoslen/dependabot-changelog-helper` action only runs on PRs that
   touch `client/**`, so root-only bumps (typescript, eslint, release-it,
   …) skip it and the changelog gate then fails.

If turning CI green requires editing any **other** file — a source file
(`.ts`/`.tsx`/`.js`), config logic, tests — it is **NOT** mechanical →
comment instead (6d). The only files this task may write on a dependabot
branch are lockfiles, the `package.json` dependency stanza, and
`client/CHANGELOG.md`.

**6a. Stale or conflicted branch → ask dependabot to rebase:**

If `mergeable_state` is `dirty` (conflicts) or `behind` (trails base), or
the failing checks are clearly a stale-branch artifact, comment the bare
bot command and stop here for this PR:

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
already shows `action:"rebase"` at this sha, just note "rebase already
requested".

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

**6c. Reproduce + attempt the mechanical fix in the worktree:**

Working in `/tmp/pr-fix-<repo>-<num>`:

**6c-i. Lockfile / build:** Detect the package manager by lockfile and
run a fresh install (`npm install` / `yarn install` / `pnpm install`) —
this regenerates the lockfile if it was out of sync. Then run the repo's
build + lint/typecheck the way CI does — infer from the failing check
names in Step 5 (e.g. `lint-app`, `tests`, `Client Build`) and the
repo's `package.json` scripts. Common: `npm run build`, `npm run lint`,
`npm test`.

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

After 6c-i / 6c-ii, re-run the failing checks' local equivalents to
confirm green, then decide:
   - **Mechanical & green:** `git diff --name-only` shows ONLY allowed
     files (lockfiles, `package.json` dep stanza, `client/CHANGELOG.md`)
     AND the relevant checks now pass →
     commit and push to the PR's own branch:

     ```bash
     git -C /tmp/pr-fix-<repo>-<num> add -A
     # Use a message that names what was actually done, e.g.
     #   "chore: regenerate lockfile to fix CI"
     #   "chore: add changelog entry"
     #   "chore: regenerate lockfile + add changelog entry"
     git -C /tmp/pr-fix-<repo>-<num> commit -m "<accurate message>

     Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
     git -C /tmp/pr-fix-<repo>-<num> push origin HEAD:<headRef>
     ```

     Record `dependabot[...] = {sha, action:"pushed"}`. Then **also post
     a short `[Claude]` PR comment** (see Step 6e format) saying what was
     pushed and that CI is re-running. Add to "🔧 Fixed automatically".
   - **Not mechanical, or still red after install:** go to 6d.

**6d. Comment a diagnosis (no push):**

When a fix isn't mechanical (or there's no local clone), post one
`[Claude]` comment (6e) with: the failing check(s), the root-cause one
-liner, and a concrete suggested patch. Add to "💬 Commented — needs
you". Record `dependabot[...] = {sha, action:"commented"}`.

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
### 🔧 Fixed automatically (lockfile/dep sync pushed, CI re-running)
- <repo>#<num> <title> — pushed: <one line>. <url>
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
- body: <single most important item, ~90 chars. Prefer a human PR needing
        review; else a commented/failing dependabot; else "K PRs safe to merge">
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
- Auto-push is restricted to **mechanical** fixes (lockfile / dep-manifest
  regeneration) that go green locally, and only to the dependabot PR's
  own `head` branch — never to `master`/`main`/`dev`, never to a
  human-authored branch.
- All build/repro work happens in a throwaway `/tmp` worktree so Gabor's
  working clone (which may hold WIP) is never disturbed.

### PRE-AUTHORIZED actions

- **Read-only `gh`:** `gh api -X GET /search/issues`,
  `gh api /repos/.../pulls/...`, `gh pr view`, `gh pr diff`,
  `gh pr checks`.
- **For failing dependabot PRs requested by name only:** `git fetch`,
  `git worktree add`/`remove`, package-manager `install`, build/lint/test,
  `git commit`, and `git push origin HEAD:<dependabot head branch>` —
  restricted to the three mechanical change classes only: lockfile /
  `package.json` dep-manifest regeneration, and adding a missing
  `client/CHANGELOG.md` entry (preserving the template block). Pushed
  only when those changes make the failing checks pass locally.
- **PR comments** via `gh pr comment` on dependabot-by-name PRs only:
  diagnosis/confirmation comments always prefixed with the `🤖 **[Claude]**`
  marker (Step 6e) so they're never mistaken for Gabor's own comments;
  plus the bare `@dependabot rebase` / `@dependabot recreate` bot command
  (Step 6a) which is posted **without** the marker so dependabot can parse
  it.
- **Spawning `claude -p`** in `../<repo>` for the human-PR `/review` is
  the core mechanic (same pattern as [[one-on-one-prep]]).

### Explicitly NOT authorized

- Merging any PR.
- Dismissing / editing the `hospitality` team review request, or removing
  any reviewer (the "removal" idea was dropped in favour of excluding).
- Pushing to any non-dependabot branch, or to `master`/`main`/`dev`.
- Posting review output of human-authored PRs to GitHub — that stays in
  the local log for Gabor only.
- Editing any file on a dependabot branch other than the three allowed
  mechanical classes (lockfiles, `package.json` dep stanza,
  `client/CHANGELOG.md`). In particular, never touch `.ts`/`.js`/test/
  config-logic files, and never remove the `client/CHANGELOG.md` template
  block.
