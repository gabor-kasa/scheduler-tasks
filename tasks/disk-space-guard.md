---
id: disk-space-guard
icon: internaldrive
title: Disk space guard — catch silent app kills before they bite
type: recurring
model: claude-haiku-4-5
effort: low
schedule: "0 9,17 * * *"
created: 2026-08-11T17:29:27+02:00
status: active
---

## Instructions

Check whether this Mac is close enough to full that macOS has started
silently killing applications, and warn before that happens again.

**This task is strictly read-only.** Never delete, move, truncate, or
modify any file, and never run `rm`, `brew cleanup`, `simctl delete`, or
any other reclaim command. Report what *should* be cleared and let the
user decide. A run that deletes something has failed even if it freed
space.

Keep healthy runs cheap, but never skip the baseline. Step 1 always
records one and reads the delta, Steps 2 and 2.5 are three shell commands,
and Step 3 exits early when everything is fine and nothing unexplained
moved. Only reach Step 4 when there is something to report.

### Step 1 — Record the baseline, then measure

Run the collector first, on every run, healthy or not:

```bash
scripts/disk-baseline.sh snapshot
scripts/disk-baseline.sh diff
```

`snapshot` appends one measurement block to `logs/disk-baseline.tsv`: used
and free for every mounted volume, APFS container free, swap, the APFS
snapshot count, and a per-directory size sweep. `diff` prints what moved
since the previous run, which directories moved it, and how much of the
change nothing accounts for.

The `diff` output is the primary material for this task. Quote its
headline figures and its top movers in the report even when the verdict is
healthy. A run that says only "30 GB free, all good" is the failure this
rewrite exists to fix: on 2026-09-12 the machine gave back 13 GB between
two runs, and no later investigation could say where it came from, because
no run had recorded a baseline to subtract from.

The volatile sweep (caches, containers, application support) costs about
35 seconds. Once a day the collector also sweeps the static trees (the
whole home directory and `/Applications`), which is slower; it decides
that for itself from a stamp file, so call it plainly and let it choose.
Pass `--full` only when the diff says the static trees are stale and the
answer depends on them.

Then take the headline numbers the rest of the steps use:

```bash
df -k /System/Volumes/Data | awk 'NR==2{printf "free_gb=%.1f used_gb=%.1f capacity=%s\n", $4/1048576, $3/1048576, $5}'
```

Use `df`, not Finder or `diskutil`. Finder's "Available" figure includes
*purgeable* space and reads far more generously than reality — that
discrepancy is exactly what made this problem hard to spot the first
time.

Also record swap, which competes for the same volume and grows silently
under memory pressure:

```bash
sysctl vm.swapusage
```

**Watch the whole container, not just the Data volume.** Every APFS volume
in the container draws on one shared pool of free space, so swap files
growing on `/System/Volumes/VM` shrink Data's free space without anything
under `~` changing size. Measured on 2026-09-13: swap total went from
7168 MB to 9216 MB in a day and the VM volume held 8.6 GB. The collector
records every volume for this reason. When Data's used size barely moved
but free space fell, read the other volumes and swap before hunting for a
directory that grew.

If either command fails, set `Status: failure` / `Severity: failure` and
log the error. Do not guess at numbers.

### Step 2 — Check whether macOS has already killed anything

This is the real harm signal, and it matters more than the threshold.
When free space gets tight, `cache_delete` terminates apps via
RunningBoard to reclaim their container caches. Those kills produce **no
crash report** (`reportType:None`), no dialog, and no notification — the
app just vanishes. Exit code is `0xBADDD15C`.

```bash
/usr/bin/log show --last 12h --style compact \
  --predicate 'eventMessage CONTAINS "CacheDeleteAppContainerCaches"' 2>/dev/null \
  | grep -oE 'termination assertion for [a-zA-Z0-9._-]+' \
  | sed 's/termination assertion for //' | sort | uniq -c | sort -rn
```

**Use the absolute path `/usr/bin/log`.** Bare `log` is a zsh builtin and
fails with "too many arguments" — a bare `log show` in this task will
silently produce nothing and make a sick machine look healthy.

Expect Apple's own background agents (`com.apple.weather`,
`wallpaper.agent`, widget and intent extensions) to dominate the list when
the machine is under pressure; they get killed and relaunched routinely.
What matters is **user-facing apps** in that list — anything the user
actually relies on. Treat these as significant if present:

- VPN / networking: `io.tailscale.ipn.macos`
- Anything the user works in: editors, browsers, Docker, Slack, terminals
- Menu-bar utilities: `leits.MeetingBar` and similar

A user-facing app appearing here means the machine is *already* losing
work silently, regardless of how much free space Step 1 reported.

### Step 2.5 — Check for self-inflicted waste

Two failure modes waste space silently and are worth reporting **regardless
of how much free space Step 1 found**, because both are defects rather than
just growth. Two cheap commands.

**Crash-looping launch agents.** A LaunchAgent whose program no longer
exists still gets respawned forever by `launchd` when `KeepAlive` is set,
appending a stack trace to its error log on every attempt.

```bash
launchctl list 2>/dev/null | awk 'NR==1 || ($1=="-" && $2!="0" && $3!~/^com\.apple/)'
```

Read the columns as `PID  Status  Label`. Interpretation matters:

- `Status` of `-9` means the process was SIGKILLed — under disk or memory
  pressure this is normal for Apple background agents, and they are
  **victims, not defects**. Ignore Apple-prefixed labels; the `awk` filter
  above already excludes them.
- A **non-Apple** label with a small non-zero status (commonly `1`) is a
  program failing on its own merits. That is the real signal.

For any hit, identify the plist under `~/Library/LaunchAgents/` and read
its `ProgramArguments`, then check whether that path actually exists. If it
does not, the agent is a zombie: it can never start, and `launchd` will
retry every ~10 seconds indefinitely.

**Runaway logs.**

```bash
find ~/Library/Logs ~/.[a-z]* -maxdepth 3 -type f -name "*.log" -size +200M 2>/dev/null -exec ls -lh {} \; | awk '{print $5, $9}'
```

A log past 200 MB is almost never healthy volume — it usually means
something is erroring in a loop. Report the size and the last few lines so
the cause is visible, and pair it with the crash-loop result above; they
are frequently the same incident seen from two angles.

**Never recommend truncating a runaway log on its own.** If a crash loop is
producing it, the file regenerates and the actual defect survives. Always
name the agent to stop first, then the log to delete, in that order.

### Step 3 — Classify, and exit early if healthy

Thresholds, calibrated on this machine (a ~494 GB volume where kills began
at roughly 12 GB free):

| Free space | Kills of user-facing apps | Verdict |
| --- | --- | --- |
| ≥ 25 GB | none | **healthy** |
| ≥ 25 GB | any | **degraded** |
| 15–25 GB | any or none | **degraded** |
| < 15 GB | any or none | **critical** |

Step 2.5 overrides a healthy disk verdict. If it found a crash-looping
non-Apple agent or a log over 200 MB, the run is **degraded** no matter how
much space is free — those are defects that will keep consuming disk until
someone intervenes.

**Unattributed movement overrides a healthy verdict.** If Step 1's diff
reports `UNATTRIBUTED` at 5 GB or more in either direction, the run is
**degraded** whatever the free space says. Something is moving GB-scale
data that no measured directory accounts for, and catching that is the
whole point of the baseline. The 5 GB figure is a guess, not a calibrated
threshold; once a few weeks of baselines exist, tune it to what normal
drift on this machine actually looks like.

If the verdict is **healthy**, Step 2.5 found nothing, and unattributed
movement is under 5 GB, stop here. Write a short `## Report` holding the
one-line summary plus Step 1's headline figures and its top three movers,
set `Status: success` / `Severity: ok`, add **no** `## Notification` block,
and finish. Do not run Step 4 — no point spending tokens or disk I/O on a
machine that is fine.

Otherwise continue. If the *only* finding is from Step 2.5 and free space
is comfortable, skip the `du` sweep in Step 4 — the consumer breakdown is
noise when the disk is fine — and report just the defect.

### Step 4 — Find what to clear (degraded / critical only)

Identify the biggest consumers so the report is actionable. Keep these
depth-limited; do not `du` the whole home directory.

```bash
du -sh ~/Library/Application\ Support/* 2>/dev/null | sort -rh | head -8
du -sh ~/Library/Caches/* 2>/dev/null | sort -rh | head -8
du -sh ~/Library/Containers/* 2>/dev/null | sort -rh | head -5
du -sh ~/Library/Developer/Xcode/DerivedData /Library/Developer/CoreSimulator 2>/dev/null
```

Known traps when estimating how much a candidate would actually free. Each
of these produced a wrong number the first time this was investigated, so
check them before quoting a figure:

- **Mounted disk images double-count.** Anything under
  `/Library/Developer/CoreSimulator/Volumes` is a *mounted view* of a
  compressed image, not additional space. Cross-check with
  `df -h | grep -i coresimulator` and treat the backing file as the real
  size.
- **Sparse files report a fantasy size.** `find -size` and `stat -f %z`
  give the *logical* size; `du` gives blocks actually allocated. For
  `~/Library/Containers/com.docker.docker/…/Docker.raw` these differ by
  20 GB. Always quote the `du` number.
- **`du -xhd1 /` double-counts via firmlinks.** It reports `/System` as
  hundreds of GB and totals more than the volume holds, because
  `/System/Volumes/Data` re-contains `/Users`. Trust
  `df -k /System/Volumes/Data` for the total and use per-directory `du`
  only for the breakdown.
- **SIP-restricted paths cannot be deleted, even with `sudo`.** Anything
  showing the `restricted` flag under `ls -lO` is off limits;
  `/System/Library/AssetsV2` is the common case. Never recommend
  `sudo rm -rf` on one — it fails with "Operation not permitted" and wastes
  the user's time. Simulator platform assets are removed from
  **Xcode → Settings → Platforms**, which holds the required entitlement.
- **Deleting an Xcode simulator runtime leaves its download behind.**
  `xcrun simctl runtime delete` deletes the associated asset by default
  (`--keep-asset` opts out), but once the runtime is gone there is no
  identifier left to retry against and the asset is stranded. Check
  `du -sh /System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime`
  and report it as GUI-only cleanup, not a command.

Also compare against prior runs to show direction of travel. List
`logs/disk-space-guard-*.md` (excluding the file being written), take the
3 most recent, extract their reported `Free:` figures, and state whether
free space is trending down, flat, or recovering. If there are no prior
logs, say "no prior baseline" and skip the trend.

### Step 5 — Write the report

Under `## Report`, include:

- **Verdict** — healthy / degraded / critical, with free GB and capacity %
- **What moved** — from Step 1's diff: Data volume used, container free,
  swap, the unattributed figure, and the top movers with their sizes.
  Include this on every run, healthy or not. It is the only part of the
  report that can answer "what is eating my free space", so it is not
  optional and it is not conditional on the verdict.
- **Swap** — total and used, flagged if free swap is under ~1 GB
- **Kills** — the user-facing apps killed in the last 12h with counts, or
  "none". Mention Apple background agents only as an aggregate count.
- **Defects** — crash-looping agents and runaway logs from Step 2.5, or
  "none". For each crash loop give the label, the missing program path, and
  the fix in order (`launchctl bootout gui/$(id -u)/<label>`, then remove
  the plist, then delete the log). For each runaway log give its size and
  the last few lines.
- **Trend** — free space across the last 3 runs, or "no prior baseline"
- **Top consumers** — the `du` results, largest first
- **Recommended reclaim** — concrete candidates with realistic sizes,
  cheapest-and-safest first. Never present a command as already run.

Set `Status: success` when the check completed, even if the verdict is
critical — `Status`/`Severity: failure` is for *the check itself* failing
(a command errored, output unparseable), not for the disk being full. A
full disk is `Severity: attention`.

Append a `## Notification` block **only** when the verdict is degraded or
critical:

```
## Notification

- title: Disk space low
- subtitle: <N> GB free, <M>% capacity
- body: <the single most useful sentence — what got killed, or what to clear>
- sound: default
```

## Context

Written 2026-08-11 after MeetingBar appeared to be "crashing repeatedly"
with no crash logs. It was not crashing. `cache_delete` had killed it 9
times in 24 hours to reclaim disk space, on a volume sitting at 98%
capacity with 12.4 GB free. In the same window it also killed Tailscale
and System Settings, plus hundreds of Apple background agents.

The whole point of this task is that **this failure mode is invisible**:

- No crash report is written (`reportType:None` suppresses it)
- No dialog, no notification, no log the user would think to check
- Finder reports plenty of free space, because it counts purgeable
- The app simply isn't running any more

So the symptom presents as "app X is flaky" and sends you looking at app X,
which is the wrong place entirely. Catching the *disk* condition on a
schedule is the only reliable way to get ahead of it.

Verified facts about the mechanism, for whoever reads a future run:

- Terminating process: `cache_delete`, via `runningboardd`
- Exit reason: `OS_REASON_RUNNINGBOARD`, code `0xBADDD15C`
- Log explanation string: `CacheDeleteAppContainerCaches requesting
  termination assertion for <bundle-id>`
- Menu-bar / `LSUIElement` apps are killed first — they carry
  `maxTerminationResistance:NonInteractive`, so they are the cheapest
  thing for the system to sacrifice

Structural background, measured 2026-08-11 against 409.7 GB used on a
460 GB volume. Two separate things, and conflating them sends you the wrong
way:

- **What is big** — 92 GB in `~/Documents/archives/Amazon Photos Downloads`
  (a local copy of cloud data, last touched March), ~92 GB in
  `~/Library`, and roughly 150 GB of development footprint across
  `~/Documents/workspace`, `~/worktrees` (25 GB of it `node_modules`),
  `~/.nvm`, and `~/.npm`. This is the chronic baseline that leaves no
  headroom.
- **What recently changed** — only ~8 GB, mostly a Claude VM bundle written
  on Aug 10. On a machine with normal headroom that would have gone
  unnoticed; on this one it crossed the kill threshold.

So report both when the disk is tight: the standing hogs *and* what moved
recently. A run that only lists the biggest directories cannot explain why
today is worse than last week.

The Step 2.5 checks exist because of a concrete case found the same day.
`~/.clawdbot/logs/gateway.err.log` had reached 796 MB and was still
growing, while no clawdbot process was running and the package was not
installed under any of the ten node versions present. The
`com.clawdbot.gateway` LaunchAgent was still loaded with `KeepAlive: true`,
pointing at a `dist/entry.js` that no longer existed, so `launchd`
respawned `node` every ~10 seconds, and every attempt appended a
`MODULE_NOT_FOUND` stack trace. The log held **1,063,328** crash traces,
implying roughly 120 days of continuous looping. Truncating the log would
have reclaimed the space and left it regenerating at ~6 MB/day forever;
the fix was to `bootout` the agent first. Note also that this cost CPU and
battery around the clock, so it is worth reporting even when disk is fine.

### Why the baseline was added (2026-09-13)

Between the 2026-09-12 09:00 and 17:02 runs the machine went from 19.8 GB
free to 29.7 GB and `used` fell 12.9 GB. Nothing could explain it
afterwards. Ruled out, each one measured:

- None of the six reclaim candidates the runs kept recommending had been
  cleared. Homebrew cache, DerivedData, Spotify, VS Code ShipIt, Codex and
  TypeScript were byte-identical a day later, so nobody ran the cleanups.
- No shell commands ran in that window. `~/.histfile` has extended history
  on and holds nothing between Sep 11 19:08 and Sep 12 20:40.
- No Claude Code session ran either, apart from the two scheduled runs.
- Nothing was trashed. `~/.Trash` was 0 B with an mtime from the day before.
- The two `cache_delete` purge attempts at 14:46 and 15:06 freed nothing.
  Purgeable went from 4,245,790,720 to 4,245,819,392 bytes, up 28 KB, and
  the daemon logged `no purges queued`.
- Time Machine could not have thinned snapshots, because Time Machine is
  broken here. Its only destination is named "Macintosh HD" with
  `Kind: Local`, and `backupd` resolves it to `/` then fails with `Alias
  resolved to a volume mounted at '/' which is an APFS volume but not a
  Time Machine volume`. Worth fixing on its own account: this Mac has no
  working backup.

So 12.9 GB moved and the cause is still unknown. That is a reporting
defect rather than a mystery. The task recorded per-directory sizes only
once it was already degraded, so every healthy run left nothing to
subtract from. Hence the Step 1 baseline, and hence `UNATTRIBUTED`, which
exists so the same event raises its hand next time instead of passing as a
quiet healthy run.

One more caveat learned the same day: `free + used` from `df` on the Data
volume is not constant (431.9, then 428.9, then 431.9 GB across three
runs). The APFS container's accounting shifts by a couple of GB on its
own, so treat any single-volume delta under ~3 GB as noise.
