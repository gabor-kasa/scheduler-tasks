---
id: hospitality-calendar-audit
icon: calendar
title: "Audit [Hospitality] team meetings against scheduling rules"
type: recurring
schedule: "0 8 * * 1"
created: 2026-05-11T15:05:00+02:00
status: active
---

## Instructions

You are auditing the [Hospitality] team calendar against a fixed set of
scheduling rules. Local timezone is **Europe/Budapest**. Only consider
workdays (Mon–Fri). Ignore deleted/cancelled events.

### Step 1 — Fetch events

Call the Google Calendar MCP tool to list events from the user's primary
calendar:

- Tool: `mcp__claude_ai_Google_Calendar__list_events`
- `startTime`: the start of today in local time, ISO 8601 with `+02:00` (or
  current offset if DST changes)
- `endTime`: 28 days from `startTime`
- `timeZone`: `Europe/Budapest`
- `pageSize`: 250
- `orderBy`: `startTime`

If the tool is unavailable, abort the task: set `status: failed` and write
the reason to the log. Do not silently skip.

### Step 2 — Filter

Keep only events where:

- `summary` starts with the literal prefix `[Hospitality]`
- `status` is not `cancelled`
- `start.dateTime` is in the future (relative to NOW)

Distinguish carefully:

- `[Hospitality] Grooming` and `[Hospitality] Tech Debt Grooming` are
  **different** events — match the full summary, not a substring.
- A **planning event** has the exact summary
  `[Hospitality] Review + Retro + Planning`. Match the full string, not a
  substring. This is the anchor for Rules A/B/C/D below.
- Standup event summary is `[Hospitality] Standup`.

### Step 3 — Convert times explicitly

For each kept event, show your work in a conversion table:

| Event summary | Original timestamp | Europe/Budapest date+time | Day of week |
|---|---|---|---|

Critical: **verify the year first** (don't assume current year), convert
to Europe/Budapest **before** computing the weekday, and re-derive the
weekday from the converted date — not the original. Timezone conversions
can shift both the date and the day of the week.

You may keep this table internal if there are no violations. If there are
violations, include only the rows involved in violations in the final log
output.

### Step 4 — Check rules

After conversion, audit against these four rules. "Planning event" means
an event whose summary is exactly `[Hospitality] Review + Retro + Planning`
(see Step 2).

**Rule A — Standups on every workday except planning days and holidays.**

For each weekday between NOW and NOW+28d:

- If the day is a planning day (a planning event falls on it), there must
  NOT be a `[Hospitality] Standup` event that day. If there is → violation.
  This holds **regardless of which weekday the planning event lands on** —
  if planning was moved to Tue/Wed/Thu/Fri, that day still must have no
  standup. (The off-Monday placement is separately checked by Rule D, with
  its own holiday exemption; the two rules are evaluated independently.)
- If the day is a Hungarian national public holiday, the absence of a
  standup is fine — not a violation. (The team is based in Hungary and
  observes Hungarian holidays only; US holidays are irrelevant here.)
- Otherwise, there must be exactly one `[Hospitality] Standup` event that
  day. If missing → violation.

**Rule B — Grooming on the Thursday before planning.**

For each planning event:

- Compute the Thursday immediately before that planning date (in
  Europe/Budapest). A `[Hospitality] Grooming` event must exist on that
  Thursday. If missing, on a wrong day, or duplicated → violation.

**Rule C — Tech Debt Grooming on the Wednesday before planning.**

Same as Rule B but for `[Hospitality] Tech Debt Grooming` on the Wednesday
immediately before each planning date.

**Rule D — Planning must be on a Monday, except when that Monday is a Hungarian public holiday.**

Every planning event must land on a Monday in Europe/Budapest, with one
exception: if the Monday of that planning event's calendar week is a
Hungarian national public holiday, planning is deliberately moved to the
next workday (typically Tuesday) and is NOT a violation. The team is
based in Hungary and observes Hungarian holidays only — US/other holidays
do not count for this exemption.

To evaluate: take the planning event's date in Europe/Budapest, find that
ISO week's Monday, and check whether that Monday falls on a Hungarian
national public holiday (e.g. Jan 1 New Year's Day, Mar 15 1848
Revolution, Easter Monday, May 1 Labour Day, Whit Monday, Aug 20 St.
Stephen's Day, Oct 23 1956 Revolution, Nov 1 All Saints', Dec 25–26
Christmas; also any government-declared substitute working/rest day
shift). If yes → no Rule D violation. If no → planning on any non-Monday
is a Rule D violation.

### Step 5 — Write the log

Append to `logs/hospitality-calendar-audit-<NOW>.md` (the file the
scheduler creates for this run). Be terse:

- If no violations: write a single line, `No rule violations in the next 28
  days. Audited N events.`
- If violations: list them one per line as `- <rule letter>: <description>`
  followed by the conversion table for only the events cited. Do not pad
  the output with summaries of compliant events.

### Step 6 — Set severity in the Outcome

When you write the Outcome section (see CRON_PROMPT.md, Step 3d), set the
`Severity:` field based on what you found:

- No violations → `Severity: ok`
- ≥ 1 violation, but the audit itself ran cleanly → `Severity: attention`
- The audit failed (couldn't fetch calendar, etc.) → `Severity: failure`
  (and `Status: failure`)

The desktop app uses this field to decide whether to badge the icon and
show the orange warning chevron on this run.

### Step 7 — Notify on violations only

If — and only if — there is at least one rule violation, append a
`## Notification` block to this run's log file. Skip this step on clean
runs; silence is the success state.

Block to append (verbatim format, fill in the placeholders):

```
## Notification

- title: Hospitality calendar audit
- subtitle: <N> rule violations
- body: <one-line summary, ~90 chars max>
- sound: default
```

- `<N>` is the count of violation lines (not the count of affected days).
- `<one-line summary>` rolls up by rule when there are many violations
  (e.g. `15× missing standups, 1× task definition mismatch`). The user
  clicks the banner to see the full list in the log.

The desktop app reads this block and fires the native macOS notification
— do not invoke any shell command. Clicking the banner opens this run's
log file. The notification is local-only (no API call, no shared state),
so no PRE-AUTHORIZED line is needed.

## Context

This task was migrated from an n8n workflow on 2026-05-11. The original
prompt was open-ended — these instructions tighten it for non-interactive
execution.

The audit is read-only (no PRE-AUTHORIZED actions needed) — it only calls
`list_events` and writes to the local log. Calendar write tools
(`create_event`, `update_event`) are NOT permitted by this task; if a
violation seems easy to auto-fix, still just report it.

Why these rules exist: Sprint Planning supersedes Standup, so we hold the
standup. The Thursday before is when product grooming happens (so the team
is ready for planning); the Wednesday before is when engineering grooms
the tech debt backlog. Violations usually mean someone moved a meeting and
broke the rhythm.

Calendar event differences worth knowing:
- `[Hospitality] Grooming` — product/story grooming, Thursdays
- `[Hospitality] Tech Debt Grooming` — engineering tech debt grooming,
  Wednesdays
- These are different cadences and different attendee sets. Don't conflate.
