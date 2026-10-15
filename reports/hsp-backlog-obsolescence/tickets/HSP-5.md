# HSP-5: No-show monitoring, skip touch up clean for mid stay cancel/move

- **Verdict:** partial
- **Label:** backlog-review-unclear
- **Confidence:** medium
- **Checked:** 2026-10-15, scheduled-task batch
- **Jira before write:** created 2023-05-10, updated 2026-09-24 (description reformatted by Andrew Popov), no labels, no parent, status To Do, blocks KC-3892 (Done, "Fire doorOpened events when triggered from VFD/Kontrol")

## Claim

If this ticket were done, something would check each reservation 24 hours after plannedArrival. If there were no
guest door-code open, no VFD remote open, no Kontrol remote open and the Pre-Arrival Checklist (KBC) were incomplete, it
would set a "possible no-show" value on the reservation and sync it to Kustomer. The touch-up clean would be skipped for that guest.

## Evidence

- Exists, manual only:
  - `kontrol-api` @ origin/master `845c5c84e`, `service/app/components/reservation-v2/controllers/reservation.no-show.controller.ts:9`
    (`executeMarkAsNoShow`) sets `BookingFlag.NO_SHOW`. Routes at `reservation.routes.ts:153-154`
    (`PUT`/`DELETE /:id/booking-flags/no-show`). Staff trigger this by hand.
  - `kustomer-sync` @ origin/master `f0b54f0`, `utils/convertKustomerReservation.ts:92` syncs it as `noShowReservationBool`.
- Missing:
  - No automatic detector. Searches across all HSP repos for NO_SHOW, noShow and possible/suspected/potential no-show
    find only the manual controller, its UI and the Kustomer mapping. Nothing reads door-open events or KBC status to set the flag.
  - No touch-up skip. `breezeway-sync` @ origin/master `4c75e73` has no reference to `NO_SHOW` or `bookingFlags` under `functions/`.
    The only touch-up note is `functions/task-sync-handler/reservation-moved/reservation-moved-mid-stay-new-unit.ts:148`, which
    avoids a touch-up for a one-night remainder, unrelated to no-shows.
- Dependency is done: KC-3892 (doorOpened events from VFD/Kontrol) is Done, so the detection input exists.

## Note for review

The manual flag and Kustomer sync cover the "flag it and sync it" half of the ticket. The automation (24h detection) and
the touch-up skip are not built. Andrew Popov edited the description on 2026-09-24, so someone looked at it recently.
Questions for Adam: is the manual no-show flag enough, or is automatic detection plus the touch-up skip still wanted?
The "TBD flag" the AC mentions may be the existing `NO_SHOW` flag.
