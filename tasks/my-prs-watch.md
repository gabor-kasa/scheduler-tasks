---
id: my-prs-watch
icon: bell.badge
title: My open PRs — notify when a reviewer acts
type: recurring
model: claude-sonnet-5
effort: low
quiet: true
schedule: "0,30 9-16 * * 1-5"
next_run: 2026-09-09T14:00:00+02:00
created: 2026-09-09T13:50:00+02:00
status: active
---

## Instructions

Watch Gabor's **own** open pull requests and raise a desktop banner when
somebody else acts on one. This is the outbound counterpart to
`pr-review-queue.md`, which covers the inbound direction (PRs waiting on
Gabor's review). That task runs once at 06:30; this one runs every 30
minutes through the working day.

GitHub login is `gabor-kasa`, work org `kasadev`, local timezone
Europe/Budapest. **Read-only run.** Never post a comment, submit a review,
merge, close, assign, or push. Nothing in this task mutates GitHub.

The whole value of this task is that a banner means something happened
**that somebody else did**. Six signals fire a banner and nothing else
does, and every one of them is subject to the self rule in Step 3: an
action Gabor took himself is never a banner, however it reaches the API.
Everything else goes in the log for him to read when he wants to.

### Step 0 — Working-hours guard

The cron schedule fires 09:00-16:30 Mon-Fri, but that is **not** the only
way this task runs. The app catches up after the Mac sleeps: on 2026-09-09
the machine slept around 15:32, the 16:00 and 16:30 slots never fired, and
the overdue run fired at **19:20** instead. A `Run now` from the UI can
fire at any hour too. Gabor asked for 9 to 5 and meant it, so check the
wall clock before doing anything else:

```bash
date +"%u %H%M"    # day-of-week 1-7, then 24h local time
```

If the day is 6 or 7, or the time is outside `0900`-`1659`, **stop there**:

- Fire no notification.
- **Do not write `logs/my-prs-state.json`.** This part matters. Quietly
  refreshing the baseline out of hours would absorb a reviewer's comment
  into state as though it had already been reported, and the banner for it
  would never fire. Leaving state untouched means the next in-window run
  diffs against the last in-window baseline and reports everything that
  piled up while the machine was asleep.
- Write a one-line log saying the run was skipped as out-of-hours, with
  `Severity: ok`, and end the run.

### Step 1 — Load state

Read `logs/my-prs-state.json`. Shape:

```json
{
  "prs": {
    "kasadev/kontrol-ui#3044": {
      "sha": "63ea1283",
      "decision": "APPROVED",
      "humanReviews": 1,
      "humanComments": 0,
      "devinReviews": 1,
      "ciFail": 0,
      "notified": ["approved", "devin_review"],
      "at": "2026-09-09T14:00:00+02:00"
    }
  }
}
```

If the file is missing or unparseable, treat it as `{"prs":{}}` and run in
**seed mode**: record current state for every PR, write the log, and fire
**no** notification. A first run must not banner four days of accumulated
history at him.

### Step 2 — Build the PR list

```bash
gh search prs --author=@me --state=open --json repository,number --limit 50
```

Leave it unscoped by org so the personal `gabor-kasa/jira` repo is included
alongside `kasadev`.

**The set to check is the search result UNION the keys already in state, not
the search result alone.** `gh search prs` reads GitHub's search index, which
is eventually consistent and *does* drop open PRs: on 2026-09-09 it returned
7 PRs at 14:30 and only 4 at 15:00 while all 7 were still open. Treating that
as "the missing 3 closed" silently dropped three PRs out of the watch. Union
the two sources and index lag can never shrink the watch.

Then, per PR, pull the detail (this exact command is verified to work):

```bash
gh pr view <num> --repo <owner>/<repo> --json \
  number,title,url,isDraft,state,reviewDecision,headRefOid,updatedAt,reviews,comments,statusCheckRollup,mergedBy
```

`state` and `mergedBy` are not optional extras. Step 4 needs `mergedBy` to
tell somebody else's merge from Gabor's own click, and without it every
self-merge fires a banner.

If `gh` fails on auth or rate limit, stop, write the error into the log,
set severity `failure`, and fire a banner saying the watch is blind. A
silently broken watch is worse than no watch.

### Step 3 — Classify each PR

**Drafts are excluded entirely.** A draft is waiting on Gabor, not on a
reviewer. List it in the report under Drafts and compute no signals for it.

Activity falls into three buckets, counted separately.

**Self, excluded from every signal, not just the counts.** `gabor-kasa`.
On css-api#214 five of the seven reviews were his own; counting them makes
the numbers lie. Verified live on 2026-09-21: smartthings-sync#223 carries
15 `gabor-kasa` reviews and 1 `gabor-kasa` comment, and the filter below
correctly counts 9 human reviews and 2 human comments, all norbertp-kasa's.
Do not "fix" that by folding his own activity back in.

The count filter is only half the rule. Comments and reviews are filtered
here; **merges are filtered in Step 4**, because a merge arrives as a state
change with no author attached to it. The rule that governs both: *if Gabor
did it, he already knows, so it never becomes a banner.* Apply that to any
signal added later, not only to the six listed today.

**Noise bots, excluded.** `github-actions` and `jira-dashboard-kasadev`
post CI status and Jira links. Neither is a review. Also exclude any login
matching `[bot]`, which covers `dependabot[bot]`.

**Reviewers, counted.** Everyone else, split into two counts:

- `humanReviews` / `humanComments` — real people.
- `devinReviews` — `devin-ai-integration`, the review bot wired up by
  `devin-pr-review.yml`. It is a genuine reviewer, so it gets its own
  count and its own signal.

The extraction, verified against kontrol-ui#3044:

Pipe to real `jq`, not `gh --jq`. **`gh pr view --jq` does not accept
`--arg`**, so a snippet that references `$skip` there fails with
`unknown flag: --arg`:

```bash
SKIP='gabor-kasa|github-actions|jira-dashboard-kasadev|\[bot\]'
DEVIN='devin-ai-integration'
gh pr view <num> --repo <owner>/<repo> --json \
  number,isDraft,state,reviewDecision,headRefOid,reviews,comments,statusCheckRollup,mergedBy \
| jq -c --arg skip "$SKIP" --arg devin "$DEVIN" '{
    state: .state, draft: .isDraft, sha: .headRefOid[0:8],
    decision: (.reviewDecision // "NONE"),
    mergedBy: (.mergedBy.login // null),
    humanReviews:  [.reviews[] |select(.author.login|test($skip)|not)
                               |select(.author.login != $devin)]|length,
    humanComments: [.comments[]|select(.author.login|test($skip)|not)
                               |select(.author.login != $devin)]|length,
    devinReviews:  [.reviews[] |select(.author.login == $devin)]|length,
    ciFail: [.statusCheckRollup[]?|select(.conclusion=="FAILURE")]|length }'
```

Verified against kontrol-ui#3044: one human review, tamas-kasa's approval,
out of three raw review entries.

Devin's review **does** fire a banner, on its own `devin_review` signal,
and the report labels it as the bot rather than folding it in with people.
It reviews well after a PR opens (09-07 and 09-08 on PRs created 09-04),
and the once-per-sha rule in Step 4 caps it at one banner per push, so it
cannot turn into a drip. Rank it below human activity in the banner body:
a person waiting on you outranks a bot that already left its notes.

### Step 4 — Diff against state, pick signals

For each non-draft PR, compare to its stored entry. Six signals can fire a
banner, and `closed` carries the self-merge condition:

| Signal | Condition |
|---|---|
| `approved` | `decision` became `APPROVED` |
| `changes_requested` | `decision` became `CHANGES_REQUESTED` |
| `new_comment` | `humanReviews` or `humanComments` went **up** |
| `devin_review` | `devinReviews` went **up** |
| `ci_red` | `ciFail` went from `0` to `>0` |
| `closed` | `state` became `MERGED` or `CLOSED` **and `mergedBy` is not `gabor-kasa`** |

**A self-merge is not news.** When `mergedBy` is `gabor-kasa`, Gabor clicked
the button himself seconds earlier and a banner telling him so is pure echo.
Measured on 2026-09-21: of the last five merge banners, three were his own
clicks (github-workflows#100 on 09-16, css-debugger#97 on 09-18,
add-on-service#732 on 09-21) and only two were somebody else's
(ai-developer-tools#616 and #595, both merged by andrew-kasa). Suppress the
signal, still prune the entry per Step 5, and log the closure under
**Your own actions** in the report so the suppression is visible rather than
silent.

A PR **closed without merging** is the same case, but `mergedBy` is null and
`gh pr view` has no `closedBy` field. Checked on 2026-09-21, it errors with
`Unknown JSON field: "closedBy"`. The actor lives in the events API instead,
verified against css-debugger#97:

```bash
gh api repos/<owner>/<repo>/issues/<num>/events \
  --jq '[.[]|select(.event=="closed" or .event=="merged")|{event,actor:.actor.login}]'
# -> [{"actor":"gabor-kasa","event":"merged"},{"actor":"gabor-kasa","event":"closed"}]
```

Only make that extra call for a PR that went `CLOSED` unmerged, which is
rare. If the call fails, suppress the banner anyway: an unmerged close of
his own PR is nearly always his own doing, and a missed banner there is
cheaper than an echo.

Somebody else merging his PR **does** still fire, and keeps its place in the
Step 6 priority order. That is genuine news: the work shipped without him
touching it.

`approved` and `changes_requested` need no author check. GitHub refuses a
review on your own PR, so `reviewDecision` cannot be moved by `gabor-kasa`
and there is nothing to filter. Do not add machinery for it.

**A signal fires once per sha.** Store every fired signal in the PR's
`notified` array and never re-fire one already listed there. A PR that has
been sitting approved for two days must stay silent on all 34 runs after
the first, exactly as `pr-review-queue.md` keeps its "still open from
earlier runs" section silent. Re-bannering a known state is how a
notification becomes noise.

**A new sha resets `notified` to `[]`.** Gabor pushed, so the review cycle
starts over and a fresh approval or comment is genuinely new.

Never fire on: a count going *down* (a deleted comment), `decision` moving
to `REVIEW_REQUIRED` on its own (that is just a re-request after his push),
a draft, a PR that appeared for the first time this run, or **anything
`gabor-kasa` did himself**: his own merge, his own close, his own comment,
his own review.

### Step 5 — Write the log + persist state

**Output contract.** The run's stdout IS the log. Emit the report below
exactly once as your final output, then end the run. Do not redraft or
re-print it. A repeated report makes the app fire the banner several times.
The `## Notification` block, or `## Outcome` when there is no notification,
is the **last thing in the output**. Nothing follows it. Put any execution
commentary *before* the `# My open PRs` heading.

Every PR from Step 1 appears exactly once across the sections. "No change"
is a reason to write a one-line entry, never to omit one. Keep empty
headings with `_None._` so the shape is stable run to run.

```
# My open PRs — <TODAY local> <HH:MM>

<headline, counts derived from the sections below, e.g.
 "7 open · 1 approved · 1 new comment · 1 Devin review · 4 quiet · 1 draft">

## 🔔 New since last run
### <repo>#<num> — <title>
- <signal>: <who did what, and when>
- <url>

## 😴 Quiet — no change since last run
- <repo>#<num> — <title> · waiting <N>d on <reviewers> · <decision>

## 🙋 Your own actions (logged, never bannered)
- <repo>#<num> — <title> · merged by you at <time>

## ✏️ Drafts (excluded)
- <repo>#<num> — <title>

## Outcome
- **Status:** <success | failure>
- **Severity:** <ok | attention | failure>
- **Finished:** <ISO timestamp with local offset>
- **Summary:** <one line with the counts>
```

In the Quiet section, show how long each PR has been waiting and on whom
(`reviewRequests`, plus `assignees` if set). That standing list is the
thing worth glancing at, even though it never triggers a banner.

Then write the updated state to `logs/my-prs-state.json`.

**Only ever prune an entry whose closure you have positively confirmed.**
Absence from the `gh search prs` result is *not* evidence that a PR closed;
it is most often index lag. Before dropping any known PR, verify it directly:

```bash
gh pr view <num> --repo <owner>/<repo> --json state,mergedAt,mergedBy
```

Prune only on `MERGED` or `CLOSED`. Fire the `closed` signal on that same
transition so the merge is reported rather than silently vanishing.
**Unless `mergedBy` is `gabor-kasa`**, in which case prune quietly and write
the closure into the **Your own actions** section instead. Pruning happens
either way; only the banner is suppressed. If the
verify call itself fails, **keep the entry** and note it in the log. A stale
entry costs one line in a JSON file; a wrongly pruned one costs the watch,
because Step 4 never fires on a PR seen for the first time, so a re-seeded PR
swallows whatever happened while it was missing.

### Step 6 — Severity + Notification

- `failure` — `gh` failed and the watch could not run. Error text in the log.
- `attention` — at least one signal fired this run.
- `ok` — nothing fired. Silence is the success state.

A run whose only event was one of Gabor's own actions is `ok`, not
`attention`. Because `quiet: true` deletes `ok` logs, that run's **Your own
actions** section disappears with it. That is intended: he merged it, he
knows. The section earns its place on runs that also carry a real signal,
where it shows what was deliberately left out of the banner.

On `attention` or `failure`, append exactly one block:

```
## Notification

- title: PR activity
- subtitle: <e.g. "kontrol-ui#3044 approved">
- body: <the single most important item, ~90 chars. Priority order:
        changes_requested, then closed, then approved, then ci_red, then
        new_comment, then devin_review last. Name the repo, number, and
        who acted.>
- sound: default
```

Skip the block entirely on `ok`. Most runs will be `ok` and produce no
banner. That is the design working, not a failure.

Those `ok` runs also leave no trace at all. The frontmatter sets
`quiet: true`, so the app deletes the run log the moment the run ends.
Nothing appears in the Runs list and nothing ticks the unread badge. Runs
that fired a banner are kept, and so is any run that failed. If you want
to confirm the watch is alive, the Tasks tab shows its last run.

## Context

Gabor has seven open PRs and every one is waiting on somebody else. He does
not want to poll them, and GitHub's own notification inbox is unusable for
this: it currently holds 20-plus `review_requested` entries from repos
across the org and **zero** `author` entries, so activity on his own PRs is
buried under review requests for other people's work.

The gap this fills is real. kontrol-ui#3044 was approved by tamas-kasa on
2026-09-07 and sat mergeable for two days without him noticing.

Cadence is 9:00 to 16:30 local, Mondays to Fridays, 16 runs a day. Nothing
fires outside working hours by design. The tradeoff: a reviewer who acts at
16:45 surfaces at 09:00 the next morning.

This is still polling, just done by the Mac instead of by Gabor. Genuine
push would need a `pull_request_review` webhook, which belongs in
`kasadev/github-workflows` as a reusable workflow (it already has
`src/utils/slack-utils.ts` and `send-deploy-notification.ts` for the Slack
side). That is the org-wide fix and helps every author on the team, not
just this machine.

Related: `tasks/pr-review-queue.md` for the inbound direction, and the
`shared-kasa-review-queue` skill for the same thing on demand.
