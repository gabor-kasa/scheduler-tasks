# HSP backlog review

Open HSP tickets checked against code on master. The labels are on the tickets in Jira, and the reasoning is in `tickets/`.
Only positive evidence on master earns `backlog-review-obsolete`.

Jira filter: `labels in (backlog-review-obsolete, backlog-review-not-implemented, backlog-review-unclear)`

## backlog-review-obsolete (proposed for closing)

| Ticket | Summary | Verdict | Why |
|---|---|---|---|
| [HSP-579](tickets/HSP-579.md) | Add "Successfully Updated/Selected Card" verbiage to CCA Page | superseded | cc-auth retired 2026-06; kasa-app's new flow shows "Your card is authorized" after add and select |

## backlog-review-unclear (needs a product call)

| Ticket | Summary | Verdict | Why |
|---|---|---|---|
| [HSP-578](tickets/HSP-578.md) | Allow usage of archived Contentful entries for checkout page | unclear | Hiding is solved by `isListed`, but unlisted properties can't be booked manually either. Is that case still needed? |
| [HSP-521](tickets/HSP-521.md) | VFD Address card should navigate to building address instead of lat/lng | partial | The API has a building guest-facing address since 2026-03; no UI shows it, and the map still uses lat/lng |

## backlog-review-not-implemented

| Ticket | Summary | Verdict | Why |
|---|---|---|---|
| [HSP-286](tickets/HSP-286.md) | Display task acceptance status in calendar task details | not implemented | Panel shows assignee names only; the status is already in the API, so this is now a small UI change |
| [HSP-285](tickets/HSP-285.md) | CSS CodeAudit should handle custom codes with codeId references | not implemented | css-api code audit skips 'CU' codes by design; the 2022 counts need re-measuring |
| [HSP-282](tickets/HSP-282.md) | Display all 'complete' Guest profile result on the rez creation form | not implemented | Guest picker uses giga-search, capped at 5 |
