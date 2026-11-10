#!/usr/bin/env bash
# Acceptance test for Issue #168: the ci_completed record goes through scripts/org (one writer
# path, one sequence, the per-id lock, the same events folder). hc and gh are stubbed as in
# tests/org-pull-request-review.test.sh; nothing reaches GitHub and no core runs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
org=$here/scripts/org
script=$here/skills/org-pull-request/scripts/org-pull-request.sh

stubdir=$tmp/bin; mkdir -p "$stubdir" "$tmp/stub"
printf '%s\n' '#!/bin/sh' \
  'case $1 in wait) echo "{\"ended\":true,\"exit_code\":0,\"signal\":null}" ;; esac' > "$stubdir/hc"
printf '%s\n' '#!/bin/sh' \
  'case "$1 $2" in "pr create") echo https://github.com/o/r/pull/42 ;; "run list") echo 777 ;; esac' > "$stubdir/gh"
chmod +x "$stubdir/hc" "$stubdir/gh"
git init -q --bare "$tmp/origin.git"; git clone -q "$tmp/origin.git" "$tmp/wt" 2>/dev/null
git -C "$tmp/wt" checkout -q -b feat/x; git -C "$tmp/wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one

# Clock: this month and the last, as scripts/org computes them.
cur=$(date -u +%Y-%m)
y=${cur%-*}; m=$((10#${cur#*-} - 1)); [ "$m" -gt 0 ] || { m=12; y=$((10#$y - 1)); }
prev=$(printf '%04d-%02d' "$((10#$y))" "$m")
now_prev=$prev-15T00:00:00Z; now_cur=${cur}-01T00:00:01Z

# Every run starts from a clean environment: only XDG_STATE_HOME (and what the case adds).
clean() { env -u PADDOCK_STATE_DIR -u PADDOCK_EVENTS_DIR -u PADDOCK_ORG_ID -u PADDOCK_NOW -u PADDOCK_LOCK_WAIT "$@"; }
o() { # o <xdg> <now> <org args...>
  local x=$1 n=$2; shift 2; clean XDG_STATE_HOME="$x" PADDOCK_NOW="$n" bash "$org" "$@"
}
pr() { # pr <xdg> [VAR=value...]: org-pull-request.sh, human mode, PR 42, run 777
  local x=$1; shift
  clean XDG_STATE_HOME="$x" PADDOCK_NOW="$now_cur" PADDOCK_RUN_SLEEP=0 PATH="$stubdir:$PATH" "$@" \
    bash "$script" --worktree "$tmp/wt" --repo o/r --title t --body b --task-id t1 2>&1
}
seqs() { # seqs <events dir>: secretary's seq numbers in write order (last month's file, then this one's)
  cat "$1/$prev/secretary.jsonl" "$1/$cur/secretary.jsonl" 2>/dev/null | sed -n 's/^{"seq":\([0-9]*\),.*/\1/p' | tr '\n' ' '
}
increasing() { awk '{ for (i = 2; i <= NF; i++) if ($i + 0 <= $(i - 1) + 0) exit 1 }' <<<"$1"; }

# 1. A ci_completed record written between two secretary messages, across a month boundary.
x=$tmp/xdg1; ev=$x/paddock/events
for t in m1 m2 m3; do o "$x" "$now_prev" --as secretary send_message w-t1 "$t" >/dev/null; done
o "$x" "$now_cur" --as secretary send_message w-t1 first >/dev/null
o "$x" "$now_cur" --as w-t1 check_messages >/dev/null # reads and acks "first"
out=$(pr "$x"); rc=$?
[ "$rc" -eq 0 ]; check "org-pull-request exits 0 with stubbed CI ($out)" $?
grep -q '"kind":"ci_completed"' "$ev/$cur/secretary.jsonl" 2>/dev/null; check "the ci_completed line is in the secretary's file under scripts/org's events folder" $?
o "$x" "$now_cur" --as secretary send_message w-t1 later >/dev/null
s=$(seqs "$ev")
increasing "$s" && [ "$(wc -w <<<"$s")" -eq 6 ]; check "secretary's seq is strictly increasing across messages and ci_completed (got: $s)" $?
o "$x" "$now_cur" --as w-t1 check_messages --peek | grep -q '^later$'; check "the reader sees the message after ci_completed as unread" $?

# 2. History already damaged by the old writer (a ci_completed line with a lower seq at the
#    end of this month's file): the next message must still be new to the reader.
x=$tmp/xdg2; ev=$x/paddock/events
for t in m1 m2 m3; do o "$x" "$now_prev" --as secretary send_message w-t1 "$t" >/dev/null; done
o "$x" "$now_cur" --as secretary send_message w-t1 first >/dev/null
o "$x" "$now_cur" --as w-t1 check_messages >/dev/null
printf '%s\n' "{\"seq\":2,\"ts\":\"$now_cur\",\"kind\":\"ci_completed\",\"writer\":\"secretary\",\"pr\":1,\"sha\":\"abc\",\"run_id\":1,\"exit_code\":0,\"conclusion\":\"success\"}" >> "$ev/$cur/secretary.jsonl"
o "$x" "$now_cur" --as secretary send_message w-t1 later >/dev/null
s=$(seqs "$ev")
o "$x" "$now_cur" --as w-t1 check_messages --peek | grep -q '^later$'; check "after a damaged line, the next message is unread (got seqs: $s)" $?

# 3. Both scripts resolve the events folder the same way: PADDOCK_STATE_DIR wins for both.
x=$tmp/xdg3; st=$tmp/st3
pr "$x" PADDOCK_STATE_DIR="$st" >/dev/null
grep -q '"kind":"ci_completed"' "$st/events/$cur/secretary.jsonl" 2>/dev/null && [ ! -e "$x/paddock/events" ]; check "with PADDOCK_STATE_DIR set, ci_completed is written under \$PADDOCK_STATE_DIR/events only" $?

# 4. The lock: while a live holder has the secretary's lock, ci_completed is not written.
x=$tmp/xdg4; ev=$x/paddock/events
mkdir -p "$ev/secretary.lock"; echo $$ > "$ev/secretary.lock/pid"
pr "$x" PADDOCK_LOCK_WAIT=1 >/dev/null; rc=$?
[ "$rc" -eq 12 ] && ! grep -qs ci_completed "$ev/$cur/secretary.jsonl"; check "a held lock stops the write: exit 12, no line (rc $rc)" $?

# 5. The subcommand itself: same fields as before, canonical numbers only.
x=$tmp/xdg5; ev=$x/paddock/events
o "$x" "$now_cur" --as secretary ci_completed --pr 42 --sha 0123abcd --run-id 777 --exit-code 1 --task t1 >/dev/null; rc=$?
l=$(cat "$ev/$cur/secretary.jsonl" 2>/dev/null)
[ "$rc" -eq 0 ] && [ "$l" = "{\"seq\":1,\"ts\":\"$now_cur\",\"kind\":\"ci_completed\",\"writer\":\"secretary\",\"task_id\":\"t1\",\"pr\":42,\"sha\":\"0123abcd\",\"run_id\":777,\"exit_code\":1,\"conclusion\":\"failure\"}" ]
check "org ci_completed writes the documented line ($l)" $?
for bad in "--pr 08" "--pr 42 --run-id 010" "--sha x\"y" "--task a\"b" "--exit-code -1"; do
  # shellcheck disable=SC2086
  set -- --pr 42 --sha abc --run-id 7 --exit-code 0 $bad
  o "$x" "$now_cur" --as secretary ci_completed "$@" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && [ "$(wc -l < "$ev/$cur/secretary.jsonl")" -eq 1 ]; check "org ci_completed refuses $bad (exit 2, nothing written)" $?
done
exit $fail
