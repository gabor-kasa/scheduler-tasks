# HSP-17: Roll out detection of devices not emitting events (silent devices)

- **Verdict:** partial / different solution, product question
- **Label:** backlog-review-unclear
- **Confidence:** medium
- **Checked:** 2026-10-16, scheduled-task batch
- **Jira before write:** created 2023-07-17, updated 2026-01-05 (fix version bump only), no labels, parent KC-3833, status To Do. Is blocked by HSP-18 (To Do).

## Claim

If this ticket were done, the silent-device detection would run on production, techops would get the actual list, and the
detection lambda would run daily once the list was manageable. That needs the detection itself (HSP-25), which does not exist
as specified.

## Evidence

Shared with HSP-18, see the Evidence section in `HSP-18.md`. In short, on `device-service` @ origin/master `33f6e95`:
no silent-device detection function exists, and the closest daily notification (`serverless.yml:281-291`
`sendDeviceIssueDigest`, HSP-4408) is disabled and reports code-health issues, not missing events.
This ticket is a rollout step of work that was never built in the form it describes.

## Note for review

Depends on HSP-25 and HSP-18. Same question for Adam as HSP-18: does the device dashboard (HSP-4032), the lockUnresponsive
check-in rule (HSP-4222) and the HSP-4408 digest replace the silent-device idea? If yes, close HSP-17, HSP-18, HSP-40 and
HSP-25 together. If a daily techops list of silent devices is still wanted, this ticket stays open as written.
