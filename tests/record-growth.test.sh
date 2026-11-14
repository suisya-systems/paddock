#!/bin/bash
# Issue #332: the record-growth probes. Static checks of the three scripts, and a test of the
# synthetic-folder generator (format, size, determinism, readable by scripts/org).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
p=$here/scripts/probes
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# 1. Static: the scripts exist, parse, and are plain sh/awk (no Python, no Node).
for s in record-growth-measure record-growth-synth record-growth-time; do
  [ -f "$p/$s.sh" ] && sh -n "$p/$s.sh" 2>/dev/null; check "$s.sh exists and parses with sh -n" $?
  ! grep -Eq 'python|node |jq ' "$p/$s.sh" 2>/dev/null && [ -f "$p/$s.sh" ]; check "$s.sh uses no python, node or jq" $?
done
# the measuring script only reads: no write, move or delete verb, no redirect into a file but
# /dev/null, and no hc call
m=$p/record-growth-measure.sh
[ -f "$m" ] && ! grep -Eq '(^|[ |;(])(rm|mv|cp|tee|touch|mkdir|sed -i|truncate|hc)( |$)' "$m"; check "the measuring script has no write verb and no hc" $?
[ -f "$m" ] && ! grep -E '>>?[ ]*[^ &/]' "$m" | grep -Eqv '>[ ]*/dev/null|2>&1'; check "the measuring script redirects only to /dev/null or stderr" $?

# 2. Generator: 600 lines per month, current and previous month, 9 writers.
g=$p/record-growth-synth.sh
SYNTH_CUR=2026-11 sh "$g" "$tmp/a" 600 >/dev/null 2>&1; check "synth: runs with a line count" $?
n=$(cat "$tmp"/a/events/2026-11/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -ge 570 ] && [ "$n" -le 630 ]; check "synth: this month holds about 600 lines (got: $n)" $?
[ -n "$(ls "$tmp"/a/events/2026-10/*.jsonl 2>/dev/null)" ]; check "synth: the previous month has files too" $?
w=$(ls "$tmp"/a/events/2026-11/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
[ "$w" -eq 9 ]; check "synth: one file per writer, 9 writers (got: $w)" $?
bad=$(cat "$tmp"/a/events/*/*.jsonl 2>/dev/null | grep -vcE '^\{"seq":[0-9]+,"ts":"[0-9-]+T[0-9:]+Z","from":"[a-z0-9_-]+","kind":"[a-z_]+","to":"[a-z0-9_-]*","task_id":"[a-z0-9_-]*","text":".*"\}$')
[ "$bad" -eq 0 ]; check "synth: every line has the shape scripts/org writes (bad: $bad)" $?
gaps=$(for f in "$tmp"/a/events/2026-11/*.jsonl; do sed -n 's/^{"seq":\([0-9]*\),.*/\1/p' "$f" | awk 'NR!=$1 { b++ } END { print b+0 }'; done | awk '{ s += $1 } END { print s+0 }')
[ "$gaps" -eq 0 ]; check "synth: seq runs 1, 2, 3, ... in each file (gaps: $gaps)" $?
SYNTH_CUR=2026-11 sh "$g" "$tmp/b" 600 >/dev/null 2>&1
diff -r "$tmp/a" "$tmp/b" >/dev/null 2>&1; check "synth: the same arguments give the same folder" $?
SYNTH_CUR=2026-11 sh "$g" "$tmp/c" 2x >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "synth: an unknown preset is refused (rc $rc)" $?

# 3. The folder is read by the real reader: check_messages answers for a worker.
out=$(env -u PADDOCK_ORG_ID PADDOCK_NOW=2026-11-20T00:00:00Z PADDOCK_STATE_DIR="$tmp/a" bash "$here/scripts/org" --as w-t01 check_messages --peek 2>&1)
case "$out" in *"secretary#"*) r=0 ;; *) r=1 ;; esac; check "scripts/org check_messages reads the generated folder" $r
out=$(env -u PADDOCK_ORG_ID PADDOCK_NOW=2026-11-20T00:00:00Z PADDOCK_STATE_DIR="$tmp/a" bash "$here/scripts/org" --as secretary list_runs 2>&1)
case "$out" in *"runs (task"*) r=0 ;; *) r=1 ;; esac; check "scripts/org list_runs reads the generated folder" $r

# 4. Measuring: read-only on the folder, reports per writer, and counts what is there.
before=$(cd "$tmp/a" && find . -type f -printf '%p %s %T@\n' | sort | cksum)
res=$(sh "$m" "$tmp/a" 2>&1); rc=$?
after=$(cd "$tmp/a" && find . -type f -printf '%p %s %T@\n' | sort | cksum)
[ "$rc" -eq 0 ]; check "measure: exits 0 (rc $rc)" $?
[ "$before" = "$after" ]; check "measure: leaves the folder as it was" $?
case "$res" in *"secretary"*"w-t01"*) r=0 ;; *) r=1 ;; esac; check "measure: names every writer" $r
total=$(printf '%s\n' "$res" | awk -F'\t' '$1=="total" { print $3 }')
all=$(cat "$tmp"/a/events/*/*.jsonl | wc -l | tr -d ' ')
[ "$total" = "$all" ]; check "measure: the total line count matches the files (got: $total, want: $all)" $?
bytes=$(printf '%s\n' "$res" | awk -F'\t' '$1=="total" { print $4 }')
want=$(cat "$tmp"/a/events/*/*.jsonl | wc -c | tr -d ' ')
[ "$bytes" = "$want" ]; check "measure: the total byte count matches the files (got: $bytes, want: $want)" $?
sh "$m" "$tmp/nonexistent" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "measure: a missing folder is an error (rc $rc)" $?

# 5. Timing script: prints one row per reader for a preset and a small folder.
res=$(SYNTH_CUR=2026-11 TIME_RUNS=1 sh "$p/record-growth-time.sh" "$tmp/t" 300 2>&1); rc=$?
[ "$rc" -eq 0 ]; check "time: runs on a 300-line folder (rc $rc)" $?
for r in check_messages list_runs wait; do
  case "$res" in *"$r"*) k=0 ;; *) k=1 ;; esac; check "time: reports $r" $k
done
exit $fail
