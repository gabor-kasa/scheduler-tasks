# Email forwarder (Apps Script)

Forwards the email-forwarder rules from inside Google, hourly, under your own
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
   `forwardMatching` runs every hour.

A failed run (cap hit, label failure, Gmail error) emails you the stack trace
through Apps Script's default failure notifications.

## Changing a rule

Edit `RULES` here and in the editor, and keep `tasks/email-forwarder.md` in
sync while that task still exists.
