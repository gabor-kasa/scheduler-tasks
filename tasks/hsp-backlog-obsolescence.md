---
id: hsp-backlog-obsolescence
icon: tray.full
title: HSP backlog obsolescence review
type: recurring
model: claude-sonnet-5-5
effort: high
schedule: "0 9-17/2 * * 1-5"
next_run: 2026-10-16T09:00:00+02:00
last_run: null
created: 2026-10-15T17:00:00+02:00
status: paused
---

## Instructions

Check the next batch of open HSP tickets against code on master. For each one, decide whether it is already
implemented, superseded by a different solution, or still open. Record the reasoning locally and put exactly
one review label on the ticket. Adam (Product Lead) uses the labels to decide closures. This task never closes anything.

PRE-AUTHORIZED: on HSP tickets in scope, add exactly one label from `backlog-review-obsolete`,
`backlog-review-not-implemented`, `backlog-review-unclear`, using
`PUT /rest/api/3/issue/<KEY>?notifyUsers=false` with `{"update":{"labels":[{"add":"<label>"}]}}`.
Nothing else in Jira: no comments, no transitions, no field edits, no label removals.
If a label PUT fails, record the failure in the ledger and do not retry with notifications on.

Jira access goes through the `shared-kasa-jira` skill's auth (`source ~/.claude/skills/shared-kasa-jira/scripts/auth.sh`).
`$AUTH` is the bare base64 value, so the header is `Authorization: Basic $AUTH`. Without "Basic", Jira answers
"Issue does not exist" rather than an auth error. Never use an Atlassian MCP tool.

### 1. Pick the batch

The scope query, re-run every time:

```
project = HSP AND statusCategory != Done AND issuetype != "Tech Debt"
AND (sprint = 543 OR sprint is EMPTY) AND issuetype != Epic
AND (labels is EMPTY OR labels not in (backlog-review-obsolete, backlog-review-not-implemented, backlog-review-unclear))
ORDER BY created ASC
```

Sprint 543 is "Hospitality Incoming Items". `sprint is EMPTY` is the board backlog. Epics are excluded here and
handled in step 4. Take the first **5** tickets. Also skip any key already in `ledger.jsonl` (a failed label write leaves no label).

If the query returns nothing and there are no unchecked epics, the review is complete. Write the Outcome with
Severity `attention`, add a Notification "HSP backlog review complete", and stop.

### 2. Read each ticket

Fetch the summary, description, all comments, labels, `created`, `updated`, issue links with their status, the
Repository field (`customfield_10144`) and the parent. Record `updated` **before** labelling, because the label
write overwrites it.

### 3. Check each ticket against code

Repos in scope are the HSP-owned ones in `reports/hsp-backlog-obsolescence/default-branches.tsv` (from
`own_list`, CODEOWNERS). Never read working trees. Your clones may be on feature branches or have local edits.

1. **Write the claim.** What would exist on master if this were done: an endpoint, a field, a component, a
   job, a flag, or a piece of copy. What alternative would make it moot.
2. **Search with `scripts/hsp-grep.sh`.** Pass `-f` on the first search of the run so it fetches. Use `REPOS="a b"` to
   narrow. It greps `origin/<default>` and prefixes each line with the repo name. Do not hand-roll
   `git grep ... -- <path>` with the ref after `--`: git then treats the ref as a path and greps the working tree.
3. **Search for the behavior, not only the names in the tech spec.** Missing field names prove nothing. HSP-578's
   three Contentful flags never existed, and the same need was met by an `isListed` DB flag.
4. **Read the actual code path** (the UI component or the endpoint handler) with `git show origin/<default>:<path>`
   before giving a verdict. Keyword hits are often a different domain. "assignment status" first matched payment
   allocation code, not Breezeway tasks.
5. **Check whether the target app is still live.** Read the repo's last few commits on `origin/<default>`.
   HSP-579 targeted cc-auth, which has redirected to kasa-app since 2026-06-24. The right question is whether
   the replacement has the problem.
6. **Follow the data across the stack.** Backend done and frontend missing is common (HSP-286, HSP-521). That is
   `partial`, not `implemented`.
7. **Date what you found** with `git log -S <identifier> origin/<default>`. Record the commit, the date and the PR number.
8. Directory layouts differ per repo (kontrol-api is `service/app`, not `src`). Search the whole repo first, then narrow.
   Start broad searches with `-l` (file names only) plus path globs. A full-content broad grep ran to 220KB once.
9. **If the ticket names a repo outside `default-branches.tsv`** (for example airbnb-sync or airbnb-api), check
   `gh repo view kasadev/<repo> --json isArchived,pushedAt` first. An archived repo or a disabled service is
   strong superseded evidence (HSP-224). Read its files with `gh api repos/kasadev/<repo>/contents/<path>?ref=<branch>`.
10. **Tickets from one feature** (siblings under one parent, such as HSP-277 to 281) may share one investigation.
    Each ticket still gets its own file and verdict, but the files may point to a shared section in the first one.
11. Check what the ticket's own comments decided. A comment like "merge it into Giga Search" (HSP-9) tells you
    where to look for the replacement.

### 4. Epics

An epic gets `backlog-review-obsolete` if all of its children are Done or already labelled
`backlog-review-obsolete`. Otherwise it gets `backlog-review-unclear`. No code reading. Process epics only after the
non-epic query returns nothing.

### 5. Verdict to label

| Verdict | Label | Requires |
|---|---|---|
| implemented | backlog-review-obsolete | `repo@sha:file:line` showing the behavior on master |
| superseded | backlog-review-obsolete | evidence of the replacement, and that it solves the ticket's problem |
| duplicate | backlog-review-obsolete | the closed ticket key, plus code evidence |
| not implemented | backlog-review-not-implemented | the places you searched and read |
| partial | backlog-review-unclear | what exists and what is missing |
| product question / can't tell | backlog-review-unclear | the question Adam needs to answer |

The hard rule is that only positive evidence earns `obsolete`. "I didn't find it" is `not-implemented`, never `obsolete`.

### 6. Record

For each ticket, write `reports/hsp-backlog-obsolescence/tickets/<KEY>.md` in the format of the existing ones:
verdict, label, confidence, checked date, Jira state before the write, Claim, Evidence (`repo` @ short SHA with
`path:line`), and Note for review. Append one JSON line to `ledger.jsonl` (`key`, `verdict`, `label`, `confidence`, `jira_updated_before`, `checked`,
`evidence[]`, `by`). Then apply the label, read it back, and add `label_put_http` and `label_readback` to the line.
Then run `python3 -I scripts/hsp-review-gen.py` to regenerate `REVIEW.md`. Never edit `REVIEW.md` by hand. Human
verdicts (`human_verdict`) and verifications (`verified_by`) are separate ledger lines, and the generator applies them.

Commit `reports/hsp-backlog-obsolescence/` to this repo's master (this folder's own rule). Don't push.

### 7. Outcome

- Severity `attention` if the batch added any `backlog-review-obsolete`. Otherwise `ok`.
- In the Summary, give counts per label for this batch and in total, plus the remaining scope count.

## Context

- Requested by Adam Kiss (Product Lead): find HSP backlog tickets that are already implemented or will never be
  done because we solved it another way. Gabor agreed the plan on 2026-10-15. Labels hold the result, and
  the reasoning stays local. No Jira comments.
- Scope on 2026-10-15: 257 open HSP tickets (backlog plus Incoming Items) excluding Tech Debt, 47 of them epics.
  The 61 sprintless HSP epics hidden from the board backlog view are in the query above via `sprint is EMPTY`.
  Confirm with Gabor whether those are wanted.
- Pilot (by hand, 2026-10-15), 6 tickets: HSP-286 not-implemented, HSP-285 not-implemented, HSP-578 unclear,
  HSP-282 not-implemented, HSP-579 obsolete (superseded), HSP-521 unclear (partial). Each took about 8 to 15 tool
  calls. That is why the batch is 5.
- Gabor's verdicts on the pilot (2026-10-15), also logged in `ledger.jsonl` as `human_verdict` lines:
  HSP-579 obsolete (agrees), HSP-285 obsolete (the code check said not-implemented), HSP-578 obsolete (the code
  check said unclear; product call), HSP-286 unclear (the code check said not-implemented), HSP-521 pending Adam
  (90% obsolete). So far, code agreed outright on 1 of 5. `not-implemented` only means nothing was found on
  master. It does not mean the ticket is still wanted, and Adam still has to review those tickets.
- `kontrol-ui-device-dashboard-nav` is a second clone of kontrol-ui and `access-review` has no remote. Both are
  marked `no-remote` in `default-branches.tsv` and skipped.
- ctf-netlify-deploy-app's default branch is `dev`. Always take the default from the tsv, never assume `master`.
