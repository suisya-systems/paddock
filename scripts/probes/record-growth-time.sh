#!/bin/sh
# Issue #332: time the mailbox readers of scripts/org on a synthetic folder.
# usage: record-growth-time.sh <work-dir> <1x|10x|p95|LINES>
# Builds <work-dir>/<size>/ with record-growth-synth.sh (a new folder each time), then times
# check_messages --peek, list_runs and one poll of wait, as a worker that has unread mail
# (wait returns on the first poll, so its time is the cost of one poll, without the sleep).
# Output, tab-separated: size, lines_per_month, bytes_on_disk, reader, seconds (median of TIME_RUNS, default 3).
# Needs sh, awk, date and a bash for scripts/org. SYNTH_CUR=<YYYY-MM> as for the generator.
set -u
[ $# -eq 2 ] || { echo "usage: $0 <work-dir> <1x|10x|p95|LINES>" >&2; exit 2; }
here=$(cd "$(dirname "$0")/../.." && pwd)
dir=$1/$2
sh "$here/scripts/probes/record-growth-synth.sh" "$dir" "$2" >/dev/null || exit $?
cur=$(ls "$dir/events" | sort | tail -n 1)
lines=$(cat "$dir/events/$cur"/*.jsonl | wc -l | tr -d ' ')
bytes=$(cat "$dir"/events/*/*.jsonl | wc -c | tr -d ' ')
runs=${TIME_RUNS:-3}
now=$cur-20T00:00:00Z
reader() { # reader <as> <org args...>: seconds of one run
  as=$1; shift
  s=$(date +%s.%N)
  env -u PADDOCK_ORG_ID PADDOCK_NOW="$now" PADDOCK_STATE_DIR="$dir" PADDOCK_WAIT_POLL=1 bash "$here/scripts/org" --as "$as" "$@" >/dev/null 2>&1
  e=$(date +%s.%N)
  awk -v s="$s" -v e="$e" 'BEGIN { printf "%.3f\n", e - s }'
}
median() { sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }'; }
for spec in "check_messages|w-t01|check_messages --peek" "list_runs|secretary|list_runs" "wait|w-t01|wait --timeout 5"; do
  name=${spec%%|*}; rest=${spec#*|}; as=${rest%%|*}; cmd=${rest#*|}
  t=$(i=0; while [ "$i" -lt "$runs" ]; do reader "$as" $cmd; i=$((i + 1)); done | median)
  printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$lines" "$bytes" "$name" "$t"
done
