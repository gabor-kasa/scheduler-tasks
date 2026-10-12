---
id: hospitality-calendar-audit
icon: calendar
title: "Audit [Hospitality] team meetings against scheduling rules"
type: recurring
model: claude-opus-5-5
effort: high
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

Recognised summaries (match the full summary, not a substring):

- `[Hospitality] Standup` — the daily standup.
- `[Hospitality] Retro + Sizing` — the **retro event**: a retro every second
  week, extended with an on-demand sizing session. This is the anchor for
  Rules A/D/E below. There is no separate sizing event to audit.
- `[Hospitality] Grooming`, `[Hospitality] Tech Debt Grooming` and
  `[Hospitality] Review + Retro + Planning` are **retired** (2026-10-12).
  The team no longer attends groomings and planning is gone. Ignore these
  events: their presence, absence or day is never a violation. Grooming
  events may still sit on the shared team calendar for other attendees.
- Any other `[Hospitality]` summary is not audited.

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

### Step 3.5 — Resolve the Hungarian work calendar

Before checking any rule, establish which dates in the audit window are
**non-working** in Hungary. Rules A and D both depend on this and must use
the same answer — they may never disagree about whether a given date is a
working day.

The authoritative source is the pinned work-calendar table in `## Context`
below. Use it. Do not derive holidays from memory, and do not re-research
dates the table already covers — the table exists so that two runs over the
same window cannot reach different conclusions.

Definitions:

- **Non-working** = a national public holiday (munkaszüneti nap) **or** a
  government-declared substitute rest day (áthelyezett pihenőnap, the
  "bridge day" traded against a working Saturday). Both are equally
  non-working; the distinction matters to payroll, not to this audit.
- A decreed **working Saturday** (ledolgozós szombat) is a working day in
  Hungary, but this audit only considers Mon–Fri (see the top of these
  instructions). Never flag a missing standup on a Saturday.

If the audit window extends into a year the pinned table does not cover:

1. `WebSearch` for that year's Hungarian work-schedule decree (the
   nemzetgazdasági miniszter's rendelet, published in Magyar Közlöny) and
   use what it says.
2. Record in the log that the pinned table needs extending, and name the
   year.

If you still cannot resolve whether a date is working or non-working, treat
it as **unresolved**: do not flag it as a violation and do not count it
toward the notification total. Instead list it in the log under a
`Notes (unverified)` heading with the date, the rule it would have
affected, and what you could not confirm. A false violation costs more than
a deferred one — this audit is only worth running if its notifications are
trustworthy.

### Step 4 — Check rules

After conversion, audit against rules A, D and E. B and C are retired and
keep their letters so older logs stay comparable. "Retro event" means an
event whose summary is exactly `[Hospitality] Retro + Sizing` (see Step 2),
and a "retro day" is a date a retro event falls on.

**Rule A — Standups on every workday except retro days and non-working days.**

For each weekday between NOW and NOW+28d:

- If the day is a retro day, there must NOT be a `[Hospitality] Standup`
  event that day. The retro replaces the standup. If there is → violation.
  This holds regardless of which weekday the retro lands on.
- If the day is **non-working** per Step 3.5 (a Hungarian national public
  holiday *or* a substitute rest day / bridge day), the absence of a
  standup is fine, not a violation. Both count equally. (The team is based
  in Hungary and observes Hungarian holidays only; US holidays are
  irrelevant here.)
- Otherwise, there must be exactly one `[Hospitality] Standup` event that
  day. If missing or duplicated → violation.

**Rule B — retired 2026-10-07.** No more regular Thursday Grooming. Never
emit a `B:` line.

**Rule C — retired 2026-10-12.** No more Tech Debt Grooming. Never emit a
`C:` line.

**Rule D — The retro must be on a Monday, except when that Monday is non-working.**

Every retro event must land on a Monday in Europe/Budapest, with one
exception: if the Monday of that retro's ISO week is **non-working** per
Step 3.5, the retro is deliberately moved to the next workday (typically
Tuesday) and is NOT a violation. Use the pinned table, do not re-derive
the holiday list here. If the date is unresolved, follow Step 3.5's
unresolved handling (note it, don't flag it).

**Rule E — Retro every second week.**

Retros run on a two-week cadence. Any 28-day window holds exactly two
retros, in ISO weeks two apart (compare ISO weeks, not dates, so a
holiday-shifted Tuesday retro still counts for its week).

- Fewer than two retro events in the window → violation (`missing retro`,
  name the ISO week where one is expected if you can infer it from the
  other).
- More than one retro in the same ISO week, or two retros in adjacent ISO
  weeks → violation.

**If the window holds no retro event at all**, the likely cause is a
rename, not a cancelled sprint (that is how the 2026-10-12 run went
wrong). Before reporting, run a second `list_events` over the same window
with `fullText: "Retro"` and look for an event that took the retro's slot.
Then report **one** line, `E: no "[Hospitality] Retro + Sizing" event in
the window`, naming any candidate rename (summary, dates, series id). In
that case do **not** also emit Rule A "missing standup" lines for Mondays:
without the anchor you cannot tell a retro day from a normal Monday.
Evaluate Rule A normally for Tuesday to Friday.

### Step 5 — Write the log

Append to `logs/hospitality-calendar-audit-<NOW>.md` (the file the
scheduler creates for this run). Be terse:

- If no violations: write a single line, `No rule violations in the next 28
  days. Audited N events.`
- If violations: list them one per line as `- <rule letter>: <description>`
  followed by the conversion table for only the events cited. Do not pad
  the output with summaries of compliant events.
- If Step 3.5 left any date unresolved, add a `Notes (unverified)` section
  after the violations listing each one. These are **not** violations: they
  do not affect `Severity:` and they do not count toward `<N>` in the
  notification. A run with zero violations and one unresolved date is still
  `Severity: ok` and still fires no notification.

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

### Hungarian work calendar — 2026 (pinned, authoritative for Step 3.5)

Source: nemzetgazdasági miniszter 10/2025. (NGM) rendelet, published in
Magyar Közlöny. Verified 2026-08-10. **Refresh this table once a year** —
a run whose window reaches past 2026-12-31 must follow Step 3.5's fallback
and say so in its log.

National public holidays (munkaszüneti napok):

| Date | Weekday | Holiday |
|---|---|---|
| 2026-01-01 | Thu | Újév / New Year's Day |
| 2026-03-15 | Sun | 1848 Revolution |
| 2026-04-03 | Fri | Nagypéntek / Good Friday |
| 2026-04-06 | Mon | Húsvéthétfő / Easter Monday |
| 2026-05-01 | Fri | A munka ünnepe / Labour Day |
| 2026-05-25 | Mon | Pünkösdhétfő / Whit Monday |
| 2026-08-20 | Thu | Szent István napja / St. Stephen's Day |
| 2026-10-23 | Fri | 1956 Revolution |
| 2026-11-01 | Sun | Mindenszentek / All Saints' Day |
| 2026-12-25 | Fri | Karácsony / Christmas Day |
| 2026-12-26 | Sat | Karácsony másnapja / Boxing Day |

Substitute rest days (áthelyezett pihenőnap) — equally **non-working** —
with the working Saturday each was traded against:

| Rest day | Weekday | Traded working Saturday |
|---|---|---|
| 2026-01-02 | Fri | 2026-01-10 |
| 2026-08-21 | Fri | 2026-08-08 |
| 2026-12-24 | Thu | 2026-12-12 |

The non-working set for Rules A and D is the **union of both tables**.
2026-08-21 is the entry that has already bitten this audit: it is not a
public holiday, so a run consulting only the first table wrongly flags the
missing 08-21 standup as a Rule A violation. The 2026-08-10 run did
exactly that; the 2026-08-03 run got it right only because it happened to
research the decree on its own. That divergence is why the table is
pinned.

### Task history

This task was migrated from an n8n workflow on 2026-05-11. The original
prompt was open-ended — these instructions tighten it for non-interactive
execution.

The audit is read-only (no PRE-AUTHORIZED actions needed) — it only calls
`list_events` and writes to the local log. Calendar write tools
(`create_event`, `update_event`) are NOT permitted by this task; if a
violation seems easy to auto-fix, still just report it.

Why these rules exist (scrum process as of 2026-10-12): HSP keeps only
two meetings. A daily standup, and a retro every second week extended with
an on-demand sizing session. The retro sits in the standup slot (Monday
11:00) and replaces that day's standup. Grooming (product and tech debt)
and sprint planning are gone. Violations usually mean someone moved a
meeting and broke the rhythm.

History:
- Until 2026-10-07 there was product grooming on the Thursday before
  planning (old Rule B).
- Until 2026-10-12 the anchor was `[Hospitality] Review + Retro + Planning`
  (13:00 on alternate Mondays), with Tech Debt Grooming on the Wednesday
  before it (old Rule C). The planning series was renamed to
  `[Hospitality] Retro + Sizing` (series `n8epse96duk51t5agtpsao1mko`) and
  moved into the standup slot.
