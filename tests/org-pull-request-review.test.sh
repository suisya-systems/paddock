#!/usr/bin/env bash
# Review fixes for org-pull-request (stubbed hc and gh). Separate file: the acceptance test stays as declared.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
script=$here/skills/org-pull-request/scripts/org-pull-request.sh
stubdir=$tmp/bin; mkdir -p "$stubdir" "$tmp/stub"; calls=$tmp/stub/calls
printf '%s\n' '#!/bin/sh' 'echo "hc $*" >> "$STUB/calls"' \
  'case $1 in wait) echo "{\"ended\":true,\"exit_code\":0,\"signal\":null}" ;; esac' > "$stubdir/hc"
printf '%s\n' '#!/bin/sh' 'echo "gh $*" >> "$STUB/calls"' \
  'case "$1 $2" in "pr create") echo https://github.com/o/r/pull/42 ;; "run list") echo 777 ;;' \
  '"pr view") cat "$STUB/head" ;; esac' > "$stubdir/gh"
chmod +x "$stubdir/hc" "$stubdir/gh"
git init -q --bare "$tmp/origin.git"; git clone -q "$tmp/origin.git" "$tmp/wt" 2>/dev/null
git -C "$tmp/wt" checkout -q -b feat/x; git -C "$tmp/wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
git -C "$tmp/wt" rev-parse HEAD > "$tmp/stub/head"
run() { env -u PADDOCK_NOW STUB="$tmp/stub" PADDOCK_STATE_DIR="$tmp/st" PADDOCK_RUN_SLEEP=0 PATH="$stubdir:$PATH" \
  bash "$script" --worktree "$tmp/wt" --repo o/r --title t --body b "$@" 2>&1; }

# A task id that would break the JSON line is refused before anything is pushed or called.
for bad in 'a"b' 'a\b' "$(printf 'a\nb')"; do
  : > "$calls"; run --task-id "$bad" >/dev/null; rc=$?
  [ "$rc" -eq 2 ] && [ ! -s "$calls" ] && [ -z "$(git -C "$tmp/origin.git" for-each-ref)" ]; check "task id with a quote, backslash or newline exits 2 before any call" $?
done
: > "$calls"; run --task-id t1.a_b-2 >/dev/null; rc=$?
[ "$rc" -eq 0 ] && grep -q '"task_id":"t1.a_b-2"' "$tmp"/st/events/*/secretary.jsonl; check "a plain task id is recorded as given" $?

# Acceptance mode waits for the other required checks of the head instead of refusing while they run.
: > "$calls"; run --mode acceptance >/dev/null; rc=$?
[ "$rc" -eq 0 ] && grep -Eq '^gh pr checks 42 .*--required .*--watch' "$calls"; check "acceptance waits on the required checks (--watch)" $?
exit $fail
