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

Design the run to be cheap on healthy days: Steps 1 and 2 are two shell
commands, and Step 3 exits early when everything is fine. Only reach
Step 4 when there is something to report.

### Step 1 — Measure real free space

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

### Step 3 — Classify, and exit early if healthy

Thresholds, calibrated on this machine (a ~494 GB volume where kills began
at roughly 12 GB free):

| Free space | Kills of user-facing apps | Verdict |
| --- | --- | --- |
| ≥ 25 GB | none | **healthy** |
| ≥ 25 GB | any | **degraded** |
| 15–25 GB | any or none | **degraded** |
| < 15 GB | any or none | **critical** |

If the verdict is **healthy**, stop here. Write a one-line `## Report`
("Free: N GB, capacity M%, no user-facing app kills in 12h"), set
`Status: success` / `Severity: ok`, add **no** `## Notification` block,
and finish. Do not run Step 4 — no point spending tokens or disk I/O on a
machine that is fine.

Otherwise continue.

### Step 4 — Find what to clear (degraded / critical only)

Identify the biggest consumers so the report is actionable. Keep these
depth-limited; do not `du` the whole home directory.

```bash
du -sh ~/Library/Application\ Support/* 2>/dev/null | sort -rh | head -8
du -sh ~/Library/Caches/* 2>/dev/null | sort -rh | head -8
du -sh ~/Library/Containers/* 2>/dev/null | sort -rh | head -5
du -sh ~/Library/Developer/Xcode/DerivedData /Library/Developer/CoreSimulator 2>/dev/null
```

Two known traps when estimating how much a candidate would actually free:

- **Mounted disk images double-count.** Anything under
  `/Library/Developer/CoreSimulator/Volumes` is a *mounted view* of a
  compressed image, not additional space. Cross-check with
  `df -h | grep -i coresimulator` and treat the backing file as the real
  size.
- **Deleting an Xcode simulator runtime leaves its download behind.**
  `xcrun simctl runtime delete` deregisters the runtime but the
  MobileAsset stays. Check
  `du -sh /System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime`
  and report it separately if non-trivial.

Also compare against prior runs to show direction of travel. List
`logs/disk-space-guard-*.md` (excluding the file being written), take the
3 most recent, extract their reported `Free:` figures, and state whether
free space is trending down, flat, or recovering. If there are no prior
logs, say "no prior baseline" and skip the trend.

### Step 5 — Write the report

Under `## Report`, include:

- **Verdict** — healthy / degraded / critical, with free GB and capacity %
- **Swap** — total and used, flagged if free swap is under ~1 GB
- **Kills** — the user-facing apps killed in the last 12h with counts, or
  "none". Mention Apple background agents only as an aggregate count.
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

Structural background: roughly 41 GB lives in
`~/Library/Application Support`, dominated by Electron apps (Claude,
Google, Brave, Notion) that cache without bound and regrow after any
cleanup. That is why a one-time reclaim does not hold and why this runs on
a schedule instead.
