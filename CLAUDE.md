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
`type` (`oneoff|recurring`), `schedule`, `next_run`, `last_run`, `created`,
`status`. The body has `## Instructions` (what the spawned Claude does when
the task fires) and usually `## Context`.

- Times are ISO 8601 with a local offset (`2026-05-12T08:00:00+02:00`),
  **not** UTC. Cron expressions in `schedule` are interpreted in local time.
- `schedule` accepts a 5-field cron expression or `every Nh|m|d|w`.
- Start from `TASK_TEMPLATE.md`; `EXAMPLE_TASK.md` has worked samples.

The app advances `last_run` / `next_run` / `status` itself after each run —
you don't hand-edit those except to reschedule.

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
