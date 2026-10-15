# HSP-25: Detect Silent Devices in DeviceService

- **Verdict:** partial / different solution, product question
- **Label:** backlog-review-unclear
- **Confidence:** medium
- **Checked:** 2026-10-15, scheduled-task batch
- **Jira before write:** created 2023-07-17, updated 2026-01-05 (fix version bumps only), no labels, parent KC-3833, status To Do. Blocks HSP-23 (Done) and HSP-18 (To Do, "Create notification of devices not emitting events").

## Claim

If this ticket were done, `device-service` would have a function that returns `silentDevices[]` (unitId, unit title,
SmartThings account and lock name). It would pick SmartThings-configured units that should have had events (recent
successful CSS code job, closed BW task in 2 days, or an ongoing checked-in reservation) and have none.

## Evidence

- No such function: a search for silentDevices, silent device and not-emitting across all HSP repos finds only a comment
  in `device-service` @ origin/master `adfbc23`, `serverless.yml:287`.
- A different mechanism covers part of the goal:
  - `serverless.yml:285-296` `syncDeviceRoster` runs hourly (HSP-4032, `9ac437a`, 2026-10-01, #190) so
    "configured-but-silent devices show on the dashboard".
  - `data/models/Device.ts:157` `roster` plus `lastHealthEvent` absent means "configured at the vendor but never reported an
    event" (see the comment at lines 145-156). That is RemoteLock only ("RemoteLock device roster").
  - `functions/api/get-smartthings-health.ts:13,75` reports SmartThings status, code and battery issues per account, but
    I found no "has not emitted events although it should have" check.
  - The `kontrol-ui` device-dashboard (`libs/kontrol-ui/pages/device-dashboard`) shows these. I did not find a "silent" filter there.
- Not covered: the ticket's SmartThings-specific criteria (code job, BW task, checked-in stay) have no implementation.

## Note for review

This is neither built nor dead. The device dashboard and roster sync address "find misconfigured devices" a different
way, for RemoteLock. Question for Adam: does the dashboard replace this ticket, and should the linked HSP-18 (notification) be
reviewed with it? If SmartThings silent-device detection is still wanted, the ticket is open as written.
