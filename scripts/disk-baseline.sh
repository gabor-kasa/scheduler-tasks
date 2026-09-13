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
#   sweep.full                             marks a block that carries duB keys
#
# So a run-to-run diff compares duA only, and a full-sweep diff compares both.

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
		cfree=$(diskutil info -plist /System/Volumes/Data 2>/dev/null |
			plutil -extract APFSContainerFree raw - 2>/dev/null)
		case "$cfree" in
		'' | *[!0-9]*) : ;;
		*) printf '%s\tcontainer.free\t%s\n' "$run_ts" "$cfree" ;;
		esac

		sysctl vm.swapusage 2>/dev/null | awk -v r="$run_ts" '
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
			printf '%s\tsweep.full\t1\n' "$run_ts"
		fi
	} >>"$TSV"

	[ "$full" -eq 1 ] && touch "$STAMP"

	echo "baseline written: $run_ts (full sweep: $full) -> $TSV"
}

# diff_pair <ts_old> <ts_new> <key regex> <heading>
diff_pair() {
	awk -F'\t' -v a="$1" -v b="$2" -v kre="$3" -v gib="$GIB" '
		$1 == a { o[$2] = $3; seen[$2] = 1 }
		$1 == b { n[$2] = $3; seen[$2] = 1 }
		END {
			for (k in seen) {
				if (k ~ kre) {
					d = (k in n ? n[k] : 0) - (k in o ? o[k] : 0)
					explained += d
					ad = (d < 0 ? -d : d)
					# 10 MB floor, so the list is movement and not noise
					if (ad >= 10485760) {
						printf "MOVER\t%d\t%.2f\t%s\n", ad, d / gib, substr(k, 5)
					}
				} else {
					ctx[k] = (k in n ? n[k] : 0) - (k in o ? o[k] : 0)
				}
			}
			target = ctx["vol.used:/System/Volumes/Data"]
			printf "HEAD\tData volume used\t%+.2f GB\n", target / gib
			printf "HEAD\tData volume free\t%+.2f GB\n", ctx["vol.free:/System/Volumes/Data"] / gib
			printf "HEAD\tContainer free\t%+.2f GB\n", ctx["container.free"] / gib
			printf "HEAD\tSwap used\t%+.2f GB\n", ctx["swap.used"] / gib
			printf "HEAD\tVM volume used\t%+.2f GB\n", ctx["vol.used:/System/Volumes/VM"] / gib
			printf "HEAD\tSnapshots\t%+d\n", ctx["snapshots.count"]
			printf "HEAD\tExplained by du\t%+.2f GB\n", explained / gib
			printf "HEAD\tUNATTRIBUTED\t%+.2f GB\n", (target - explained) / gib
		}' "$TSV" >"$TMPF"

	echo "$4"
	grep '^HEAD' "$TMPF" | cut -f2- | awk -F'\t' '{ printf "  %-18s %s\n", $1, $2 }'
	movers=$(grep -c '^MOVER' "$TMPF" || true)
	if [ "${movers:-0}" -gt 0 ]; then
		echo
		echo "  top movers (GB, + grew / - shrank):"
		grep '^MOVER' "$TMPF" | sort -t"$(printf '\t')" -k2,2nr | head -15 |
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
	diff_pair "$ts_old" "$ts_new" '^duA\.' "since the previous run: $ts_old -> $ts_new"

	echo "  (volatile set only. Movement inside the static trees, which are"
	echo "  swept once a day, lands in UNATTRIBUTED until the next full sweep.)"
	echo

	full_list=$(awk -F'\t' '$2 == "sweep.full" { print $1 }' "$TSV" | uniq)
	full_count=$(echo "$full_list" | grep -c .)
	if [ "$full_count" -ge 2 ]; then
		f_old=$(echo "$full_list" | tail -2 | head -1)
		f_new=$(echo "$full_list" | tail -1)
		diff_pair "$f_old" "$f_new" '^du[AB]\.' "since the previous full sweep: $f_old -> $f_new"
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
