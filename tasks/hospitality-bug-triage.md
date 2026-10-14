---
id: hospitality-bug-triage
icon: ladybug
title: Weekday bug triage — new reports in #hospitality-bugs
type: recurring
model: claude-opus-5-5
effort: high
schedule: "30 6 * * 1-5"
next_run: 2026-10-15T06:30:00+02:00
created: 2026-10-14T08:46:20+02:00
status: active
---

## Triage rulings

Gabor's corrections to earlier verdicts. Read these before Step 5 and
apply them. Each line is one ruling, with the date and the ticket that
prompted it. When a ruling contradicts the Instructions below, the ruling
wins.

_None yet._

## Instructions

You triage new bug reports in #hospitality-bugs (`C0437ACUVD5`, workspace
`livekasa`). For each HSP ticket that is still waiting for triage, you do
three things. You decide whether it is a real bug, working from the facts
and not from the reporter's root-cause analysis. You decide which team
owns the cause (HSP or RC). You add a valid HSP bug to the active HSP
sprint. Everything else is reported to Gabor.

**This task is in a testing phase.** The single permitted mutation is
listed below. Everything else is read-only.

> PRE-AUTHORIZED: add an HSP-project ticket to the currently active
> Hospitality sprint (board 48), and only when Step 5's gate passes. Use
> `POST https://kasa.atlassian.net/rest/agile/1.0/sprint/{activeSprintId}/issue`
> with body `{"issues":["HSP-NNNN"]}`, then read `customfield_10020` back to
> confirm.

**Forbidden, no exceptions:**
- Any Slack write: `slack_send_message`, `slack_send_message_draft`,
  `slack_schedule_message`, reactions, canvases. Do not reply to anyone.
- Any other Jira write: comments, transitions, assignee, priority, labels,
  fields, links, moving a ticket between projects, creating tickets. Do not
  touch RC tickets. Do not remove anything from a sprint.
- Any production write (Mongo, APIs, SQS/SNS, S3, Dynamo, ConfigCat).
- Any git mutation in the repos under `~/Documents/workspace/kasa/`, such
  as checkout, pull, branch, commit, stash or worktree. Gabor has
  in-flight work there. `git fetch` is fine. Read the latest code with
  `git -C <repo> show origin/master:<path>`, `git -C <repo> grep <pattern>
  origin/master`, or `gh api`/`gh search code`.
- Notion writes. The `ticket-triage` skill tells you to log to the Notion
  "Triage Case Log". Skip that step. Reading it is fine.
- PRs, and code changes anywhere.

If a step seems to need any of these, do not do it. Write what you would
have done in the report under "Would have done".

Use the `shared-kasa-jira` skill's auth for all Jira calls
(`. ~/.claude/skills/shared-kasa-jira/scripts/auth.sh` gives `$AUTH`; the
host is `kasa.atlassian.net`). Never call `mcp__claude_ai_Atlassian__*`
tools.

### Step 1 — Collect reports (rolling 14 days)

Read #hospitality-bugs with `slack_read_channel(channel_id="C0437ACUVD5",
oldest=<now − 14 days>, limit=100, response_format="detailed")`. Paginate
with `cursor` until the window is covered.

A **report** is a top-level message, from anyone, that reports a problem
and links an **HSP** ticket. No particular format is required. TechOps
usually writes `[PRD][Severity]` plus a link, but a teammate posting their
own bug counts too. These are not reports: messages asking for a PR
review, chatter, and messages that link only RC or other non-HSP tickets.
If a message links a Slack thread instead of a ticket, read that thread
and look for an HSP key. If there is none, ignore the message.

For each report, record:
- the HSP key(s) from `kasa.atlassian.net/browse/HSP-…` links;
- the poster's name and the local time;
- the message text (it often carries context, e.g. "RC half currently in
  review");
- the thread, if `Thread: N replies` is shown. Read it with
  `slack_read_thread`. A claim in the thread such as "I'll take this" does
  not count as triaged. Jira decides that. Note the claim in the report.

Build each permalink by dropping the dot in `Message TS`:
`https://livekasa.slack.com/archives/C0437ACUVD5/p<ts_without_dot>`.

### Step 2 — Filter to "waiting for triage"

Fetch each key once:
`GET /rest/api/3/issue/<KEY>?fields=summary,status,assignee,reporter,customfield_10020,issuetype,priority,created,updated,project,components,description`.

A ticket is **waiting for triage** when all three hold, whatever the
status. `Ready To Triage` is an old status that means the same as To Do.
1. **Open.** `status.statusCategory.key` is not `done`.
2. **Not in the active sprint.** No entry in `customfield_10020` has
   `state == "active"`. Closed past sprints don't count. A ticket in the
   active sprint has been looked at by someone on the team, even if
   unassigned.
3. **No assignee.**

Tickets that fail any condition are **already handled**. Count them in
the report and don't list them.

Then check the ledger from earlier runs (Step 6 defines its format). Read
the previous run logs, `ls -1r logs/hospitality-bug-triage-*.md`, newest
first. Skip this run's own log, which is the newest file and less than an
hour old. Collect the latest ledger line per key. Logs are read-only, so
never edit them.

If a waiting ticket already has a ledger verdict and its Jira `updated`
timestamp is older than that ledger entry, don't re-investigate it. Carry
it forward to "Still waiting from earlier runs" with the old verdict and
the date. If the ticket changed since then, triage it again.

Cap: investigate at most **6** tickets per run, oldest report first. List
the rest under "Deferred to next run". The rolling window picks them up
on the next weekday. The cap limits how long one run can take, e.g. when
an incident brings a burst of tickets. Normal volume is 3 or fewer a day.

### Step 3 — Read the ticket and separate facts from assumptions

TechOps tickets are AI-written and often contain a confident but wrong
root-cause analysis. Before investigating anything, take the ticket
apart, including the description, comments and any linked Slack thread,
into a claims table:

| # | Claim | Kind | Evidence in ticket |
|---|---|---|---|

`Kind` is one of:
- **Observation**: something someone saw, with an artefact behind it.
  For example a reservation code, a timestamp, a log line, a screenshot
  or a guest report.
- **Inference**: an explanation or causal claim. For example "X fails
  because Y", "the service does Z", "this was introduced by…", a code
  path or line number, or a proposed fix.
- **Unclear**: it can't be told which. Treat it as an inference.

Only observations are inputs to your RCA. Treat inferences as untested
hypotheses, and don't let them steer the investigation. Pull out the
concrete entities: reservation codes, unit/building IDs, lock IDs,
timestamps, services named.

### Step 4 — Root-cause analysis on the facts

Use the **Diagnosis discipline** from the `investigate` skill
(`~/.claude/skills/investigate/SKILL.md`, steps A–C). Run only that
section. Do not run its Phase 2 (create a ticket), Phase 3 steps 1–3
(branch, transition, assign, sprint), its fix step, or Phases 4–5 (PR).
In practice:

- **A. Red loop.** Show the observed symptom with a read-only probe on
  the ticket's own entities. That can be a Mongo query, a
  Datadog/CloudWatch log count, a `kasa-api` GET, or the code path at
  `origin/master`. Run it and keep the output, with secrets shown as
  `<REDACTED>`. If you cannot reproduce the observation, say so and say
  exactly what you tried.
- **B. Minimise.** Narrow it to the smallest condition that produces the
  symptom.
- **C. Hypotheses.** Rank 3–5 falsifiable hypotheses, then probe the top
  ones one variable at a time.

For access, lock-code, PAC, VFD or keyless tickets, also apply the
`shared-kasa-access-triage` skill's not-a-software-bug fast path and its
red-herring guards. Use the `shared-kasa-ticket-triage` skill's case-memory
search and duplicate-ticket search (Jira RC/HSP/HELP, Notion) as leads.
Again, never its Notion write.

Tools: `shared-kasa-mongocli`, `shared-kasa-datadog-logs`,
`shared-kasa-cloudwatch-logs`, `shared-kasa-kasa-api`, and repo code via
`gh` or `git show origin/master:…`. Datadog keeps 14 days, so use
CloudWatch for anything older.

**Scratch files** (query bodies, saved API responses): create one folder
per run with `SCRATCH=$(mktemp -d -t hospitality-bug-triage)` and keep
every temporary file in it. Don't write to a fixed path like `/tmp/<key>`,
where runs would collide or reuse stale files. Never put scratch files in
`logs/`, `tasks/` or a repo.

**AWS credentials**: this spawned process may inherit short-lived STS env
vars that shadow the SSO profile and expire mid-run. Run every AWS-backed
command as `env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u
AWS_SESSION_TOKEN <cmd> --profile "${AWS_PROFILE:-poweruser}"`, or hydrate
once via `aws configure export-credentials`. If the SSO session itself is
dead, try the `shared-kasa-aws-auto-login` skill once. If that fails, mark
the affected tickets `unverified (blocked: <error>)` and continue. Never
guess around a block.

Time box: about 20 minutes of investigation per ticket. If you run out,
stop with what is established and mark the verdict `unverified`.

### Step 5 — Verdicts and the sprint gate

Apply `## Triage rulings` first. Then, for each ticket, decide:

**Verdict:**
- `valid-bug`: the system produced behaviour it should not, proven one
  of two ways. Record which one:
  - `proof: data`. Your own probe shows the bad state on the ticket's
    own entities.
  - `proof: code`. The data has moved on (code expired, guest checked
    out), but the observations, such as logs from the time or
    timestamps, plus a code path at `origin/master` that clearly produces
    them, establish it. Cite file:line.
- `works-as-expected`: the observation is real, but it is designed or
  configured behaviour. Cite the code or config.
- `not-reproducible`: neither kind of proof could find the reported
  state.
- `not-software`: hardware, vendor outage, ops or config data entry.
  Name what it is.
- `duplicate`: same root cause as an existing ticket. Name the key.
- `unverified`: blocked or out of time. Name the blocker.

**Owner** (HSP, RC or split). Take it from the repo or service where the
*verified* root cause lives. Never take it from the ticket's summary tag
or the reporter's RCA. Look at that repo's CODEOWNERS:
`rg --hidden -g CODEOWNERS -g '!node_modules/**' '@kasadev/' ~/Documents/workspace/kasa/<repo>`.
`@kasadev/hospitality` means HSP and `@kasadev/formula-rc` means RC. If
CODEOWNERS names only individuals or another team, decide from the domain
and say so. RC (Formula RC) owns the financial domain: balances, payments,
financials, rates and quotes, promotions, and extension/group financials.
HSP owns guest experience and operations: access and lock codes (css-api,
code-setting-service, device-service, the lock syncs), PAC, VFD and
check-in, guest-api, and Kontrol ops flows. A ticket can be split across
both. If it is, name both parts.

**RCA comparison:** go through the reporter's inferences from Step 3 one
by one. Mark each `confirmed`, `wrong` (and give what is actually true) or
`untested`.

**Sprint gate.** Add the ticket to the active HSP sprint only when all of
these hold:
- the verdict is `valid-bug`, with either kind of proof;
- the owner is HSP, or it's a split and the HSP part is confirmed and
  still open. We take care of our part. Note the RC part as "recommend a
  separate RC ticket" and create nothing;
- the Step 2 conditions still hold when you re-fetch the ticket just
  before writing, because someone may have picked it up during the run.

Resolve the active sprint live, never from memory:
`GET /rest/agile/1.0/board/48/sprint?state=active`. Board 48 always has
exactly one active sprint. If there are zero or several, something is
broken. Add nothing, put "Board 48 sprint state broken: <what you saw>"
at the top of the report, and set Severity to `attention`. After the
POST, re-fetch `customfield_10020` and confirm the sprint appears. Record
`added` or `add-failed: <error>`.

In every other case, do not touch the ticket. A valid bug owned by RC is
"recommend: route to RC", and Gabor decides. A ticket that isn't a valid
bug is "recommend: <close / ask reporter for X / merge into KEY>".

### Step 6 — Write the report

Append `## Report` to the run log with this structure. Tag every factual
claim as **measured** (you ran it; name the query or tool), **derived**
(computed from measured inputs) or **assumed** (say what would settle it).

```
## Report

**Window:** <now − 14d> → <now>. Reports found: N · waiting for triage: T
(investigated: I, carried forward: C, deferred: D) · added to sprint: A
· already handled: H. Active sprint: <name> (<id>).

### Added to sprint
<one line per ticket: KEY — summary — owner — proof: data|code — one-
 sentence root cause. Or _None._>

### Needs your decision
<valid bugs owned by RC, works-as-expected / not-reproducible /
 not-software / duplicate verdicts, unverified items, add-failed.
 One line each: KEY — verdict — owner — recommended action. Or _None._>

### Ticket details
<for each investigated ticket, in this order:>

#### <KEY> — <summary>
- Slack: <permalink> · posted by <name>, <local time>
- Jira: https://kasa.atlassian.net/browse/<KEY> · <status> · priority <p>
- Thread claim: <who said what, or "none">
- **Verdict:** <verdict> (proof: <data|code>, for valid-bug) ·
  **Owner:** <HSP|RC|split> · **Action:** <added | none, and why>

**Facts vs assumptions**
<the Step 3 claims table>

**Our RCA**
<red-loop command and result (measured), minimisation, ranked hypotheses
 and which probe settled each, and the root cause with file:line at
 origin/master where applicable. Or exactly what blocked it.>

**Their RCA vs ours**
<one line per reporter inference: confirmed / wrong (what's true) /
 untested>

**Would have done** (skipped, testing mode)
<e.g. comment on the ticket correcting the RCA, reassign to RC. Omit
 if nothing.>

### Still waiting from earlier runs
<KEY — earlier verdict — earlier run date. Or _None._>

### Deferred to next run
<KEY — summary. Or _None._>

### Ledger
<fenced block, one line per ticket triaged OR carried forward this run,
 exactly this shape, used by Step 2 of the next run:>
triage | <KEY> | <verdict> | <owner> | <added|not-added|add-failed> | <ISO timestamp of this run>
```

Keep the prose plain. No guest PII beyond what the investigation needs:
use reservation codes, not guest names, emails or phone numbers.

### Step 7 — Outcome and notification

`## Outcome`:
- **Status:** `success` if the run completed (even with some tickets
  `unverified`). `failure` if Slack or Jira reads failed and you couldn't
  build the list, or if anything forbidden happened. `skipped` is not
  used.
- **Severity:**
  - `ok`: nothing waiting for triage.
  - `attention`: anything added to the sprint, anything in "Needs your
    decision", an `add-failed`, or a broken board 48 sprint state.
  - `failure`: errored, as above.
- **Summary:** counts. For example "3 new bugs: 1 added to sprint,
  1 RC-owned, 1 works-as-expected."

On `attention`, append:

```
## Notification

- title: Bug triage — <A> added, <N> need you
- body: <the single most important item, ~90 chars>
- sound: default
```

## Context

- Requested by Gabor on 2026-10-14 and refined in a grilling session the
  same day. TechOps (currently Jennifer McAleese, Edgar Leiva and others)
  files production bugs in Jira and posts each one to #hospitality-bugs.
  Their tickets are AI-generated. They usually pick the right team, but
  their root-cause sections are often wrong. That is why Step 3 separates
  facts from inferences before any investigation.
- TechOps never adds tickets to the HSP sprint. A ticket in the active
  sprint was put there by someone on the team, so it counts as triaged.
- Only HSP-project tickets are in scope. Routing RC tickets, or HSP
  tickets that turn out to be RC-owned, is Gabor's decision for now.
- **Testing phase.** Adding to the sprint is the only write. Output is
  the run log only. Once Gabor trusts the verdicts, likely next steps are
  commenting the corrected RCA on the ticket, reassigning RC-owned
  tickets, and replying in the Slack thread. Each needs its own
  `PRE-AUTHORIZED:` line before the task may do it.
- **Why a rolling 14-day window plus a ledger, not "since the last run".**
  A missed run (laptop asleep, app down) would silently drop reports with
  a since-last-run window. The rolling window re-checks Jira state every
  run, so a ticket stays in scope until someone triages it, and Monday
  covers the weekend. The ledger stops the task from re-investigating the
  same untouched ticket every day.
- Jira: HSP board 48, sprint field `customfield_10020`, HSP has no story
  points. Never set them. Sprint ids rotate every two weeks, so always
  resolve the active sprint live.
- The scheduler runs this as `claude -p` with no one to answer questions.
  Skills that say "ask the user" (e.g. `investigate`'s branch and PR
  prompts) do not apply here. Take the read-only path and record the open
  question in the report.
