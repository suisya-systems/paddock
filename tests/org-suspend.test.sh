#!/usr/bin/env bash
# Acceptance test for skills/org-suspend/scripts/org-suspend.sh (stubbed hc).
. "$(dirname "${BASH_SOURCE[0]}")/hc-stub.sh"
script=$here/skills/org-suspend/scripts/org-suspend.sh
rec=$tmp/state/suspend.record
nothing_ended() { ! grep -Eq '^(kill|rm|run|send|keys|server|interrupt) ' "$calls"; }

[ -f "$script" ]; check "script exists" $?
[ -f "$here/skills/org-suspend/SKILL.md" ]; check "SKILL.md exists" $?
bash -n "$script" 2>/dev/null; check "script parses" $?

out=$(bash "$script" --help 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -qi usage <<<"$out"; check "--help exits 0 with usage" $?
bash "$script" --no-such-flag >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; check "unknown argument exits 2" $?
out=$(env PATH="$tmp/empty" "$(command -v bash)" "$script" 2>&1); rc=$?
[ "$rc" -eq 3 ]; check "no hc on PATH exits 3" $?
reset; ENVX=CLAUDE_CODE_CHILD_SESSION=1 run_script "$script" >/dev/null; rc=$?
[ "$rc" -eq 4 ] && [ ! -s "$calls" ]; check "agent environment exits 4 without calling hc" $?
reset; ENVX=STUB_LS_FAIL=1 run_script "$script" >/dev/null; rc=$?
[ "$rc" -eq 5 ] && [ ! -e "$rec" ]; check "core unreachable exits 5, writes no record" $?

# Happy path: two paddock terminals, one terminal without a label, one secretary.
reset; term w-t1 t1; term w-t2 t2; term other; term secretary
out=$(run_script "$script"); rc=$?
[ "$rc" -eq 0 ] && [ -s "$rec" ]; check "suspend exits 0 and writes the record ($out)" $?
grep -q 't1' "$rec" && grep -q 't2' "$rec" && grep -q 'w-t1' "$rec"; check "record lists the paddock terminals by task_id" $?
! grep -Eq '(^|[^A-Za-z0-9_-])(other|secretary)([^A-Za-z0-9_-]|$)' "$rec"; check "record leaves out the unlabelled terminal and the secretary" $?
grep -q 'Alpha' "$rec" && grep -q 'carefully' "$rec"; check "record keeps the org-state document (title and original task)" $?
head=$(git -C "$wt" rev-parse HEAD)
grep -q "$head" "$rec"; check "record holds the worktree's git HEAD" $?
nothing_ended; check "suspend ends, starts and types nothing, and does not touch the core" $?
[ -f "$tmp/stub/term-w-t1" ] && [ -f "$tmp/stub/term-other" ] && [ -f "$tmp/stub/term-secretary" ]; check "every terminal is still alive" $?
grep -q '^connect' "$calls"; check "org-state is read through hc connect" $?
grep -qi 'missing' "$rec"; check "a missing worktree is recorded as missing" $?

# An empty org-state is recorded, not fatal.
reset; rm "$tmp/stub/doc"; term w-t1 t1; run_script "$script" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && grep -q 't1' "$tmp/state/suspend.record"; check "no org-state document still records the terminals" $?
# Rerun replaces the record, does not append.
reset; term w-t1 t1; run_script "$script" >/dev/null; run_script "$script" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c 'w-t1' "$tmp/state/suspend.record")" -eq 1 ]; check "a rerun replaces the record" $?
exit $fail
