---
id: slack-digest
icon: text.bubble
title: Weekday Slack digest — what I missed
type: recurring
schedule: "0 6 * * 1-5"
created: 2026-05-18T09:30:00+02:00
status: active
---

## Channels

Gabor's starred channels — the per-channel digest scope. Update this list
when starred channels change (the Slack MCP can't enumerate them, see
`## Context` below).

- #eng-cross-team-alignment — C06RGAAN1AN
- #eng-managers-sync — C01HRUJV23Y
- #eng-team — C03B4QEJGJH
- #hosp-internal — C05F0JLJ4BZ
- #hosp-lt — C05KQGCRNM8
- #hospitality-bugs — C0437ACUVD5
- #hospitality-public — C011RJKSX7H
- #hungary — GLE7Z6RC2
- #small-arch — C02K09DELHW
- #tech_prod_leads — C012SQ2H69X
- #tech-internal — GLFEVE0NN

## Instructions

You are producing Gabor's "what I missed while offline" digest. Slack
user_id is `US8T5ML6T`, workspace is `livekasa` (`T5D4SGV2P`).

### Step 1 — Compute the cutoff timestamp

Cutoff = end of the previous working day:

- If today (local) is **Monday** → cutoff = the previous **Friday at 18:00** local.
- If today is **Tue–Fri** → cutoff = **yesterday at 18:00** local.

Compute it as a Slack-format ts (`<unix_seconds>.000000`) using the BSD
`date` tool on macOS:

```bash
weekday=$(date +%u)                # 1=Mon … 7=Sun
if [ "$weekday" = "1" ]; then days_back=3; else days_back=1; fi
cutoff_date=$(date -v-${days_back}d +%Y-%m-%d)
cutoff_ts=$(date -j -f "%Y-%m-%d %H:%M:%S" "$cutoff_date 18:00:00" +%s).000000
cutoff_human="$cutoff_date 18:00 $(date +%Z)"

# Separate window for the #tech-releases "Shipped" section (Step 5):
# "since the last run", NOT the 18:00 cutoff above. Releases ship during
# business hours, so the 18:00 cutoff would miss most of the previous
# workday's deploys.
#
# Source of truth for the last run is the gitignored schedule-state
# sidecar. The app advances it *after* each run, so while this run is
# executing the sidecar still holds the PREVIOUS run's timestamp — exactly
# the "since the last run" anchor we want. If there's no recorded last run
# (first run ever, or the entry is missing/unreadable), fall back to the
# last 24 hours.
state_file="logs/schedule-state.json"
last_run=$(jq -r '."slack-digest".last_run // empty' "$state_file" 2>/dev/null)
releases_cutoff_ts=""
if [ -n "$last_run" ]; then
  # ISO 8601 w/ local offset, e.g. 2026-06-03T06:35:44+02:00. BSD %z wants
  # +0200 (no colon), so strip the colon from the trailing offset first.
  lr_norm=$(printf '%s' "$last_run" | sed -E 's/([+-][0-9]{2}):([0-9]{2})$/\1\2/')
  lr_secs=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$lr_norm" +%s 2>/dev/null)
  if [ -n "$lr_secs" ]; then
    releases_cutoff_ts="${lr_secs}.000000"
    releases_cutoff_human="$last_run (last run)"
  fi
fi
if [ -z "$releases_cutoff_ts" ]; then
  releases_cutoff_ts=$(date -v-24H +%s).000000
  releases_cutoff_human="$(date -v-24H '+%Y-%m-%d %H:%M %Z') (last 24h — no recorded last run)"
fi
```

You'll also need a date-only form for Slack search modifiers
(`after:YYYY-MM-DD` is the most precise the search API supports). Use
the day **before** `cutoff_date` so the search definitely covers the
cutoff hour, then filter results by ts ≥ cutoff_ts:

```bash
search_after_date=$(date -j -v-1d -f "%Y-%m-%d" "$cutoff_date" +%Y-%m-%d)
```

### Step 2 — Read each starred channel

For every channel ID under `## Channels`, call:

```
slack_read_channel(
  channel_id=<id>,
  oldest=<cutoff_ts>,
  limit=100,
  response_format="detailed"
)
```

**Exception**: for `C011RJKSX7H` (#hospitality-public), use a wider
7-day `oldest` instead of `cutoff_ts`. Cross-team chatter there often
spans several days and the longer window keeps the rolling view useful.
Compute the 7-day `oldest` like `cutoff_ts` but with `days_back=7` and
`00:00:00` time-of-day.

Skip channels with zero new messages (do not list them in the output).

For each remaining message capture: sender display name (resolve via
the user ID if the API returns only the ID), local timestamp,
permalink (see below), and the first ~200 chars of body.

**Permalink construction.** `response_format="detailed"` returns a line
like `Message TS: 1779038593.559769` for each message. Build the link
by dropping the decimal in that ts:

```
https://livekasa.slack.com/archives/<channel_id>/p<ts_without_dot>
```

So `Message TS: 1779038593.559769` in channel `C0437ACUVD5` becomes
`https://livekasa.slack.com/archives/C0437ACUVD5/p1779038593559769`.
For thread replies, append `?thread_ts=<parent_ts>&cid=<channel_id>`.
Never reconstruct a permalink from a human-readable time — it loses
microsecond precision and lands on the channel root.

**Drop:**
- Messages sent by Gabor himself (`US8T5ML6T`). His own outgoing isn't
  "missed".
- Bot-only posts with no actionable content.

**For #hospitality-bugs specifically**: if a `[Critical]` or `[Major]`
item has thread replies, call `slack_read_thread` once on that parent
and surface (a) whether Gabor was @-mentioned anywhere in the thread,
(b) any explicit severity escalation or scope note from the reporter
(e.g. "affects whole portfolio"). For lower-severity bugs just note
"Thread: N replies".

For other starred channels, fetch a thread only if the top-level message
both mentions Gabor and the channel reads has more than a one-line
"reply count" — i.e. there's substance you'd otherwise miss.

### Step 3 — Global @-mentions of Gabor

Find mentions in non-starred channels:

```
slack_search_public_and_private(
  query="<@US8T5ML6T> after:<search_after_date>",
  sort="timestamp",
  include_context=false,
  limit=20
)
```

Filter the results:

- Drop any whose channel ID is in the starred list (Step 2 has them).
- Drop any whose Slack ts is strictly older than `cutoff_ts`
  (`after:` is date-granular and will return earlier-same-day msgs).

### Step 4 — DMs and group DMs

Two searches:

```
slack_search_public_and_private(query="after:<search_after_date>", channel_types="im",   limit=20, sort="timestamp", include_context=false)
slack_search_public_and_private(query="after:<search_after_date>", channel_types="mpim", limit=20, sort="timestamp", include_context=false)
```

Drop:

- Messages whose ts < `cutoff_ts`.
- Messages sent by Gabor himself (`US8T5ML6T`) — those are his own
  outgoing, not things he missed.
- Pure bot noise with no actionable content (use judgment — Jira
  bot DMs usually qualify as noise unless the body is meaningful).

If either search returned a full page (20 results) and the oldest
returned ts is still ≥ cutoff_ts, paginate until results fall before
the cutoff.

For the "ball in their court" framing in the output: only tag it that
way when Gabor's last reply was substantive (a question, a request, or
new information). Short closure acks from the other side ("ok",
"thanks", "rendben", "oks", "👍") mean the thread is **closed**, not
"ball back in their court" — say so plainly.

### Step 5 — What shipped (#tech-releases — different, wider window)

Read deploy announcements from **#tech-releases** (`C03HRBXNEMD`). This is
a separate report from the per-channel digest above and uses a **different
window**: the "since the last run" window from Step 1 (`releases_cutoff_ts`
/ `releases_cutoff_human`), **not** the 18:00 `cutoff_ts`. #tech-releases
is not a starred channel — don't add it to `## Channels`.

```
slack_read_channel(
  channel_id="C03HRBXNEMD",
  oldest=<releases_cutoff_ts>,
  limit=100,
  response_format="detailed"
)
```

If a full page (100 messages) comes back and the oldest returned message
is still ≥ `releases_cutoff_ts`, paginate with the returned cursor until
messages fall before the cutoff (a Monday / post-weekend window can span
several days and exceed one page).

Posts come from the `incoming-webhook` bot in a fixed shape:

```
*[service name]* `vX.Y.Z` · deployed by <who>
- <jira-link|RC-1234> <summary> (<author>)
- *<summary>* (<author>)              # no ticket
- Maintenance: <…>                    # housekeeping
- Maintenance: bumped <…> (dependabot[bot] / npm-autorelease-pr-creator[bot])
<release-url|View release> | <actions-run-url|run-id>
```

For each release capture: service, version, deployer, and the meaningful
change bullets (the ticketed and bold ones). **Condense the noise** —
collapse `Maintenance:` lines and `dependabot[bot]` /
`npm-autorelease-pr-creator[bot]` dependency bumps into a single trailing
`+ maintenance/deps` note rather than listing each bump. If a release is
*entirely* maintenance/deps, render it as a single line.

Build the Slack permalink with the same rule as Step 2 (drop the dot in
`Message TS`): `https://livekasa.slack.com/archives/C03HRBXNEMD/p<ts>`.
The `View release` link in the post is the GitHub release; keep it too
when it adds value.

This section is **informational only** — it never raises `Severity` on
its own (see Step 7). Drop bot/release posts that aren't actual deploy
announcements.

### Step 6 — Write the digest log

The scheduler creates the log file for this run. Append the body in
this exact structure:

```
## Window

From <cutoff_human> to <now local>.
The **Shipped** section below uses a different, wider window —
<releases_cutoff_human> to <now local> (everything since the last run).

> Caveat: this is an approximation. The Slack MCP available to this task
> doesn't expose true unread state, so we use a time cutoff instead.
> Messages Gabor already read on mobile during the window may still appear.

## Mentions
<bulleted list — mentions outside the starred channels.
 Per item: channel, sender, time, one-line teaser, permalink.>

## DMs
<bulleted list — DMs + group DMs.
 Group by conversation partner. Tag the state plainly: "closed" (last
 msg is a closure ack), "ball with Gabor" (substantive question/ask
 from the other side, no reply yet), or "ball with <them>" (Gabor's
 last msg is substantive and unanswered).>

## Per-channel
<one subsection per starred channel that had new activity, ordered
 by priority (#hospitality-bugs first, then anything with [Critical]/
 [Major] in the text, then everything else). Up to ~5 bullets per channel.
 #hospitality-public uses a 7-day window (see Step 2); note that
 explicitly in its subsection header so Gabor knows the window
 differs.>

## Shipped
<what landed since the last run, from #tech-releases (Step 5) — a WIDER
 window than the sections above (see the Window note). Group by service;
 one entry per service listing the version(s) shipped, deployer, and a
 compressed summary of the meaningful changes. Collapse maintenance /
 dependabot bumps to "+ maintenance/deps". Link each release's Slack post
 (drop the dot in its ts), and keep the GitHub `View release` link when
 useful. Newest service activity first.>

## Outcome
Status: success
Severity: <ok | attention | failure>
```

If a section is empty, write a single line `_None._` under it rather
than omitting the heading — keeps the output shape consistent.

### Severity rules

- `ok` — nothing new anywhere, or only bot noise / Gabor's own outgoing.
- `attention` — any of: a `[Critical]` or `[Major]` item in
  #hospitality-bugs, an @-mention of Gabor outside starred channels, or
  a DM with the ball on Gabor's side. Default for a normal Monday run.
- `failure` — Slack API calls erred out and you couldn't reconstruct
  the digest. Include the error text in the log body.

The **Shipped** section (#tech-releases) is informational — a normal
deploy feed never raises severity on its own.

### Step 7 — Notification

If `Severity: attention`, append:

```
## Notification

- title: Slack digest — what you missed
- subtitle: <N mentions · M DMs · K channels>
- body: <one-line teaser of the single most urgent item, ~90 chars.
        Prefer a Critical bug if present; otherwise a DM with the
        ball on Gabor; otherwise the loudest channel item.>
- sound: default
```

Skip the notification on `ok` runs.

## Context

### The unread-state limitation

Slack's Web API exposes true unread state via
`conversations.info.last_read` + `conversations.history?oldest=last_read`,
but the MCP wrapper this task uses doesn't surface `last_read`. The clean
fix is a personal Slack app installed in `livekasa` with user scopes
(`channels:history`, `groups:history`, `im:history`, `mpim:history`, …).
That install requires admin approval, which Gabor opted not to pursue
on 2026-05-18.

If that decision changes later: replace the cutoff in Step 1 with a
per-conversation `conversations.info` lookup to read `last_read`, fetch
history with `oldest=last_read&inclusive=false`, and the
"already-read-on-mobile" caveat goes away.

### Why weekdays at 07:00

Catches the previous workday before Gabor's morning rhythm starts; on
Monday it covers the whole weekend. Runs early enough that the digest
is waiting when he sits down — ahead of
[[hospitality-calendar-audit]] (08:00) and [[weekly-insights-review]]
(09:00 Mon).

### No PRE-AUTHORIZED actions

This task is strictly read-only — `slack_read_channel`,
`slack_read_thread`, `slack_search_public_and_private` are the only MCP
calls it should make. Do not invoke `slack_send_message`,
`slack_send_message_draft`, or `slack_schedule_message`.
