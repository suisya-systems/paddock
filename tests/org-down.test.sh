#!/usr/bin/env bash
# Acceptance test for skills/org-down/scripts/org-down.sh (stubbed hc).
. "$(dirname "${BASH_SOURCE[0]}")/hc-stub.sh"
script=$here/skills/org-down/scripts/org-down.sh
rec=$tmp/state/suspend.record

[ -f "$script" ]; check "script exists" $?
[ -f "$here/skills/org-down/SKILL.md" ]; check "SKILL.md exists" $?
bash -n "$script" 2>/dev/null; check "script parses" $?
out=$(bash "$script" --help 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -qi usage <<<"$out" && grep -q -- '--stop-core' <<<"$out" && grep -q -- '--secretary' <<<"$out"; check "--help exits 0 and names both flags" $?
bash "$script" --no-such-flag >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; check "unknown argument exits 2" $?
out=$(env PATH="$tmp/empty" "$(command -v bash)" "$script" 2>&1); rc=$?
[ "$rc" -eq 3 ]; check "no hc on PATH exits 3" $?
reset; ENVX=CLAUDE_CODE_CHILD_SESSION=1 run_script "$script" >/dev/null; rc=$?
[ "$rc" -eq 4 ] && [ ! -s "$calls" ]; check "agent environment exits 4 without calling hc" $?

# Label filtering: only terminals with a task_id label are killed and removed.
reset; term w-t1 t1; term w-t2 t2; term other; term secretary; term person-shell
out=$(run_script "$script"); rc=$?
[ "$rc" -eq 0 ]; check "down exits 0 ($out)" $?
[ ! -f "$tmp/stub/term-w-t1" ] && [ ! -f "$tmp/stub/term-w-t2" ]; check "labelled terminals are killed and removed" $?
grep -q '^kill w-t1' "$calls" && grep -q '^rm w-t1' "$calls" && grep -q '^kill w-t2' "$calls" && grep -q '^rm w-t2' "$calls"; check "hc kill then hc rm for each labelled terminal" $?
[ -f "$tmp/stub/term-other" ] && [ -f "$tmp/stub/term-person-shell" ]; check "unlabelled terminals are never touched" $?
! grep -Eq '^(kill|rm) (other|person-shell)' "$calls"; check "no kill or rm names an unlabelled terminal" $?
[ -f "$tmp/stub/term-secretary" ] && ! grep -Eq '^(kill|rm) secretary' "$calls"; check "the secretary stays without --secretary" $?
! grep -q '^server' "$calls"; check "the core is never stopped without --stop-core" $?
! grep -Eq '^(send|keys|interrupt) ' "$calls"; check "nothing is typed into an agent" $?

# Suspend first.
s=$(line '^connect'); k=$(line '^kill ')
[ -s "$rec" ] && [ -n "$s" ] && [ -n "$k" ] && [ "$s" -lt "$k" ]; check "the suspend record is written before the first kill" $?

# A failed suspend ends nothing.
reset; term w-t1 t1; ENVX=STUB_LS_FAIL=1 run_script "$script" >/dev/null; rc=$?
[ "$rc" -ne 0 ] && ! grep -Eq '^(kill|rm|server) ' "$calls"; check "suspend failing exits non-zero and ends nothing" $?

# --secretary.
reset; term w-t1 t1; term secretary; term other
run_script "$script" --secretary >/dev/null; rc=$?
[ "$rc" -eq 0 ] && grep -q '^kill secretary' "$calls" && grep -q '^rm secretary' "$calls" && [ -f "$tmp/stub/term-other" ]; check "--secretary also ends the secretary, still not unlabelled terminals" $?
reset; term boss; ENVX=PADDOCK_SECRETARY_NAME=boss run_script "$script" --secretary >/dev/null; rc=$?
[ "$rc" -eq 0 ] && grep -q '^kill boss' "$calls"; check "PADDOCK_SECRETARY_NAME is honoured with --secretary" $?

# --stop-core: stops the core, after the cleanup, never otherwise.
reset; term w-t1 t1; term other
run_script "$script" --stop-core >/dev/null; rc=$?
k=$(line '^rm w-t1'); sv=$(line '^server stop')
[ "$rc" -eq 0 ] && [ -n "$sv" ] && [ "$k" -lt "$sv" ] && ! grep -q '^server restart' "$calls"; check "--stop-core runs hc server stop after the cleanup, never restart" $?

# A kill that fails is reported and the core is not stopped.
reset; term w-t1 t1; ENVX=STUB_KILL_FAIL=1 run_script "$script" --stop-core >/dev/null; rc=$?
[ "$rc" -eq 5 ] && ! grep -q '^server' "$calls"; check "hc kill failing exits 5 and does not stop the core" $?
# Nothing labelled: still exits 0 and leaves everything.
reset; term other; run_script "$script" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ -f "$tmp/stub/term-other" ] && ! grep -Eq '^(kill|rm|server) ' "$calls"; check "no labelled terminal: exits 0, ends nothing" $?
exit $fail
