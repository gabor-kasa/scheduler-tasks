# Claude Scheduled Tasks — Claude Code guide

This file is read when Claude Code is launched in this directory (e.g. via
the app's "Edit with Claude" toolbar button). It tells future Claude
sessions enough to make changes productively.

## What this project is

A personal automation system Gabor uses. The app is distributable: the
**data folder** that holds `tasks/`, `logs/`, and `done/` is a user
setting, *not* derived from where the app bundle lives. On first launch
the app prompts for a location (suggesting
`~/Documents/ClaudeScheduledTasks`); it's editable later in Settings.
Resolution lives in `SchedulerPaths.root` (`Helpers.swift`):
`SCHEDULER_ROOT` env var (tests / fixtures) → the configured `dataRoot`
in `state.json` → `suggestedDefault`. The repo source tree and the data
folder are independent — a clone is for building the app; the tasks it
runs live wherever the user pointed it. Two pieces, in the same git repo:

1. **The scheduler runtime** (config + data, in the chosen data folder):
   - `tasks/<slug>.md` — markdown task files with YAML frontmatter that
     specify schedule + instructions for what Claude should do when the
     task fires.
   - `logs/`, `done/` — per-run logs and archived one-off tasks.
   - `CRON_PROMPT.md` — historical/explanatory only. The orchestration
     logic it used to describe now lives in Swift (`TaskRunner.swift`).
     Each tick's spawned Claude sees only one task's instructions, not
     this file.

2. **The desktop app** (Swift / SwiftUI, in `app/`):
   menu-bar app that *both* drives the schedule and visualises results.
   - **Internal scheduler** (`InternalScheduler.swift`) — owns a Timer
     that fires at the exact minute of the earliest pending task's
     `next_run`, any hour, any day of the week. When no tasks are
     pending the scheduler idles — no periodic safety sweep needed,
     since the store nudges the scheduler whenever a task file
     changes. The store nudges the scheduler via
     `tasksDidChange()` whenever a task file is added/modified, so new
     work is picked up promptly. Each fire delegates to `TaskRunner`,
     which determines the due set in Swift, spawns `claude -p` per
     due task with a per-task prompt, advances `next_run` via
     `CronParser`, and moves one-off tasks to `done/`. Catches up
     after sleep via `NSWorkspace.didWakeNotification`.
   - **TaskRunner** (`TaskRunner.swift`) — orchestration code. Reads
     task files, pre-creates per-run log scaffolding, builds the
     per-task prompt, spawns `claude`, parses the resulting log's
     Outcome, and updates the task file's `last_run` / `next_run` /
     `status`. There is no longer a shell wrapper (`run.sh` is gone).
   - **CronParser** (`CronParser.swift`) — pure-Swift parser for
     5-field cron expressions and `every Nh|m|d|w` intervals. Used to
     compute the next fire after a successful recurring run.
   - **Login item** (`LoginItem.swift`) — registered via `SMAppService`
     so the app auto-launches at login. Without this, the scheduler
     stops firing when the user logs out.
   - **Viewer** — lists tasks, runs, logs; force-run buttons per task;
     dock-badge with unread count when window is open; menu-bar status
     icon always present.

The app *is* the scheduler daemon — no external job runner involved.
Both pieces deliberately stay simple — file-based state, no database,
no network beyond what individual tasks call out to via MCP.

## Folder layout (canonical)

Single project tree, git-ready:

```
<repo root>/                                 ← build source; clone anywhere
├── .gitignore                                excludes logs/, done/, tasks/*.md, build artifacts
├── CLAUDE.md                                 this file (auto-loads for CC; seeded into data folder)
├── README.md                                 system overview
├── CRON_PROMPT.md                            historical / explanatory — no longer fed to claude
├── TASK_TEMPLATE.md                          copy this for new tasks (seeded into data folder)
├── EXAMPLE_TASK.md                           worked samples (seeded into data folder)
├── tasks/                                    dev checkout's task files (.gitkeep tracked; *.md gitignored)
├── logs/                                     dev checkout's run logs (gitignored)
├── done/                                     dev checkout's archived one-offs (gitignored)
└── app/                                      desktop app — viewer + scheduler
    ├── Info.plist                            bundle metadata (LSUIElement=true)
    ├── build.sh                              swiftc + iconutil + codesign
    ├── make-icon.swift                       generates the .icns
    ├── Claude Scheduled Tasks.app            built bundle (gitignored)
    ├── README.md                             app-specific docs
    └── Sources/
        ├── App.swift                         @main entry, MenuBarExtra, Window scene
        ├── AppDelegate.swift                 activation policy toggle, login item registration
        ├── InternalScheduler.swift           Timer-driven scheduler; calls TaskRunner per fire
        ├── TaskRunner.swift                  orchestration: due queue, log scaffolding, spawn claude, advance frontmatter
        ├── CronParser.swift                  pure-Swift 5-field cron + 'every Nh|m|d|w' parser
        ├── LoginItem.swift                   SMAppService wrapper for auto-launch
        ├── ContentView.swift                 NavigationSplitView + toolbar + tab picker
        ├── LogDetailView.swift               runs tab detail pane
        ├── TaskDetailView.swift              tasks tab detail pane
        ├── SelectableMarkdownView.swift      shared markdown renderer
        ├── Notifier.swift                    native notifications wrapper
        ├── SettingsView.swift                preferences UI
        ├── Models.swift                      ScheduledTask, LogEntry, severity parsing
        ├── Store.swift                       polling + watchers + read tracking
        └── Helpers.swift                     paths, persistence, Terminal launch, dock badge

~/Library/Application Support/ClaudeScheduledTasks/    state.json (read hashes, terminal pref, dataRoot)
<data folder>/                                         user-chosen; default ~/Documents/ClaudeScheduledTasks
├── tasks/  logs/  done/                               the live scheduler data the app reads/writes
└── CLAUDE.md  TASK_TEMPLATE.md  EXAMPLE_TASK.md        seeded on first run for the claude that runs here
```

Two things to internalize:

- The whole tree is one git repo. The `app/` subfolder is
  *not* a separate project — it's the desktop app alongside the scheduler
  config and tasks.
- `logs/`, `done/`, `app/build/`, and `app/Claude Scheduled Tasks.app` are
  runtime/build artifacts — excluded by `.gitignore`. Everything else is
  versioned.

## Build & run

From the project root:

```bash
cd app
./build.sh                          # generates icon, compiles, signs, bundles
open "Claude Scheduled Tasks.app"   # launch
```

No Xcode required — pure `swiftc` + `iconutil` + `codesign` via the
command-line Swift toolchain. Build takes ~5 seconds.

After source changes, quit the running app before rebuilding:
```bash
osascript -e 'tell application "Claude Scheduled Tasks" to quit'
cd app && ./build.sh && open "Claude Scheduled Tasks.app"
```

## Window vs menu-bar behavior

`Info.plist` sets `LSUIElement = true`, so the app starts as an
*accessory* (menu-bar only, no dock icon). `Window(id: "main")` is a
singleton — opening it brings the existing one forward instead of
spawning duplicates.

`AppDelegate` listens for `NSWindow.didBecomeKeyNotification` and
`willCloseNotification` on the main window and toggles
`NSApp.activationPolicy`:

- Window visible → `.regular` (dock icon + unread badge appear)
- Window closed → `.accessory` (back to menu-bar-only, app keeps running)

`applicationShouldTerminateAfterLastWindowClosed` returns `false` so
closing the window never quits the app — only the menu-bar "Quit" item
(or `⌘Q`) terminates.

## Key conventions

### Task file format

YAML frontmatter + markdown body. Required keys: `id`, `title`, `type`
(`oneoff|recurring`), `schedule`, `next_run`, `last_run`, `created`,
`status`. Body has `## Instructions` (what Claude does when the task
fires) and usually `## Context`.

Times are ISO 8601 with local offset (`2026-05-12T08:00:00+02:00`),
**not** UTC. Cron expressions are interpreted in local time.

See `TASK_TEMPLATE.md` and `EXAMPLE_TASK.md` at the project root.

### Severity model (how the app surfaces "this needs attention")

Every log file's `## Outcome` section includes a `Severity:` field:

- `ok` — silent default
- `attention` — task succeeded but found something the user should see
  (orange triangle in the run list)
- `failure` — task errored (red octagon)

The task decides its own severity; the app reads it directly — **don't
add keyword sniffing**. See `Models.swift` → `parseSeverity`.

### Read tracking — by content hash

`state.json` stores a `Set<String>` of SHA256 hashes of read log files.
A log is unread iff its current hash isn't in the set. This means
**edits make a log re-appear as unread**, which is intentional.

Auto-mark fires after 1.5s of viewing a log in the detail pane. ⇧⌘U
marks all current logs read.

### Force-run flow

`SchedulerStore.forceRunTask(_:)` calls
`InternalScheduler.runNow(taskId:)`, which routes through
`TaskRunner.forceRun(taskId:)`. The runner finds the task by id and
runs it regardless of its `next_run` — no frontmatter rewriting
required, and no risk of pulling in other coincidentally-due tasks.

### Concurrent execution + per-task gating

Multiple tasks run in parallel. The scheduler does NOT have a global
"is anything running?" flag any more — it tracks the set of in-flight
task IDs:

- `TaskRunner.inFlightTaskIds: Set<String>` is the authoritative
  source. Mutations happen on the main actor.
- `InternalScheduler` mirrors that set into a `@Published
  inFlightTaskIds: Set<String>` via `onTaskStarted` / `onTaskFinished`
  callbacks so SwiftUI views re-render when tasks start or finish.
- Views gate per-task with `scheduler.isTaskRunning(id)` — a Run
  button stays enabled while *other* tasks are running, and a
  long-running task can no longer freeze the whole UI.
- Summary widgets (menu-bar dropdown, "N tasks running" labels) use
  `scheduler.isAnyTaskRunning` and `scheduler.inFlightTaskIds.count`.

The one-at-a-time-per-task-ID invariant is preserved: `runDueTasks`
filters in-flight IDs out of the due set, `runSingle` re-checks
`inFlightTaskIds` before inserting, and `forceRun` refuses re-entry
for the same id. Concurrent tasks with *different* ids run in a
`TaskGroup`; per-task completion fires an `onEachComplete` callback
so the store refreshes and the timer re-arms as each task finishes —
no waiting for the slowest one.

The Timer that drives `fire()` does NOT block on the resulting work.
`fire()` is sync — it stamps `lastFireDate` and kicks the awaited body
(`runBatchOrSingle`) off in a detached `Task` so the Timer can re-arm
immediately and the next minute's tick isn't lost. The in-flight set
updates after `fire()` returns, but both run on the main actor in
serial order, so the next `fire()` sees the updated state.

On app quit, `AppDelegate.applicationWillTerminate` calls
`scheduler.terminateAllInFlight()` which forwards to
`TaskRunner.terminateAllInFlight()` to SIGTERM every live claude
child. Otherwise the children would orphan and run to completion
with no parent.

### Live updates

`SchedulerStore` watches the `tasks/` and `logs/` directories
via `DispatchSource.makeFileSystemObjectSource` for instant refresh on
file add/delete/rename. A 3-second `Timer` polls as a backstop for
in-place edits (which don't change directory metadata, so FSEvents
misses them).

If you add another scheduler directory to watch, add it in
`installDirectoryWatchers()` in `Store.swift`.

### Sleep / wake catch-up

`InternalScheduler.start()` registers an observer for
`NSWorkspace.didWakeNotification`. On wake, if the scheduled fire time
has already passed, fire immediately; otherwise rebuild the Timer for
the same target (Timers can drift after the system sleeps).

## Gotchas

- **TCC / Documents access.** macOS prompts the user the first time
  the app reads from `~/Documents/`, `~/Desktop/`, or `~/Downloads/`.
  If the project lives inside any of those (e.g.
  `~/Documents/workspace/scheduler/`), the user gets one prompt at
  launch. The grant only *persists across rebuilds* when the bundle
  is signed with a stable identity — ad-hoc signing produces a fresh
  cdhash every build and TCC re-prompts each time. `build.sh` looks
  for a `Local Code Signing` self-signed cert in Keychain and falls
  back to ad-hoc with a warning if it's not there. Create the cert
  once via Keychain Access → Certificate Assistant → Create a
  Certificate → Self Signed Root, Code Signing. If a task needs to
  read files in *another* TCC-protected dir, grant Full Disk Access
  to the `claude` binary (find with `which claude` — typically
  `~/.local/bin/claude` or `/opt/homebrew/bin/claude`).
- **Path resolution.** `tasks/`/`logs/`/`done/` derive from
  `SchedulerPaths.root`, resolved fresh on each access (no cache —
  `state.json` is the source of truth, so a Settings change is picked up
  everywhere without cross-thread cache invalidation). Order:
  `SCHEDULER_ROOT` env var → configured `dataRoot` in `state.json` →
  `suggestedDefault` (`~/Documents/ClaudeScheduledTasks`). First launch
  (`dataRoot == nil`) triggers `AppDelegate.runFirstRunSetup`, which
  prompts, migrates any co-located dev checkout's data
  (`DataFolderSetup.migrateLegacyData`), and seeds `CLAUDE.md` + templates
  (`DataFolderSetup.seedTemplates`, sourced from the checkout or from the
  bundle's Resources). The spawned/interactive claude runs with
  `root` as its working directory, so the seeded `CLAUDE.md` auto-loads.
  Changing the folder in Settings is refused while any task is in flight
  (a running child's cwd + log path are bound to the old folder).
- **Login item registration.** `LoginItem.register()` may trigger a
  macOS notification asking the user to enable the login item in
  System Settings → General → Login Items. First-run only.
- **`claude -p` stdin vs argv.** Passing the prompt as a positional CLI
  arg silently produces no output in some Claude CLI versions.
  `TaskRunner.spawnClaude` writes the per-task prompt to claude's
  stdin and closes the pipe — that's intentional.
- **Notifications need permission.** The app uses the native
  `UserNotifications` framework (`UNUserNotificationCenter`); banners
  fire under the app's own bundle identifier and icon. On first launch
  macOS prompts for alert + sound permission — without it banners are
  silently dropped. The entry appears in System Settings → Notifications
  under "Claude Scheduled Tasks" after the first attempt.
  Tasks declare notifications by appending a `## Notification` block
  to their log file (the contract is described in
  `TaskRunner.buildPrompt`); they never invoke any shell command. The
  repo previously used `terminal-notifier` for the same purpose —
  that dependency is gone.

## Adding a new task (workflow)

1. Copy `TASK_TEMPLATE.md` to `tasks/<slug>.md`.
2. Fill in frontmatter — set `next_run` to when you want the first fire.
3. Write `## Instructions` for the spawned Claude. Be explicit; no user
   is around to clarify. The runner injects the conventions Claude
   still has to follow (where to append, what the Outcome block looks
   like, severity values, optional `## Notification` block).
4. If the task mutates shared state (Slack, PRs, prod), prefix the
   action in instructions with `PRE-AUTHORIZED:` — otherwise the run
   will refuse.
5. The app picks up the new task within ~150ms (FSEvents) or 3s
   (polling backstop).

For destructive operations the spawned Claude lacks a way to ask the
user — design tasks to either be read-only or to declare every
mutation as `PRE-AUTHORIZED:` in the body.

## Adding a feature to the app

- UI changes → `ContentView.swift`, `LogDetailView.swift`,
  `TaskDetailView.swift`. Markdown rendering is shared in
  `SelectableMarkdownView.swift`. Menu-bar dropdown contents live in
  `App.swift` (`MenuBarMenu`).
- Data parsing → `Models.swift` (`ScheduledTask`, `LogEntry`,
  frontmatter parser, severity parser).
- Scheduler timing / fire dispatch → `InternalScheduler.swift`.
- Per-task orchestration (due-queue, log scaffolding, prompt
  construction, `claude -p` spawn, frontmatter advancement) →
  `TaskRunner.swift`. Edit `buildPrompt` to change what Claude sees.
- Cron / interval parsing → `CronParser.swift`. Add new schedule
  forms here (e.g. day-name aliases) and extend the test stubs in
  the worktree before shipping.
- App lifecycle, dock icon toggle, login item registration →
  `AppDelegate.swift`.
- File watching, persistence, force-run mechanics → `Store.swift`.
- Paths, persistence, Terminal launch, dock badge → `Helpers.swift`.

The store is the single source of truth for tasks + logs; the
scheduler is the single source of truth for run state. Views observe
both via `@EnvironmentObject`. Side-effecting actions go through
methods on `SchedulerStore` (`forceRunTask`, `markRead`, `deleteLog`)
or `InternalScheduler` (`runNow`, `start`, `stop`). Don't reach into
the filesystem from views.

## Don't

- Don't introduce an external job runner alongside the app. The app
  is the scheduler — anything else spawning `claude -p` against this
  tree's tasks would race for the task files.
- Don't change the bundle identifier or label without also updating
  the `SMAppService` login item registration and the state file
  location.
- Don't introduce a database or background daemon for read state —
  `state.json` is plenty.
- Don't poll more aggressively than 1s — the FSEvents watcher handles
  most urgent updates already.
- Don't put scheduling logic back into the prompt fed to `claude -p`.
  The whole point of the in-Swift orchestration is that zero-due
  ticks cost zero tokens. New conventions (severity values,
  notification block fields, etc.) belong in
  `TaskRunner.buildPrompt`, not in a side prompt file.
- Don't add features the user didn't ask for. The user has been
  driving this incrementally; keep changes scoped.
