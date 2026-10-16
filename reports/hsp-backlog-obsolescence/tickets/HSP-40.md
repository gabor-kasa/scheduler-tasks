# HSP-40: Display warning if 'silent device' issue is detected

- **Verdict:** partial / different solution, product question
- **Label:** backlog-review-unclear
- **Confidence:** medium
- **Checked:** 2026-10-16, scheduled-task batch
- **Jira before write:** created 2023-07-20, updated 2026-01-05 (fix version bump only), no labels, repository field kontrol, parent KC-3833, status To Do. Relates to HSP-41 (Done), blocks HSP-47 (Done). A 2023-07-21 comment by Gabor says it "can be merged with" another ticket (the key did not survive in the export).

## Claim

If this ticket were done, the reservation access codes page in Kontrol would show the time since the last event received from
the device, and a warning when that is older than one day and the device should have been sending events.

## Evidence

- `kontrol-ui` @ origin/master `ea34ed10e`, reservation access codes page
  (`libs/kontrol-ui/pages/reservation-details/src/lib/reservation-access-codes/`): no "time since last event" widget and no
  silent-device warning found. The only "no events" text is a filtered-table empty state,
  `components/access-events-section.tsx:36-40`, "No events recorded for this device on this reservation in the selected range"
  (HSP-4028, `a5ce4a6f1`, 2026-08-05). That describes the filter result, not device health.
- A different mechanism covers the same worry on the reservations list: `kontrol-api` @ `845c5c84e`
  `service/app/components/check-in-issue/rules/lock-unresponsive.rule.ts:166,213` flags a lock with `noHealthSignal` as an
  issue (HSP-4222, `46006aed4`, 2026-09-11, #3109), and `kontrol-ui` has `lockUnresponsive` guidance copy
  (`libs/kontrol-ui/shared/utils/src/lib/reservations/check-in-issue-guidance.spec.ts:90`).
  I did not check whether that issue is also shown on the reservation details access codes page itself.
- The detection the ticket relies on (HSP-25) does not exist, see `HSP-18.md`.

## Note for review

Not implemented as written, but the intent (warn staff when a lock is silent for a stay) is met in part by the lockUnresponsive
check-in issue. Question for Adam: is that enough, or should the access codes page itself show last-event time and a warning?
Decide together with HSP-25, HSP-18 and HSP-17.
