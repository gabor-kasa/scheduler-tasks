---
id: one-on-one-prep
icon: person.2
title: Daily 1:1 prep briefs for direct reports
type: recurring
schedule: "0 7 * * 1-5"
next_run: 2026-06-03T07:00:00+02:00
last_run: 2026-06-02T07:10:53+02:00
created: 2026-05-18T16:00:00+02:00
status: active
---

## Direct reports (HSP team)

Used to filter today's calendar events to actual 1:1s and to feed the
canonical display name into the inner prompt. Maintain this table —
calendar event titles usually include one of the values in
`Calendar aliases`, and `Jira display name` is what keys the
`changesByPerson` map in the daily standup reports.

| Jira display name | Calendar aliases | Google username | GitHub |
| --- | --- | --- | --- |
| Zoltán Fehér       | Zoltán, Zoli            | zoli                 | zoli-kasa     |
| Balázs Iván        | Iván, Balázs Iván       | balazs.ivan          | ibalazs-kasa  |
| Tamas Fodor        | Tamas, Tamás            | tamas.fodor          | tamas-kasa    |
| Janos Mayer        | Janos, János            | janos                | janos-kasa    |
| Norbert Pospischek | Norbert, Norbi          | norbert.pospischek   | norbertp-kasa |
| Viktória Molnár    | Viktória, Viki          | viktoria             | viktoria-kasa |
| Kristóf Iváncza    | Kristóf, Kristof        | kristof.ivancza      | kristof-kasa  |
| Péter Horváth      | Péter, Peter            | peter.horvath        | peter-kasa    |

Important disambiguation: "Balázs" on its own is **not** a reliable match
— there is also a Balázs Antal on TechOps (not a direct report). Only
treat a calendar title as referring to Balázs Iván (DR) when it contains
`Iván` or the full `Balázs Iván`.

If the calendar surfaces a 1:1 whose short name isn't in this table,
pass the short name through verbatim — the inner Claude resolves it
against the DynamoDB data (and the outer log records the resolution so
you can extend the table after the fact).

## Instructions

Gabor's morning 1:1 prep. Local timezone Europe/Budapest. TEAM_ID for
the Jira app is `hsp`. The task fires **once** per weekday at 07:00,
then waits in a poll loop for AWS SSO creds to become valid (Gabor
refreshes them sometime between 07:00 and 10:00). After 10:00 with no
valid creds, the task gives up with a notification.

### Credential handling — READ THIS FIRST

The scheduler launches this run with **short-lived STS credentials frozen
into the process environment** (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_SESSION_TOKEN`). They expire ~2h after launch, and because env-var
creds sit at the **top** of AWS's resolution chain they *shadow* the
on-disk SSO profile cache that `aws-login` refreshes. A running process
cannot inherit a later `aws-login`, so any `aws` call that uses the
inherited env vars fails with `ExpiredToken` — and the Step 1 poll loop
below would then wait until 10:00 forever, never seeing the refresh.
(This is exactly what broke the 2026-06-01 run: fired 07:04, Gabor logged
in 07:05, still fruitlessly polling at 08:50.)

So strip those three env vars on **every** command that touches AWS — the
Step 1 poll loop, the Step 3 DynamoDB reads, **and** the inner `claude -p`
in Step 4 (it inherits the same frozen env and does its own `aws dynamodb`
reads). Resolution then falls through to the `default` SSO profile, which
the SDK auto-refreshes from the on-disk SSO token `aws sso login` keeps
current. Prepend this exact **AWS-clean prefix** to each such command:

```
env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN AWS_PROFILE=default
```

The three `-u` flags drop the dead env creds; `AWS_PROFILE=default` makes
the SSO profile explicit. Each Bash tool call is a fresh shell, so prepend
this literal prefix **in the same invocation** as the command — don't rely
on a shell variable set in an earlier call. (Verified: with these vars
unset and the `default` profile, `aws sts get-caller-identity` succeeds via
the `Kasa` SSO session.)

### Step 1 — wait for AWS creds (up to 10:00 local)

Loop until either `aws sts get-caller-identity --region us-west-2`
succeeds, or local time reaches **10:00** Europe/Budapest, whichever
comes first.

The loop body, each iteration:

1. Run the credential check **with the AWS-clean prefix** (see
   **Credential handling** above — without it this check uses the frozen
   env creds and can never succeed):
   ```
   env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN AWS_PROFILE=default aws sts get-caller-identity --region us-west-2
   ```
   with a 15s timeout. If it succeeds, log `aws creds valid at <local
   time>` and break out of the loop — continue to Step 2.
2. If it fails, check the current local time:
   - If local time is **≥ 10:00** → stop looping, write the
     failure-with-notification block below, and **stop** the whole task.
   - Otherwise, log a single line like `aws creds still expired at
     <local time>, sleeping 5m` and sleep 300 seconds. (Use the Bash
     tool's `timeout` parameter — set it to 360000ms — so the 5-minute
     `sleep 300` completes within budget.) Loop again.

**Run one iteration per Bash tool call** — check, log a line, `sleep 300`,
return — and let this outer loop drive the repetition. Do **not** collapse
the whole wait into a single shell `until …; do … sleep 300; done`
command: a single long-running call buffers every per-iteration log line
until it finally exits, so the run looks frozen for hours (that is what
happened on 2026-06-01 — it was polling fine but the log hadn't flushed),
and one call spanning the full ~3h wait can exceed the Bash timeout
ceiling in stricter environments.

Don't fire any notification for in-progress polling — only fire the
"creds expired" notification at the 10:00 give-up point. Specifically,
if you give up at 10:00 with no valid creds, write to the log:

```
aws creds never refreshed before 10:00 local — giving up for today
```

then append:

```
## Outcome

- **Status:** failure
- **Severity:** failure
- **Finished:** <ISO timestamp with local offset>
- **Summary:** AWS creds did not refresh by 10:00 local. No 1:1 briefs produced.

## Notification

- title: AWS creds expired
- body: 1:1 prep gave up at 10:00 — run aws-login to unblock tomorrow.
- sound: default
```

…and stop. Do **not** proceed to Step 2.

### Step 2 — today's 1:1s

Call `mcp__claude_ai_Google_Calendar__list_events`:

- `startTime`: today 00:00 local (`<TODAY>T00:00:00+02:00`)
- `endTime`: today 23:59 local
- `timeZone`: `Europe/Budapest`
- `pageSize`: 100
- `orderBy`: `startTime`

Filter to events that look like 1:1s with a direct report:

- `status` is not `cancelled`
- AND either:
  - the title contains `1:1`, `1-1`, `1 on 1`, `/ Gabor`, or `Gabor /`
    (case-insensitive); OR
  - the event has exactly 2 attendees (Gabor + one other) AND that
    "other" maps to someone in the direct-reports table above.

For each match emit `{shortName, eventTime, eventTitle, displayNameHint}`.
`displayNameHint` is the right-column value from the table if found,
else the raw short name (the inner Claude will resolve it).

If the filtered list is empty → write a short log
`no 1:1s with directs today`. `Severity: ok`, `Status: success`. Stop.

### Step 3 — active sprint start date

The inner-prompt guardrails need this to suppress sprint-planning-day
admin bursts. Read DynamoDB:

```
env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN AWS_PROFILE=default \
  aws dynamodb get-item \
  --table-name jira-dashboard-production-tableTable-bdxoxuzx \
  --key '{"PK":{"S":"TEAM#hsp#DAILY_REPORT#<TODAY>"},"SK":{"S":"STANDUP"}}' \
  --region us-west-2 \
  --output json
```

The HSP report Lambda runs at `cron(50 8 ? * MON-FRI *)` UTC
(≈ 10:50 Europe/Budapest summer / 09:50 winter), so today's item may
not exist yet at 07:00-09:00. Walk back day-by-day for up to 7 days
until you find one. From the item, read
`.Item.data.M.sprintStartDate.S` and call this `SPRINT_START_DATE`. If
no report exists in the last 7 days, abort with `Severity: failure`,
`Status: failure` — something is wrong upstream.

### Step 4 — per-direct briefs

For each `{displayNameHint, eventTime, eventTitle}` from step 2:

1. Build the inner prompt by template-filling `## Inner prompt template`
   (below) with:
   - `{{PERSON}}` = `displayNameHint`
   - `{{TEAM_ID}}` = `hsp`
   - `{{TODAY}}` = local `YYYY-MM-DD`
   - `{{SPRINT_START_DATE}}` = the value from step 3
2. Write the resulting prompt to `/tmp/one-on-one-prep-<slug>.md` (slug
   = lowercase displayNameHint, spaces → dashes).
3. Run, with cwd `../jira`, 5-minute timeout. Launch it **with the
   AWS-clean prefix** — the inner Claude inherits this run's frozen env and
   does its own `aws dynamodb` reads, so it needs the clean credential
   environment too:
   ```
   (cd ../jira && env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN AWS_PROFILE=default claude -p --output-format text < /tmp/one-on-one-prep-<slug>.md)
   ```
   Capture stdout.
4. Delete the temp file.
5. If the call errors, times out, or returns empty stdout, record a
   `(brief generation failed: <reason>)` placeholder for that person
   and continue.

### Step 5 — write the day's log

Append to the per-run log file (the runner already created it for you):

```
# 1:1 prep — <TODAY>

Sprint start date (passed to inner): <SPRINT_START_DATE>
N briefs: <count of successful inner runs>

## <displayNameHint> — <eventTime> (event: "<eventTitle>")

<inner Claude stdout, verbatim>

---

## <next person>
...
```

If the inner Claude reports an ambiguous-name failure (its prompt tells
it to "list candidates and stop"), include its stdout verbatim — that
disambiguation is the value of running it.

Then append the Outcome:

```
## Outcome

- **Status:** success
- **Severity:** attention
- **Finished:** <ISO timestamp with local offset>
- **Summary:** <count> briefs for <comma-separated displayNameHints>
```

Severity is always `attention` when ≥ 1 brief was produced — the orange
triangle is the cue to read the briefs before today's 1:1s.

### Step 6 — Notification

If ≥ 1 brief was produced, append:

```
## Notification

- title: 1:1 prep ready
- body: <count> brief(s) ready for today.
- sound: default
```

## Inner prompt template

Verbatim — do not edit between runs without checking with Gabor. The
outer task fills `{{PERSON}}`, `{{TEAM_ID}}`, `{{TODAY}}`,
`{{SPRINT_START_DATE}}` and writes the result to a temp file before
piping to `claude -p`.

```
You are preparing a 1:1 prep brief for an engineering manager. The person they're
meeting is {{PERSON}} on team {{TEAM_ID}}. Today is {{TODAY}}. The active sprint
started on {{SPRINT_START_DATE}}.

# Data source

Daily standup reports for the past 14 calendar days live in the production
DynamoDB table `jira-dashboard-production-tableTable-bdxoxuzx` (region
`us-west-2`). Key format:

  PK = "TEAM#{{TEAM_ID}}#DAILY_REPORT#YYYY-MM-DD"
  SK = "STANDUP"

The person's per-day section is at:
  .Item.data.M.changesByPerson.M["<displayName>"].M

Each person record contains:
  - summary           (free-text AI summary; usually includes a "===SPRINT_SUMMARY==="
                       block after the daily activities)
  - tickets           (ticket updates that day)
  - commits, prsCreated, prsMerged, reviewsGiven
  - totalCommits, totalPRs, totalReviews, totalTicketChanges
  - assignedOpenTickets (current snapshot — pull from the MOST RECENT day only)

# Steps

1. Resolve {{PERSON}} to the full display name used as the map key (e.g. "Viki"
   → "Viktória Molnár"). If ambiguous, list candidates and stop.
2. Fetch reports for the past 14 calendar days. Skip days with no item.
3. Extract that person's `summary` and key counters for each day, plus the
   `assignedOpenTickets` from the most recent day.

# Output: a 1:1 prep brief, two sections only

## What they've worked on
Walk through the period chronologically. Group by sprint if a sprint boundary
falls inside the window. For each meaningful day call out: tickets moved to
Done, PRs merged, big code-review days, and PTO. Don't list every status nudge;
roll up admin-only days into one line. End with the CURRENT open tickets
(ticket key, summary, status, story points).

## Things worth flagging in the 1:1
A short numbered list. Each item: one-sentence observation + one-sentence
suggestion of what to ask. Prioritize, in this order:

  a. Tickets stuck in Review > 3 working days (who's the bottleneck).
  b. Sprint commitment risk: SP done vs target with days elapsed.
  c. Activity gaps of 3+ working days that ARE NOT explained by PTO.
  d. Work done DURING logged PTO (boundary check + ask if calendar is wrong).
  e. Commits/PRs not tied to any ticket key — likely needs linking.
  f. Anything else genuinely surprising in the data.

# Guardrails — do NOT flag these as concerns

  - Story-point edits or status churn within the first 1–2 working days from
    {{SPRINT_START_DATE}}. Treat bulk ticket admin in that window as expected
    sprint-planning hygiene, not a red flag.
  - Bursty delivery (one big merge day after several quiet days) on its own —
    only flag if the quiet stretch is 3+ working days AND there's no ticket
    movement either.
  - PTO days with no activity.
  - Story-point reductions that bring a ticket closer to its actual delivered
    scope at the end of a sprint.

# Style

Direct, specific, manager-to-manager. Whenever you reference a ticket, ALWAYS
include its title alongside the key — format: `HSP-XXXX (short ticket title)`.
A bare `HSP-XXXX` is not enough context for Gabor to know what the ticket is
about. This applies everywhere: the chronological walk-through, the open
tickets list, and every item in "Things worth flagging". Pull the title from
the standup report's ticket data (`tickets[].summary` or equivalent); if the
title isn't present in the report, fetch it before writing the brief. Also
include dates. No fluff, no closing summary paragraph. If the data is thin
(person on extended PTO, new to team, etc.) say so plainly and keep the brief
short.
```

## Context

- The `../jira` repo (sibling of this scheduler tree) is the Jira analytics
  dashboard for HSP. Its production DynamoDB table is what this task reads.
  The inner Claude is launched with `../jira` as cwd so its CLAUDE.md guides
  it correctly on table shape and conventions.
- Daily standup Lambda schedule for HSP: `cron(50 8 ? * MON-FRI *)` UTC.
  That's why step 3 tolerates "today's report not yet written" and walks
  back. The inner Claude does the same — historical reports drive its
  output.
- Sprint boundary handling: passing `SPRINT_START_DATE` to the inner prompt
  is the single biggest false-positive suppressor (sprint-planning-day
  admin bursts otherwise read as "concerning churn"). Don't drop it.
- Long-running by design: step 1 may sit in a `sleep`-loop for up to 3
  hours waiting for AWS creds. That is intentional — this replaced the
  old multi-fire retry pattern (which kept misfiring on a fragile marker
  check). The Swift scheduler does not enforce a per-task timeout, so
  the loop is safe to run.
- PRE-AUTHORIZED: read-only AWS calls only —
  `aws sts get-caller-identity`, `aws dynamodb get-item`. No writes.
- PRE-AUTHORIZED: `sleep 300` invocations in the step-1 polling loop.
- PRE-AUTHORIZED: spawning `claude -p` as a subprocess from within
  `../jira` is the core mechanic — the inner Claude has free run of the
  jira repo's tools (it can `aws dynamodb get-item` repeatedly to walk
  the 14-day window).
- Future extensions (not implemented yet):
  - Cache resolved `shortName → displayName` mappings so the inner
    Claude doesn't pay the lookup each time.
  - Optionally have the inner Claude pull each ticket's recent Jira
    comments + PR descriptions for richer context (the daily summaries
    are already AI-condensed, so a second-pass agent loses nuance —
    weigh carefully).
