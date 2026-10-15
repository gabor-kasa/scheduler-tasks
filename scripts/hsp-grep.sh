#!/usr/bin/env bash
# Usage: hsp-grep.sh [-f] <git-grep-options/pattern...> [-- <pathspec...>]
# Greps origin/<default> of every HSP-owned repo (CODEOWNERS via own_list), never the working tree.
# Output lines are prefixed "<repo>:". -f fetches each repo first. REPOS="a b" limits the repo set.
set -u
W=~/Documents/workspace/kasa
M=$W/scheduler-tasks/reports/hsp-backlog-obsolescence/default-branches.tsv
FETCH=0; [ "${1:-}" = "-f" ] && { FETCH=1; shift; }
OPTS=(); PATHS=(); seen=0
for a in "$@"; do
  if [ $seen = 0 ] && [ "$a" = "--" ]; then seen=1; continue; fi
  if [ $seen = 0 ]; then OPTS+=("$a"); else PATHS+=("$a"); fi
done
while IFS=$'\t' read -r repo slug def; do
  [ "$def" = "no-remote" ] && continue
  if [ -n "${REPOS:-}" ] && ! tr ' ' '\n' <<<"$REPOS" | grep -qx "$repo"; then continue; fi
  [ $FETCH = 1 ] && git -C "$W/$repo" fetch -q 2>/dev/null
  git -C "$W/$repo" grep -I "${OPTS[@]}" "origin/$def" -- ${PATHS[@]+"${PATHS[@]}"} 2>/dev/null \
    | awk -v r="$repo" -v p="origin/$def:" 'index($0,p)==1{print r":"substr($0,length(p)+1);next}{print r":"$0}'
done < "$M"
