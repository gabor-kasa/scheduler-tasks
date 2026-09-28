---
id: my-prs-watch
icon: bell.badge
title: My PRs — notify when a reviewer acts or a review waits on me
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

Watch two things and raise a desktop banner when either moves:

1. **Outbound.** Gabor's **own** open pull requests, when somebody else acts
   on one (Steps 2 to 4).
2. **Inbound.** Other people's PRs where Gabor is a reviewer, when the next
   move is his: a new review request, feedback he left that the author has
   now addressed, or a question put to him in a comment (Step 4b).

`pr-review-queue.md` also covers the inbound direction, but only as a
once-a-day 06:30 digest with auto-reviews. This task is the daytime banner:
it runs every 30 minutes through the working day and says "somebody is
waiting on you" within half an hour of it becoming true.

GitHub login is `gabor-kasa`, work org `kasadev`, local timezone
Europe/Budapest. **Read-only run.** Never post a comment, submit a review,
merge, close, assign, or push. Nothing in this task mutates GitHub.

The whole value of this task is that a banner means something happened
**that somebody else did**. Six outbound signals (Step 4) and three inbound
signals (Step 4b) fire a banner and nothing else does, and every one of
them is subject to the self rule in Step 3: an action Gabor took himself is
never a banner, however it reaches the API.
Everything else goes in the log for him to read when he wants to.

### Step 0 — Working-hours guard

The cron schedule fires 09:00-16:30 Mon-Fri, but that is **not** the only
way this task runs. The app catches up after the Mac sleeps: on 2026-09-09
the machine slept around 15:32, the 16:00 and 16:30 slots never fired, and
the overdue run fired at **19:20** instead. A `Run now` from the UI can
fire at any hour too. Gabor asked for 9 to 5 and meant it, so check the
wall clock before doing anything else:

```bash
TZ=Europe/Budapest date +"%u %H%M"    # day-of-week 1-7, then 24h Budapest time
```

Always pass `TZ=Europe/Budapest`. Never use a bare `date`, and do not
"correct" the result against the system timezone. The Mac follows its
location, so a bare `date` returns whatever zone it is sitting in. From
2026-09-20 to 2026-09-28 it was on America/New_York. The guard read 14:00
on a run that fired at 20:00 Budapest time and let it through, so the
watch ran on New York hours all week. The window is Budapest working
hours wherever the machine is.

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
  },
  "reviewingCheckedAt": "2026-09-23T15:00:00+02:00",
  "reviewing": {
    "kasadev/device-service#189": {
      "sha": "8c5d2853",
      "author": "norbertp-kasa",
      "requested": false,
      "myReviewCount": 3,
      "myLastReviewAt": "2026-09-23T19:05:34Z",
      "lastAsk": "2026-09-21T10:56:31Z",
      "notified": ["review_requested", "re_review@2026-09-14T16:08:54Z"],
      "at": "2026-09-23T15:00:00+02:00"
    }
  }
}
```

`prs` is the outbound side (Steps 2 to 4), `reviewing` the inbound side
(Step 4b). `reviewingCheckedAt` is the time of the last in-window run that
refreshed `reviewing`.

If the file is missing or unparseable, treat it as `{"prs":{}}` and run in
**seed mode**: record current state for every PR, write the log, and fire
**no** notification. A first run must not banner four days of accumulated
history at him.

**Seed each side on its own.** If the file parses but has no `reviewing`
key, which is exactly what the first run after the inbound side was added
on 2026-09-23 will see, seed `reviewing` silently while `prs` runs
normally. Otherwise that run would banner every open review request in the
org as if it had just arrived.

Seeding `reviewing` means more than copying fields. The inbound signals are
conditions, not diffs, so a seed run must also **pre-mark every condition
that is already true**: add `review_requested` and the current
`re_review@<myLastReview.at>` to `notified` wherever they hold, and set
`lastAsk` to the newest ask. Skip that and the second run banners them all.
On 2026-09-23 that would have been css-api#222, kontrol-ui#3094 and more.

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

### Step 4b — Reviews waiting on you (inbound)

**Build the list.** Union three searches, then union the keys already in
`reviewing` (same index-lag reason as Step 2):

```bash
for q in --review-requested=@me --reviewed-by=@me --mentions=@me; do
  gh search prs $q --state=open --json repository,number,author --limit 50
done
```

Drop these before fetching detail:

- **His own PRs** (`author == gabor-kasa`). Those are the outbound side.
- **Bot-authored PRs** (login matching `\[bot\]`, or `app/`). Dependabot PRs
  are `pr-review-queue.md`'s job at 06:30; nobody is waiting on him there.
- **Reviewer opt-out repos.** Use the list under "Reviewer opt-out repos" in
  `tasks/pr-review-queue.md` and read it from there each run, so there is one
  list. Do **not** remove him as a reviewer here. That mutation belongs to
  `pr-review-queue.md` and this run is read-only.

Then per PR, run this. Verified on 2026-09-23 against device-service#189,
css-api#222, code-setting-service#967, kontrol-ui#3094, salto-sync#120 and
css-api#183. Save it to a temp script and call it with `bash`, not inline:
the shell here is zsh, which does not word-split an unquoted `$var`, so a
`for p in "repo num"` loop hands `gh` one glued argument and fails with
`accepts 1 arg(s), received 2`.

```bash
#!/bin/bash
# usage: bash inbound.sh <owner>/<repo> <num>
R=$1; N=$2
BOT='\[bot\]|github-actions|jira-dashboard-kasadev|devin-ai-integration|cursor'
PR=$(gh pr view $N --repo $R --json author,isDraft,state,headRefOid,reviewRequests,reviews,comments)
IC=$(gh api --paginate repos/$R/pulls/$N/comments \
  --jq '[.[]|{id,a:.user.login,re:.in_reply_to_id,at:.created_at,body}]' | jq -s 'add // []')
jq -nc --argjson pr "$PR" --argjson ic "$IC" --arg bot "$BOT" '
  ($pr.reviews|map(select(.author.login=="gabor-kasa"))) as $mine
  | ($ic|map(select(.a=="gabor-kasa")|.id)) as $myIds
  | ([$mine[].submittedAt] + [$ic[]|select(.a=="gabor-kasa")|.at]
     + [$pr.comments[]|select(.author.login=="gabor-kasa")|.createdAt] | max) as $myLast
  | {
    author: $pr.author.login, draft: $pr.isDraft, state: $pr.state, sha: $pr.headRefOid[0:8],
    requested: ([$pr.reviewRequests[]|.login]|index("gabor-kasa") != null),
    myReviewCount: ($mine|length),
    myLastReview: ($mine|last|if . then {state, at:.submittedAt, sha:.commit.oid[0:8]} else null end),
    myLastActivity: $myLast,
    asks: (
      [ $pr.comments[] | select(.author.login|test($bot)|not) | select(.author.login!="gabor-kasa")
        | select(.body|test("@gabor-kasa\\b")) | {kind:"mention", who:.author.login, at:.createdAt} ]
    + [ $pr.reviews[] | select(.author.login|test($bot)|not) | select(.author.login!="gabor-kasa")
        | select(.body|test("@gabor-kasa\\b")) | {kind:"mention", who:.author.login, at:.submittedAt} ]
    + [ $ic[] | select(.a|test($bot)|not) | select(.a!="gabor-kasa")
        | select((.body|test("@gabor-kasa\\b")) or ((.re // -1) as $r | $myIds|index($r) != null))
        | {kind:(if (.body|test("@gabor-kasa\\b")) then "mention" else "reply" end), who:.a, at} ]
    | sort_by(.at) )
  }'
```

What the fields mean, and the traps behind them:

- `requested` is **by name only**. `review-requested:@me` also returns PRs
  where only a team he belongs to is requested; a team entry in
  `reviewRequests` has no `login`, so it never sets this. Team-only requests
  are not his to act on (the same rule `pr-review-queue.md` applies).
- GitHub **removes** a reviewer from `reviewRequests` when he submits a
  review. So `requested == true` with `myReviewCount > 0` means the author
  put him back: an explicit re-request. device-service#189 showed exactly
  that on 2026-09-22 after his COMMENTED review.
- `asks` are comments from a person, not a bot, that either mention
  `@gabor-kasa` or reply inside an inline thread he started. The bot filter
  is load-bearing: `jira-dashboard-kasadev` mentions `@gabor-kasa` on nearly
  every PR (four times on device-service#189 alone), and without the filter
  every Jira sync would read as a question.
- `myLastActivity` is his newest review, inline comment or PR comment. An
  ask older than that is one he has already answered.

**Drafts are excluded**, same as outbound. A PR that turns out `MERGED` or
`CLOSED` is pruned from `reviewing` quietly: somebody else's PR closing is
not news to him. Only prune on a confirmed state, same rule as Step 5.

The Step 2 failure rule covers these calls too: an auth or rate-limit error
on a search means the watch is blind, so report `failure`. If only one PR's
detail fetch fails, keep its entry unchanged, note it in the log and carry
on.

**Signals.** Three, each subject to the self rule:

| Signal | Condition | Fires at most |
|---|---|---|
| `review_requested` | `requested` and `myReviewCount == 0` | once per PR |
| `re_review` | `myReviewCount > 0`, the last review is not `APPROVED`-and-unrequested, and either `requested` (re-requested) or the head `sha` differs from `myLastReview.sha` (new commits since his feedback) | once per review round, keyed `re_review@<myLastReview.at>` |
| `question` | an entry in `asks` newer than both `myLastActivity` and the entry's `lastAsk` (for a PR new to state, `reviewingCheckedAt`) | once per new ask |

Spelled out, `re_review` fires when:

- his last review was `CHANGES_REQUESTED` or `COMMENTED` and the author
  pushed since, or
- he was re-requested after any review, including an approval.

An `APPROVED` review followed by more commits and no re-request is not
waiting on him. That is the author finishing up.

Why the keys differ from outbound's once-per-sha:

- `review_requested` is once per PR because the **initial** request is the
  news. Later pushes are not a second request.
- `re_review` is keyed to his review, not the sha. Otherwise every push the
  author makes after his feedback would banner again. One banner per round
  of his feedback. When he reviews again, `myLastReview.at` changes and the
  next round can fire.
- `question` advances `lastAsk` to the newest ask it reported, so each
  question banners once.

Unlike outbound, a PR seen for the first time **does** fire
`review_requested` (after seed mode). A brand-new request is exactly the
event. `question` on a first-seen PR only counts asks newer than
`reviewingCheckedAt`, so a mention search that surfaces an old thread does
not banner history.

Never fire inbound on: a team-only request, a bot comment, his own comment
or review, a draft, or a PR he authored.

Persist `reviewing` and set `reviewingCheckedAt` to now in the same state
write as Step 5.

### Step 5 — Write the log + persist state

**Output contract.** The run's stdout IS the log. Emit the report below
exactly once as your final output, then end the run. Do not redraft or
re-print it. A repeated report makes the app fire the banner several times.
The `## Notification` block, or `## Outcome` when there is no notification,
is the **last thing in the output**. Nothing follows it. Put any execution
commentary *before* the `# My open PRs` heading.

Every PR from Step 2 and Step 4b appears exactly once across the sections. "No change"
is a reason to write a one-line entry, never to omit one. Keep empty
headings with `_None._` so the shape is stable run to run.

```
# My open PRs — <TODAY local> <HH:MM>

<headline, counts derived from the sections below, e.g.
 "7 open · 1 approved · 1 new comment · 1 Devin review · 4 quiet · 1 draft
  · reviewing: 1 new request · 1 question · 5 waiting on you">

## 🔔 New since last run
### <repo>#<num> — <title>
- <signal>: <who did what, and when>
- <url>

## 😴 Quiet — no change since last run
- <repo>#<num> — <title> · waiting <N>d on <reviewers> · <decision>

## 👀 Waiting on your review — new since last run
### <repo>#<num> — <title> (by <author>)
- <review_requested | re_review | question>: <who, what, when; for a
  question, quote its first ~100 chars>
- <url>

## 👀 Waiting on your review — standing
- <repo>#<num> — <title> (by <author>) · <why it waits on you: requested
  <N>d ago / pushed since your changes-requested / unanswered question from
  <who>> · already bannered

## 💤 Reviewing — nothing waiting on you
- <repo>#<num> — <title> · <e.g. you approved, no new request>

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
- `attention` — at least one signal fired this run, outbound or inbound.
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
- subtitle: <e.g. "kontrol-ui#3044 approved" or "css-api#222 review requested">
- body: <the single most important item, ~90 chars. Priority order:
        changes_requested, question, re_review, closed, approved,
        review_requested, ci_red, new_comment, devin_review last. Name the
        repo, number, and who acted. If more fired, end with "+N more".>
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

The inbound side was added on 2026-09-23. `pr-review-queue.md` already
covered the inbound direction, but only at 06:30. A review request that
lands at 10:00, or an author who answers his feedback at 11:00, sat unseen
until the next morning. The three inbound signals map onto what he asked
for: the initial request (`review_requested`), feedback he left that was
then addressed (`re_review`), and a question put to him (`question`).

Related: `tasks/pr-review-queue.md` for the daily inbound digest, and the
`shared-kasa-review-queue` skill for the same thing on demand.
