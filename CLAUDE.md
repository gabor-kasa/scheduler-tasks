# Claude Scheduled Tasks — data folder guide

This file auto-loads when Claude Code runs in this folder — both the
non-interactive `claude -p` the scheduler spawns for each task, and any
interactive session you open here (the desktop app's "Edit with Claude"
button, or a terminal). It is **not** the guide for developing the app;
that lives in the app's separate source repo (its own `CLAUDE.md`).

## What this folder is

The **data folder** for the "Claude Scheduled Tasks" desktop app. The app
is the scheduler: it watches the files here, fires `claude -p` per task at
each task's `next_run`, writes a log per run, and advances the schedule.
Nothing else should drive these tasks — don't stand up a cron job or other
runner against them; it would race the app for the task files.

Layout:

- `tasks/<slug>.md` — one markdown file per scheduled task (YAML
  frontmatter + instructions). The source of truth for what runs and when.
- `logs/` — one log file per run. Generated output.
- `done/` — one-off tasks the app archives here after they fire.
- `TASK_TEMPLATE.md`, `EXAMPLE_TASK.md` — copy / reference when authoring a task.

## Version control

This folder is its own git repo, separate from the app's source repo.
**Task files are tracked here** — `tasks/` and `done/` are committed so the
schedule has history; only `logs/` (run output) and `.DS_Store` are ignored
(see `.gitignore`). So when you create or edit a task you're editing tracked
source, not a throwaway file. Do **not** treat task files as gitignored —
that was only true in the app's *build* repo, where these folders don't
exist. Leave commits to the user's normal git flow; the global
`~/.claude/CLAUDE.md` rules (branch, don't push to `master`) still apply.

## Task file format

YAML frontmatter + markdown body. Required frontmatter keys: `id`, `title`,
`type` (`oneoff|recurring`), `schedule`, `created`, `status`. `next_run` is an
optional first-fire **seed**; `last_run` is optional. The body has
`## Instructions` (what the spawned Claude does when the task fires) and usually
`## Context`.

- Times are ISO 8601 with a local offset (`2026-05-12T08:00:00+02:00`),
  **not** UTC. Cron expressions in `schedule` are interpreted in local time.
- `schedule` accepts a 5-field cron expression or `every Nh|m|d|w`.
- `model` / `effort` (both optional) pin the model and thinking level for
  this task's runs. `model` is any `claude --model` value (e.g.
  `claude-opus-4-8`); `effort` is `low|medium|high|xhigh|max`. Omit either to
  use the app default (`claude-sonnet-4-6`) / the model's default effort. The
  resolved model is recorded in each run-log header (`- **Model:**`). Heavy
  review/audit tasks pin `claude-opus-4-8` + `high`; simple digests can stay
  default or use `claude-haiku-4-5` to save cost.
- Start from `TASK_TEMPLATE.md`; `EXAMPLE_TASK.md` has worked samples.

The live `next_run` / `last_run` live in the gitignored
`logs/schedule-state.json` sidecar, **not** the task `.md` — that's what keeps
these version-controlled task files from churning on every run. The app
advances them there after each run; only `status` is written back into the
`.md` (and a same-value rewrite is content-identical, so it won't churn git).
The `.md` `next_run` is just the first-fire seed (read once, then the sidecar
owns it). To re-time a task's next fire, edit its entry in
`logs/schedule-state.json` (or delete the entry to fall back to the `.md`
seed) — editing the frontmatter `next_run` alone won't take effect once the
task has run. `status` you can still hand-edit (e.g. `paused`).

> Takes effect once the new app build ships (the running build may still write
> `next_run`/`last_run` into the `.md` until then). After it ships and each task
> has run once, the now-inert `next_run`/`last_run` lines can be stripped from
> the existing `tasks/*.md` in a one-time commit.

## What a run must produce (the contract)

When the scheduler fires a task it injects these rules into the prompt;
they're repeated here so an interactive session authoring a task knows the
shape it has to produce:

- The run appends its narrative to a log file in `logs/`, then an
  `## Outcome` block with:
  - **Status:** `success` | `failure` | `skipped`
  - **Severity:** `ok` (silent default) | `attention` (succeeded but the
    user should look — anomalies, items to triage) | `failure` (errored).
    The app surfaces `attention` (orange) and `failure` (red) in the run
    list; `ok` is silent. The task decides its own severity — no keyword
    sniffing.
  - **Finished:** ISO timestamp with local offset
  - **Summary:** 1–3 sentences
- Optional `## Notification` block (`title` required, `subtitle` optional,
  `body` required) to fire a native desktop banner beyond what `Severity:`
  surfaces. Tasks never shell out to a notifier — they only append this
  block and the app delivers it.

## Pre-authorized mutations

A scheduled run has **no user to approve actions**. If a task needs to
mutate shared state (Slack, GitHub PRs, production, etc.), that action must
be prefixed `PRE-AUTHORIZED:` in the task's `## Instructions` — otherwise
the run must refuse and record the reason in its `## Outcome` with
`Status: failure`. Design tasks to be read-only or to declare every
mutation as `PRE-AUTHORIZED:`.

## Adding a task

1. Copy `TASK_TEMPLATE.md` to `tasks/<slug>.md`.
2. Fill in the frontmatter; set `next_run` to the first fire time.
3. Write `## Instructions` for the spawned Claude — be explicit; no one is
   around to clarify. Declare any mutation as `PRE-AUTHORIZED:`.
4. Commit the new task file (it's tracked). The app picks it up within a
   few seconds (FSEvents, or a 3s polling backstop).

## Also applies

Follow `~/.claude/CLAUDE.md` (the user's global rules) for everything you do
here.
