# HSP-92: Make the period/RT edit warning more explicit

- **Verdict:** not implemented
- **Label:** backlog-review-not-implemented
- **Confidence:** medium-high
- **Checked:** 2026-10-16, scheduled-task batch
- **Jira before write:** created 2023-08-03, updated 2026-01-05 (fix version bump only), label Designed, repository kontrol-ui, no parent, status To Do.

## Claim

If this ticket were done, the reservation editor would show two distinct warnings in the box that holds the dates and the
room type: "period AND room type can't be edited" and "period can't be edited but room type CAN be edited". The old generic
warning, which reads as if everything in the box is locked, would be gone.

## Evidence

- `kontrol-ui` @ origin/master `ea34ed10e`:
  - `libs/kontrol-ui/pages/reservation-creator/src/lib/components/drawer/widgets/components/date-range-select.tsx:73-75`
    still shows the single generic copy "These fields cannot be edited for this channel." for a non-editable 3rd-party source.
    Added by `53dd66b41` (KC-2319, 2023-06-22), never reworded. The file was last touched 2026-06-02 (`1771ff538`) for
    unrelated work.
  - `widgets/availability-widget.tsx:128-129` renders `<DateRangeSelect />` and `<RoomTypeSelect />` together, so the
    ticket's "same box" layout still exists.
  - `widgets/components/room-type-select.tsx:238-240` adds a separate message only when the user changes the room type:
    "Room type can only be changed free of charge for this source!". It does not state up front which fields are editable.
- Searched `reservation-creator` for edit/can't/cannot copy; no copy that separates "period locked, room type editable".
- The backend rules the copy should reflect still exist: `kontrol-api` @ `845c5c84e`
  `service/app/components/reservation-v2/services/reservation.3rdPartyEdit.validator.service.ts:84-168`
  allows `unitLocked` / `roomType` edits per source.

## Note for review

Nothing found on master that matches the requested copy. This only says it was not built. Whether it is still worth doing
is a product call (it is a copy change, and the `Designed` label means a design exists in Jira).
