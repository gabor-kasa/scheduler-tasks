#!/bin/sh
#
# Disk baseline collector for the disk-space-guard task.
#
#   disk-baseline.sh snapshot [--full]   append one measurement block to logs/disk-baseline.tsv
#   disk-baseline.sh diff                print what moved, per run and per full sweep
#
# Why this exists: on 2026-09-12 the machine gave back ~13 GB between two runs
# and nothing on disk could explain it afterwards, because the task only
# recorded per-directory sizes when it was already degraded. A healthy run kept
# no baseline, so every recovery and every silent consumer was unattributable.
# This records the same numbers on every run, cheaply, so the next run can
# subtract.
#
# Format is one line per measurement: <run_ts>\t<key>\t<value_bytes>
#
# Key prefixes matter, because the two sweeps run on different cadences and a
# key missing from a block means "not measured", not "deleted":
#
#   vol.* container.* swap.* snapshots.*   context, every run
#   duA.<path>                             volatile set, every run (~35s)
#   duB.<path>                             static set, once a day (~3min)
#   duC.<path>                             detail inside two duB trees, daily
#   sweep.full                             marks a block that carries duB keys
#
# So a run-to-run diff compares duA only, and a full-sweep diff compares both.
#
# duC is reporting detail, not accounting. duB carries ~/worktrees and
# ~/Documents as one line each, which is the depth du -xkd1 works at, so no run
# could ever name the worktree that grew. duC itemises those two trees. Its
# bytes are already counted by their duB parent, so it is deliberately excluded
# from the explained/UNATTRIBUTED sum — including both would double-count every
# one of them.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TSV="$ROOT/logs/disk-baseline.tsv"
STAMP="$ROOT/logs/.disk-baseline-full-stamp"
GIB=1073741824

snapshot() {
	run_ts=$(date '+%Y-%m-%dT%H:%M:%S%z')

	full=0
	[ "${1:-}" = "--full" ] && full=1
	[ -f "$STAMP" ] || full=1
	[ -f "$STAMP" ] && [ -z "$(find "$STAMP" -mtime -1 2>/dev/null)" ] && full=1

	# Measure into a temp file and append the block only once it is whole.
	#
	# The sweep below takes 35s volatile / ~4min full, and it used to append
	# straight to the TSV, so anything that killed the process mid-sweep left
	# a partial block behind that looked exactly like a complete one. On
	# 2026-09-17 17:00 the harness's 30s Bash timeout moved this script to the
	# background and it then died partway through duA, writing 213 of 1297
	# keys. The 09-18 09:00 diff read every unmeasured directory as having
	# grown by its own size and reported +6.09 GB of Docker growth, +3.22 GB
	# of DerivedData and +8.71 GB of /private/var/folders that never happened,
	# against a machine where Docker had not moved a byte in two days.
	#
	# Two defences, because either alone is thin: the whole block lands in one
	# append (~1ms, versus a ~4min window), and block.complete is the last key
	# written, so a block that died anyway is identifiable rather than silent.
	BLOCK=$(mktemp -t disk-baseline-block) || return 1
	# shellcheck disable=SC2064
	trap "rm -f '$BLOCK'" EXIT INT TERM

	{
		# Every mounted volume, not just Data. All APFS volumes share one
		# container, so swap growth on /System/Volumes/VM eats Data's free
		# space and looks like an unexplained loss if you only watch Data.
		df -k | awk -v r="$run_ts" '
			NR > 1 && $1 ~ /^\/dev\// {
				mnt = $9
				for (i = 10; i <= NF; i++) mnt = mnt " " $i
				printf "%s\tvol.used:%s\t%.0f\n", r, mnt, $3 * 1024
				printf "%s\tvol.free:%s\t%.0f\n", r, mnt, $4 * 1024
			}'

		# Container free is the number that governs whether macOS starts
		# killing apps. It is not the same as the Data volume's free.
		#
		# Absolute paths, like /usr/bin/tmutil and /usr/bin/log below. The
		# scheduler spawns claude -p without /usr/sbin on PATH, so bare
		# `diskutil` and `sysctl` exit 127 and their 2>/dev/null swallows it.
		# Between 2026-09-13 and 2026-09-15 that silently dropped every
		# container.free and swap.* measurement, and the diff then reported
		# the missing keys as "+0.00 GB" — three runs called the container
		# stable while swap grew from 8 to 11 GB.
		cfree=$(/usr/sbin/diskutil info -plist /System/Volumes/Data 2>/dev/null |
			/usr/bin/plutil -extract APFSContainerFree raw - 2>/dev/null)
		case "$cfree" in
		'' | *[!0-9]*) : ;;
		*) printf '%s\tcontainer.free\t%s\n' "$run_ts" "$cfree" ;;
		esac

		/usr/sbin/sysctl vm.swapusage 2>/dev/null | awk -v r="$run_ts" '
			{
				for (i = 1; i <= NF; i++) {
					if ($i == "total") tot = $(i + 2)
					if ($i == "used")  usd = $(i + 2)
				}
				printf "%s\tswap.total\t%.0f\n", r, tobytes(tot)
				printf "%s\tswap.used\t%.0f\n",  r, tobytes(usd)
			}
			function tobytes(v,   n) {
				n = v + 0
				if (v ~ /G$/) return n * 1073741824
				if (v ~ /K$/) return n * 1024
				return n * 1048576
			}'

		# APFS snapshots are invisible to du and can hold many GB.
		snaps=$(/usr/bin/tmutil listlocalsnapshots /System/Volumes/Data 2>/dev/null |
			tail -n +2 | grep -c .)
		printf '%s\tsnapshots.count\t%s\n' "$run_ts" "$snaps"

		# Volatile set: what legitimately churns day to day.
		du -sk \
			"$HOME/Library/Application Support/"* \
			"$HOME/Library/Caches/"* \
			"$HOME/Library/Containers/"* \
			"$HOME/Library/Group Containers" \
			"$HOME/.cache/"* \
			"$HOME/Library/Developer/Xcode/DerivedData" \
			/private/tmp \
			/private/var/folders \
			2>/dev/null |
			awk -v r="$run_ts" -F'\t' '{ printf "%s\tduA.%s\t%.0f\n", r, $2, $1 * 1024 }'

		if [ "$full" -eq 1 ]; then
			du -xkd1 "$HOME" 2>/dev/null |
				awk -v r="$run_ts" -F'\t' '$2 != ENVIRON["HOME"] { printf "%s\tduB.%s\t%.0f\n", r, $2, $1 * 1024 }'
			du -sk /Applications/* 2>/dev/null |
				awk -v r="$run_ts" -F'\t' '{ printf "%s\tduB.%s\t%.0f\n", r, $2, $1 * 1024 }'

			# One level inside the two development trees. See the duC note at
			# the top: detail only, never added to the explained sum.
			# Costs ~1m20s warm on top of the ~2m30s home walk (2026-09-17).
			du -sk "$HOME/worktrees/"* "$HOME/Documents/workspace/"* 2>/dev/null |
				awk -v r="$run_ts" -F'\t' '{ printf "%s\tduC.%s\t%.0f\n", r, $2, $1 * 1024 }'

			printf '%s\tsweep.full\t1\n' "$run_ts"
		fi

		# Terminator. Must stay the last line written in this block.
		printf '%s\tblock.complete\t1\n' "$run_ts"
	} >"$BLOCK"

	# Refuse to append a block that did not reach its own terminator, rather
	# than handing the next run a short one to misread.
	if ! tail -n 1 "$BLOCK" | grep -q "$(printf 'block.complete\t1')"; then
		echo "baseline ABORTED: block did not complete, nothing appended to $TSV" >&2
		return 1
	fi

	cat "$BLOCK" >>"$TSV"

	[ "$full" -eq 1 ] && touch "$STAMP"

	echo "baseline written: $run_ts (full sweep: $full) -> $TSV"
}

# diff_pair <ts_old> <ts_new> <key regex> <detail regex> <heading>
diff_pair() {
	awk -F'\t' -v a="$1" -v b="$2" -v kre="$3" -v dre="$4" -v gib="$GIB" '
		function have(k) { return (k in o) && (k in n) }
		function ctxline(label, k) {
			# A key missing from either block was never measured. Printing a
			# "+0.00 GB" delta for it reads as "nothing changed", and that is
			# how three runs in a row called the container and swap stable
			# while swap was growing from 8 GB to 11 GB.
			if (!have(k)) { printf "HEAD\t%s\tnot measured\n", label; return }
			printf "HEAD\t%s\t%+.2f GB\n", label, (n[k] - o[k]) / gib
		}
		$1 == a { o[$2] = $3; seen[$2] = 1; if ($2 ~ kre) ocount++; if ($2 == "block.complete") odone = 1 }
		$1 == b { n[$2] = $3; seen[$2] = 1; if ($2 ~ kre) ncount++; if ($2 == "block.complete") ndone = 1 }
		END {
			for (k in seen) {
				if (k ~ kre) {
					# A key measured in only ONE block is not movement, and
					# calling it movement is how this script invented 20 GB of
					# overnight growth on 2026-09-18. Treating a missing old
					# value as zero reports the entire current size of a dir
					# as growth; treating a missing new value as zero reports
					# it as deletion. Neither was observed. Count them, keep
					# them out of the explained sum so they surface as
					# UNATTRIBUTED, and let the reader see the scale.
					if (!have(k)) {
						if (k in n) { onlynew++; onlybytes += n[k] }
						else        { onlyold++; onlybytes += o[k] }
						continue
					}
					d = n[k] - o[k]
					explained += d
					ad = (d < 0 ? -d : d)
					# 10 MB floor, so the list is movement and not noise
					if (ad >= 10485760) {
						printf "MOVER\t%d\t%.2f\t%s\n", ad, d / gib, substr(k, 5)
					}
				} else if (dre != "" && k ~ dre && have(k)) {
					# Detail keys: reported, never summed into explained. The
					# have(k) test also stops the first sweep after duC was
					# added from printing every worktree as a brand-new
					# multi-GB "grower" against a block that never measured
					# them at all.
					d = n[k] - o[k]
					ad = (d < 0 ? -d : d)
					if (ad >= 10485760) {
						printf "DETAIL\t%d\t%.2f\t%s\n", ad, d / gib, substr(k, 5)
					}
				}
			}

			dused = "vol.used:/System/Volumes/Data"
			dfree = "vol.free:/System/Volumes/Data"
			target = have(dused) ? n[dused] - o[dused] : 0

			ctxline("Data volume used", dused)
			ctxline("Data volume free", dfree)
			ctxline("Container free", "container.free")
			ctxline("Swap used", "swap.used")
			ctxline("VM volume used", "vol.used:/System/Volumes/VM")
			if (have("snapshots.count"))
				printf "HEAD\tSnapshots\t%+d\n", n["snapshots.count"] - o["snapshots.count"]
			else
				printf "HEAD\tSnapshots\tnot measured\n"
			printf "HEAD\tExplained by du\t%+.2f GB\n", explained / gib
			printf "HEAD\tUNATTRIBUTED (Data)\t%+.2f GB\n", (target - explained) / gib

			# Coverage. A diff is only as good as the thinner of its two
			# blocks, and until 2026-09-18 nothing in the output said how
			# thin that was.
			printf "HEAD\tKeys compared\t%d of %d old / %d new\n", ocount - onlyold, ocount, ncount
			if (onlynew + onlyold > 0)
				printf "HEAD\tMeasured one side only\t%d keys, %.2f GB unknown\n", onlynew + onlyold, onlybytes / gib

			# block.complete is written last by snapshot(). Blocks recorded
			# before it existed do not carry it, so fall back to comparing key
			# counts: a block holding under 60%% of the keys its neighbour has
			# died mid-sweep. The 2026-09-17 17:00 block had 213 duA keys
			# against 1297 either side, and no run noticed.
			lo = (ocount < ncount ? ocount : ncount)
			hi = (ocount > ncount ? ocount : ncount)
			if ((!odone && ocount < ncount * 0.6) || (!ndone && ncount < ocount * 0.6))
				printf "TRUNC\t%d\t%d\tone block is short (%d vs %d keys) and carries no block.complete marker: it died mid-sweep. Movement below is NOT trustworthy.\n", lo, hi, ocount, ncount

			# Container ledger: where the free space actually went.
			#
			# Every APFS volume in one container draws on a single free pool,
			# so df reports the same free figure for each of them, which is how
			# a volume is recognised as sharing this container here. What the
			# volumes gained must equal what the pool lost, so this balances to
			# ~0 and names the split. Swap files live on /System/Volumes/VM and
			# never touch Data, so a Data-only ledger cannot explain a loss
			# that swap caused, which is most of what these runs kept missing.
			if (have(dfree)) {
				for (k in seen) {
					if (k !~ /^vol\.used:/) continue
					mnt = substr(k, 10)
					if (!have(k) || !have("vol.free:" mnt)) continue
					if (n["vol.free:" mnt] != n[dfree]) continue
					d = n[k] - o[k]
					ledger += d
					if (d >= 10485760 || d <= -10485760)
						printf "LEDGER\t%.2f\t%s\n", d / gib, mnt
				}
				printf "LEDGERSUM\t%.2f\t%.2f\t%.2f\n", ledger / gib, (n[dfree] - o[dfree]) / gib, (ledger + n[dfree] - o[dfree]) / gib
			}
		}' "$TSV" >"$TMPF"

	echo "$5"

	# Loud and first. A short block poisons every number under it, so this
	# must not read as a footnote the way "not measured" did.
	if grep -q '^TRUNC' "$TMPF"; then
		echo "  !! TRUNCATED BASELINE !!"
		grep '^TRUNC' "$TMPF" | cut -f4- | awk '{ printf "  !! %s\n", $0 }'
		echo "  !! Report this as a defect and set Severity: attention. Do not"
		echo "  !! quote the movers below as growth."
	fi

	grep '^HEAD' "$TMPF" | cut -f2- | awk -F'\t' '{ printf "  %-24s %s\n", $1, $2 }'

	if grep -q '^LEDGERSUM' "$TMPF"; then
		echo
		echo "  where the free space went (container ledger, balances to ~0):"
		grep "^LEDGER$(printf '\t')" "$TMPF" | sort -t"$(printf '\t')" -k2,2nr |
			awk -F'\t' '{
				name = $3
				if (name == "/System/Volumes/VM") name = name "   <- swap files, not temp files"
				printf "    %+8.2f  %s\n", $2, name
			}'
		grep '^LEDGERSUM' "$TMPF" |
			awk -F'\t' '{ printf "    %+8.2f  = total volume growth, against %+.2f GB of free space (residual %+.2f)\n", $2, $3, $4 }'
	fi

	movers=$(grep -c '^MOVER' "$TMPF" || true)
	if [ "${movers:-0}" -gt 0 ]; then
		echo
		echo "  top movers (GB, + grew / - shrank):"
		grep '^MOVER' "$TMPF" | sort -t"$(printf '\t')" -k2,2nr | head -15 |
			awk -F'\t' '{ printf "    %+8.2f  %s\n", $3, $4 }'
	fi

	details=$(grep -c '^DETAIL' "$TMPF" || true)
	if [ "${details:-0}" -gt 0 ]; then
		echo
		echo "  development trees, itemised (detail only — already counted in"
		echo "  their parent above, so do not add these to the totals):"
		grep '^DETAIL' "$TMPF" | sort -t"$(printf '\t')" -k2,2nr | head -15 |
			awk -F'\t' '{ printf "    %+8.2f  %s\n", $3, $4 }'
	fi
	echo
}

diff_last_two() {
	[ -f "$TSV" ] || {
		echo "no baseline file yet: $TSV"
		return 0
	}

	TMPF=$(mktemp -t disk-baseline) || return 1
	# shellcheck disable=SC2064
	trap "rm -f '$TMPF'" EXIT INT TERM

	ts_list=$(cut -f1 "$TSV" | uniq)
	count=$(echo "$ts_list" | grep -c .)
	if [ "$count" -lt 2 ]; then
		echo "no prior baseline (only $count measurement block so far)"
		return 0
	fi

	ts_old=$(echo "$ts_list" | tail -2 | head -1)
	ts_new=$(echo "$ts_list" | tail -1)
	# No detail regex: duC is collected on full sweeps only, so a run-to-run
	# pair never has it in both blocks.
	diff_pair "$ts_old" "$ts_new" '^duA\.' '' "since the previous run: $ts_old -> $ts_new"

	echo "  (volatile set only. Movement inside the static trees, which are"
	echo "  swept once a day, lands in UNATTRIBUTED until the next full sweep.)"
	echo

	full_list=$(awk -F'\t' '$2 == "sweep.full" { print $1 }' "$TSV" | uniq)
	full_count=$(echo "$full_list" | grep -c .)
	if [ "$full_count" -ge 2 ]; then
		f_old=$(echo "$full_list" | tail -2 | head -1)
		f_new=$(echo "$full_list" | tail -1)
		diff_pair "$f_old" "$f_new" '^du[AB]\.' '^duC\.' "since the previous full sweep: $f_old -> $f_new"
	else
		echo "since the previous full sweep: not yet, only $full_count full sweep on record"
		echo
	fi
}

case "${1:-}" in
snapshot)
	shift
	snapshot "${1:-}"
	;;
diff) diff_last_two ;;
*)
	echo "usage: $(basename "$0") snapshot [--full] | diff" >&2
	exit 2
	;;
esac
