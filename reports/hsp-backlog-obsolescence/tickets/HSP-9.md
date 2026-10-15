# HSP-9: Email search is broken

- **Verdict:** superseded (by Giga Search)
- **Label:** backlog-review-obsolete
- **Confidence:** medium
- **Checked:** 2026-10-15, scheduled-task batch
- **Jira before write:** created 2023-07-14, updated 2023-09-25, no labels, no parent, Repository kontrol-api, status To Do. Comment 2023-08-28: "merge it into Giga Search roadmap item".

## Claim

If this were fixed, searching a full email like `peter@saat-network.ch` in Kontrol would match the guest with that exact
address instead of only matching the `peter` token. The only alternative named on the ticket is Giga Search.

## Evidence

- `kontrol-api` @ origin/master `845c5c84e`:
  - `service/app/components/reservation-v2/services/opensearch.reservation.index.ts:229-230` maps `guestEmail` with
    `email_ngram_analyzer` for indexing and `email_search_analyzer` for queries.
  - Same file `:630` and `:676-684`: both analyzers use the `whitespace` tokenizer with the `strip_special_except_at`
    char filter. The `@` stays in the token, so the email is not split into `peter` plus a domain.
  - `service/app/components/reservation-v2/services/reservation.search.service.ts:449` (`gigaSearchGuests`) queries
    `guestEmail` and `guestEmail.keyword^3`. `giga-search.controller.ts:25-28` runs four giga searches per request.
  - `kontrol-ui` @ `602bc67f1`, `libs/kontrol-ui/shared/redux/services/src/lib/kontrol-api/rest/endpoints/queries/search/search.ts:10`
    calls `giga-search`.
  - Dated by `git log -S email_ngram_analyzer`: `02ad4a227` (2026-02-25, HSP-3247, #2745) added guest search; the
    `strip_special_except_at` filter came with `b74d3c502` (2026-02-18, HSP-3187, #2739).

## Note for review

I read the analyzer config. I did not run a live query for `peter@saat-network.ch`, so behavior is inferred from the mapping.
The config addresses the exact cause in the report, and the ticket itself was folded into Giga Search in 2023. Confirm
with a quick search in Kontrol before closing if you want certainty.
