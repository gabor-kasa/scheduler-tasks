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
modify any file, and never run `rm`, `brew cleanup`, `simctl delete`,
`git worktree remove`, `git branch -d`, or any other reclaim command.
Report what *should* be cleared and let the user decide. A run that
deletes something has failed even if it freed space. `git worktree
remove` is on that list because Step 4 now identifies dead worktrees by
name and prints the command to remove them — printing it is the job,
running it is not.

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

Three rules for reading that output. Each one is here because the
2026-09-15 run broke it and produced a report that could not say where the
space went.

- **The container ledger is the answer to "where did the free space
  go".** The diff prints it under `where the free space went`: every
  volume sharing the APFS free pool, what each one gained, and the
  residual against the change in free space. It balances to roughly zero,
  so it is a complete account rather than a guess. Quote it before
  anything else. `UNATTRIBUTED` is a much smaller claim — it is the *Data
  volume's* residue alone. Swap files live on `/System/Volumes/VM` and
  never touch Data, so a report that discusses only Data cannot explain a
  loss that swap caused. On 2026-09-15 the ledger read Data +5.45 GB and
  VM +1.00 GB against -6.45 GB of free space, residual 0.00.
- **"not measured" is not "unchanged".** When a key was never collected
  the diff prints `not measured` instead of a delta. Never restate that
  as stable, flat, or unchanged. Say the collector did not record it and
  set `Severity: attention`: the guard is half blind until someone fixes
  it. If Step 1's own `sysctl` returned a number the collector missed,
  report the direct reading and say the two disagree.
- **Read both windows.** On a full-sweep run the diff prints a second
  block covering a longer window (since the previous full sweep) that
  includes the static trees — `~/Documents`, `~/Downloads`, `~/worktrees`,
  `/Applications`. Multi-GB movement usually lives there, while the
  run-to-run block sees only caches and containers and dumps everything
  else into `UNATTRIBUTED`. Report movers from both blocks, labelled with
  the window each came from. The 2026-09-15 run printed both and quoted
  only the first, so it carried 2.86 GB of unattributed movement while
  the second block on the same screen named `~/Documents` +1.06 GB and
  `~/Downloads` +0.65 GB.
- **A named tree is not a named cause.** The full-sweep block reports
  `~/worktrees` and `~/Documents` as one line each, because that is the
  depth `du -xkd1 $HOME` works at. "`~/worktrees` +1.78 GB" is a
  direction, not a finding, and the user cannot act on it. The collector
  now itemises those two trees under a separate `development trees,
  itemised` heading in the same diff output. When the tree moved, quote
  the itemised lines, not just the parent. Those lines are detail only:
  their parent already counts the same bytes, so they are deliberately
  left out of `Explained by du` and `UNATTRIBUTED`. Never add them in.

The volatile sweep (caches, containers, application support) costs about
35 seconds. Once a day the collector also sweeps the static trees (the
whole home directory, `/Applications`, and one level inside `~/worktrees`
and `~/Documents/workspace`), which is much slower; it decides that for
itself from a stamp file, so call it plainly and let it choose. Pass
`--full` only when the diff says the static trees are stale and the answer
depends on them.

Budget for that full sweep honestly: measured 2026-09-17, the home walk
alone is ~2m30s and the itemised development trees add ~1m20s, both with a
warm cache, and the same sweep took **9m57s** cold on a machine with
0.7 GB of free swap. It is I/O bound, not CPU bound, so it gets slower
exactly when the machine is in the state this task exists to catch. A full
sweep taking several minutes is normal and is not a reason to skip it.

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

**Then the development trees, every degraded or critical run.** The block
above covers `~/Library` and nothing else, so on its own it cannot see the
largest reclaimable pool on this machine. Measured 2026-09-17: 21.3 GB in
`~/worktrees` and 23.0 GB of `node_modules` under `~/Documents/workspace`,
against a "top consumers" list whose headline recommendation was a 3.2 GB
Xcode cache.

```bash
du -sk ~/worktrees/* 2>/dev/null | sort -rn | head -10 | awk '{printf "%.2f GB\t%s\n", $1/1048576, $2}'
du -sh ~/worktrees ~/Documents/workspace 2>/dev/null
```

Most of that mass is `node_modules`, which is reinstallable rather than
lost, so it is worth separating from real data when you size the
opportunity:

```bash
find ~/worktrees -maxdepth 3 -type d -name node_modules -prune 2>/dev/null \
  | while read -r d; do du -sk "$d"; done \
  | awk '{s+=$1} END{printf "node_modules in worktrees: %.2f GB across %d dirs\n", s/1048576, NR}'
```

Then name the **dead** worktrees: the ones whose PR is already merged or
closed, where the code is on master and the checkout is pure waste.

```bash
for w in ~/worktrees/*/; do
  br=$(git -C "$w" rev-parse --abbrev-ref HEAD 2>/dev/null)
  up=$(git -C "$w" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo NONE)
  dirty=$(git -C "$w" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "$up" = NONE ]; then unpushed=NO-UPSTREAM; else unpushed=$(git -C "$w" rev-list --count "$up"..HEAD 2>/dev/null); fi
  pr=$(cd "$w" && gh pr list --head "$br" --state all --json number,state --limit 1 \
       --jq '.[0] | "#\(.number) \(.state)"' 2>/dev/null)
  printf '%s\t%s\t%s\tdirty=%s\tunpushed=%s\n' \
    "$(du -sk "$w" | awk '{printf "%.2f GB", $1/1048576}')" "$(basename "$w")" "${pr:-no-PR}" "$dirty" "$unpushed"
done
```

Report a worktree as reclaimable **only** when all three hold: its PR is
`MERGED` or `CLOSED`, `dirty=0`, and `unpushed=0`. Anything else stays off
the list, and `NO-UPSTREAM` is the one to be strict about — it means local
commits that exist nowhere else, so however big it is, it is not
reclaimable. Give the total GB of the reclaimable set and the command,
unrun:

```
git -C ~/worktrees/<name> worktree remove ~/worktrees/<name>
```

Two notes so the report does not overclaim. Stashes are stored once per
repository, not per worktree, so several worktrees of one repo all report
the same stash count and removing any of them loses none of it. And `gh`
may be unauthenticated or rate-limited in a scheduled run; if the PR state
comes back empty for every worktree, say the PR states could not be read
and report sizes only, rather than treating "no PR" as "dead".

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
- **Where the free space went** — the container ledger from Step 1's
  diff, quoted as it printed: each volume's gain, the total, and the
  residual against the change in free space. This is the question the task
  exists to answer, so it comes first and appears on every run, healthy or
  not. Say "swap" in words when `/System/Volumes/VM` moved.
- **What moved** — Data volume used, container free, swap, the
  unattributed figure, and the top movers with their sizes, from **both**
  diff windows when the run was a full sweep, each labelled with its
  window. Anything the diff printed as `not measured` is reported as not
  measured, never as zero or unchanged.
- **Swap** — total and used, flagged if free swap is under ~1 GB. When it
  is under 1 GB, say in the same breath that clearing files will not fix
  it: swap is held by a running process, and it comes back only when
  something quits or the machine restarts. Name it as the binding
  constraint and point at memory, not at a cache list. On 2026-09-17 free
  space rose 9.3 GB across a cleanup while swap climbed to 9.5 GB used
  with 0.7 GB free, and the kill risk did not improve at all.
- **Kills** — the user-facing apps killed in the last 12h with counts, or
  "none". Mention Apple background agents only as an aggregate count.
- **Defects** — crash-looping agents and runaway logs from Step 2.5, or
  "none". For each crash loop give the label, the missing program path, and
  the fix in order (`launchctl bootout gui/$(id -u)/<label>`, then remove
  the plist, then delete the log). For each runaway log give its size and
  the last few lines.
- **Trend** — free space across the last 3 runs, or "no prior baseline"
- **Top consumers** — the `du` results, largest first
- **Development footprint** — `~/worktrees` and `~/Documents/workspace`
  totals, how much of each is `node_modules`, and the dead-worktree table
  from Step 4 with a GB total for the reclaimable set. This bullet is
  required on every degraded or critical run. It is the one the task kept
  missing: for a month of runs the largest safely reclaimable pool on the
  machine never appeared in a single report, because no step measured
  below `~/worktrees` and the `du` block only looked at `~/Library`.
- **Recommended reclaim** — concrete candidates with realistic sizes,
  cheapest-and-safest first. Never present a command as already run. Rank
  these against the ledger and the movers, not against absolute size. A
  directory that gained 4 GB since yesterday is the finding; a 3 GB cache
  that has been 3 GB for a month is background. When the growth is not
  reclaimable — a system agent's container, swap — say that plainly rather
  than falling back to the standing hogs. "The 4 GB went to
  `com.apple.mediaanalysisd`, which you cannot safely delete, and here is
  what you can clear instead" is a useful answer. "Clear your Homebrew
  cache", offered on a run where Homebrew did not move, is not.

Set `Status: success` when the check completed, even if the verdict is
critical — `Status`/`Severity: failure` is for *the check itself* failing
(a command errored, output unparseable), not for the disk being full. A
full disk is `Severity: attention`. The 2026-09-15 run wrote
`Status: success` together with `Severity: failure`; that pairing is
always wrong. If the check ran, the severity is `ok` or `attention`.

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

### Why the ledger was added (2026-09-15)

The baseline was in place and the 09:00 run still could not say where
6.5 GB had gone. Three separate defects, all measured afterwards:

- **The collector lost two of its five context measurements on
  2026-09-13.** `container.free` and `swap.*` come from `diskutil` and
  `sysctl`, both in `/usr/sbin`, which is not on the PATH the scheduler
  gives `claude -p`. Both exited 127 into `2>/dev/null`. Every block from
  `2026-09-14T09:00` onward is missing those keys. The script already used
  absolute paths for `log` and `tmutil` for this exact reason and missed
  these two.
- **The diff scored a missing key as zero.** So the runs of 09-14 17:00,
  09-15 09:00 reported "Container free +0.00 GB (stable)" and "Swap used
  +0.00 GB (no change)" a few lines above their own direct `sysctl`
  output showing swap total climbing 8192 → 10240 → 11264 MB. The
  09-14 09:00 run got the mirror image, a phantom "-20.35 GB", from
  differencing a block that had the key against one that did not. Missing
  keys now print `not measured`.
- **The ledger only balanced the Data volume.** Free space is a
  *container* property shared by every volume in it, so `df` reports the
  same free figure for `/`, `/System/Volumes/Data`, `VM`, `Preboot` and
  `Update`. Swap grows on `VM` and never appears in a Data-only account.
  Summing the used-delta of every volume in that container reconciles the
  loss exactly: over 09-14 17:00 → 09-15 09:00, Data +5.45 GB and VM
  +1.00 GB against -6.45 GB free, residual 0.00. Over the full-sweep
  window 09-13 18:17 → 09-15 09:00, Data +3.52 and VM +3.00 against
  -6.53, residual 0.00.

So the honest answer to "where did the overnight 6.5 GB go" was 5.45 GB
onto the Data volume, of which 3.97 GB is `com.apple.mediaanalysisd`'s
container, plus 1.00 GB of new swap file. None of that is in the report
the run actually wrote.

### Why the development trees are itemised (2026-09-17)

The 09:00 run died on a usage limit and wrote no measurement, so the first
reading of the day came by hand at 11.30 GB free, 98% capacity — lower
than anything in the ledger. Working out where it went exposed a blind
spot that had been there since the task was written.

`~/worktrees` held **21.29 GB across 33 worktrees**, of which 20.37 GB was
`node_modules`. Twenty-one of those worktrees had a merged or closed PR, a
clean working tree, and nothing unpushed: **11.55 GB that could be deleted
without losing a line of code**. Removing them, plus 4.49 GB of
`com.apple.e5rt.e5bundlecache`, took free space from 11.30 GB to 20.60 GB
in one sitting.

Not one run had ever mentioned it. The reason is structural, not a lapse
of judgement by any run:

- Step 4's `du` block covered `~/Library/{Application Support,Caches,
  Containers}`, DerivedData and CoreSimulator. `~/worktrees` and
  `~/Documents/workspace` were not in it, so "Top consumers" could not
  contain them at any size.
- The collector's static sweep is `du -xkd1 $HOME`, one line per top-level
  directory. The ledger could say `~/worktrees` grew 1.78 GB and could
  never say which worktree or that it was `node_modules`.

So the runs recommended what they could see. On 2026-09-16 17:00 the
headline advice was to clear a 3.2 GB Xcode cache to cross back into the
healthy band, while 11.55 GB of dead checkouts sat unmentioned a directory
away. The Context section of this very file had said `~/worktrees` was
25 GB of `node_modules` since 2026-08-11, in prose, and no step ever
measured it. A fact in the background notes that no step reads is not a
fact the task knows.

Two things that make the new check safe to act on, both verified that day:

- **Stashes are per repository, not per worktree.** All four
  `code-setting-service` worktrees reported the same 19 stashes, all three
  `smartthings-sync` ones the same 5. `git worktree remove` does not touch
  them.
- **A branch with no upstream is the one to protect.** Five of the
  surviving worktrees had no upstream and commits ahead of master, meaning
  work that exists on no remote. Size is not the test; reachability is.

The mediaanalysisd leak also repeated exactly as the ledger predicted:
0.48 GB on 09-14 17:00, 4.39 GB by 09-15 09:00, self-cleared to 0.09 GB by
17:00, then 4.58 GB again by 09-17. It is a recurring overnight refill of
`Data/Library/Caches/com.apple.mediaanalysisd/com.apple.e5rt.e5bundlecache`,
it is safe to delete, and it comes back. Report it as a recurring 4 GB
tax rather than a fresh discovery each time.
