# HSP-18: Create notification of devices not emitting events

- **Verdict:** partial / different solution, product question (shared silent-device investigation for HSP-17, HSP-18, HSP-40, see also HSP-25)
- **Label:** backlog-review-unclear
- **Confidence:** medium
- **Checked:** 2026-10-16, scheduled-task batch
- **Jira before write:** created 2023-07-17, updated 2026-01-05 (fix version bump only), labels BackEndOnly, parent KC-3833, status To Do. Blocks HSP-17 (To Do) and HSP-25 (Done in Jira, but HSP-25 is `unclear` in this review).

## Claim

If this ticket were done, a scheduled job (the AC names "device-notification-service") would call a device-service
endpoint that lists devices not producing events, and post a log line plus a Slack message per unit to
`#tech-notifications-iot-cleanup`. What would make it moot: a different job that tells techops daily about problem devices.

## Evidence (shared for HSP-17, HSP-18, HSP-40)

- No detection of "silent" devices as the tech spec describes it (units that should have had events but have none):
  a search for silentDevice, silent device, not emitting and noEvents across all HSP-owned repos finds nothing relevant.
  `device-service` @ origin/master `33f6e95` has only `lastEventAt` bookkeeping (`data/models/Device.ts:144`) and the hourly
  roster sync described in `serverless.yml:299` ("so configured-but-silent devices show on the dashboard", HSP-4032).
- No repo named `device-notification-service` or `iot-cleanup` exists under kasadev (`gh repo view` returns not found for both).
- A daily Slack digest exists but is not the same thing and is switched off:
  - `device-service` `serverless.yml:281-291` `sendDeviceIssueDigest` ("Daily Slack digest of devices with new, still open and
    cleared code-health device issues", HSP-4408, commit `f1ea34d`, 2026-10-14, merged as #201 on 2026-10-16).
  - `SLACK_NOTIFICATIONS_ENABLED: false` at line 286, the `events:` schedule block is commented out (lines 288-291), and the
    comment at line 280 says "Disabled until we agree on the Slack channel".
  - `services/DeviceIssueDigest.ts:25-52` builds the digest from `codeHealth.issues` (code and lock configuration issues),
    not from missing events.
- A different mechanism covers silent locks for upcoming stays, not as a daily list:
  `kontrol-api` @ origin/master `845c5c84e`, `service/app/components/check-in-issue/rules/lock-unresponsive.rule.ts:20-33,166,213`
  (HSP-4222, commit `46006aed4`, 2026-09-11, #3109). A lock with no health signal is "detected" with reason `noHealthSignal`,
  and a vendor whose whole feed went quiet for 6h (`VENDOR_SILENCE_MS`, line 54) is judged "silent". `kontrol-ui` carries
  `lockUnresponsive` guidance copy (`libs/kontrol-ui/shared/utils/src/lib/reservations/check-in-issue-guidance.spec.ts:90`).
  I found no Slack or other notification in `check-in-issue/` (grep for slack/notify is empty).
- `kontrol-ui` @ `ea34ed10e` device dashboard (`libs/kontrol-ui/pages/device-dashboard/src/lib/components/devices-grid.tsx:201-217`)
  shows the last health event per device, so techops can find stale devices by looking, not by being told.

## Note for review

Not built as specified and not dead. The need "tell techops about problem devices daily" is partly met by three other things:
the device dashboard, the lockUnresponsive check-in issue, and the HSP-4408 digest. The digest is the closest fit for this
exact ticket (daily Slack list), but it is disabled and covers config issues, not missing events.
Question for Adam: is a daily "device not emitting events" Slack notification still wanted, or does the dashboard plus the
digest replace HSP-18, HSP-17 and HSP-40 (and HSP-25)? These four stand or fall together.
