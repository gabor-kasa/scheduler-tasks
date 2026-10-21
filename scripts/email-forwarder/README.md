# Email forwarder (Apps Script)

Forwards the email-forwarder rules from inside Google, daily at 06:00, under your own
account. It exists because Claude's Gmail connector now requires approval for
each `forward` call, so the scheduled `claude -p` run can't send. The rules and
dedup labels match `tasks/email-forwarder.md`.

## Setup

1. Go to script.google.com while signed in as gabor@kasa.com and create a new project.
2. Project Settings: tick "Show appsscript.json manifest file in editor".
3. Paste `Code.gs` and `appsscript.json` from this folder over the defaults.
4. Run `dryRun` once. Approve the OAuth prompt. The execution log lists what
   each rule would forward. Nothing is sent.
5. If the list looks right, run `installTrigger` once. From then on
   `forwardMatching` runs once a day in the 06:00 hour.

A failed run (cap hit, label failure, Gmail error) emails you the stack trace
through Apps Script's default failure notifications.

Installed 2026-10-21 as project "Email forwarder" (`.clasp.json` holds its
id), with a daily 06:00 trigger on `forwardMatching`.

## Changing a rule

Edit `RULES` in `Code.gs`, then push from this folder:

```
npx -y @google/clasp@3.4.1 push -f
```

Keep `tasks/email-forwarder.md` in sync while that task still exists.
