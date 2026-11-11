#!/usr/bin/env bash
# Acceptance test for skills/org-resume/scripts/org-resume.sh (stubbed hc).
. "$(dirname "${BASH_SOURCE[0]}")/hc-stub.sh"
script=$here/skills/org-resume/scripts/org-resume.sh
suspend=$here/skills/org-suspend/scripts/org-suspend.sh
launched() { grep -Eq '^(run|kill|rm|send|keys|server) ' "$calls"; }

[ -f "$script" ]; check "script exists" $?
[ -f "$here/skills/org-resume/SKILL.md" ]; check "SKILL.md exists" $?
bash -n "$script" 2>/dev/null; check "script parses" $?
out=$(bash "$script" --help 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -qi usage <<<"$out" && grep -q -- '--apply' <<<"$out"; check "--help exits 0 and names --apply" $?
bash "$script" --no-such-flag >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; check "unknown argument exits 2" $?
out=$(env PATH="$tmp/empty" "$(command -v bash)" "$script" 2>&1); rc=$?
[ "$rc" -eq 3 ]; check "no hc on PATH exits 3" $?
reset; ENVX=CLAUDE_CODE_CHILD_SESSION=1 run_script "$script" >/dev/null; rc=$?
[ "$rc" -eq 4 ] && [ ! -s "$calls" ]; check "agent environment exits 4 without calling hc" $?
# Neither a record nor in-progress work (the work list is empty or absent): stop with a clear message.
reset; echo '{"jsonrpc":"2.0","id":1,"result":{"value":{"work":[],"approvals":[]},"version":4}}' > "$tmp/stub/doc"
out=$(run_script "$script"); rc=$?
[ "$rc" -eq 9 ] && ! launched; check "no record and no work in the work list exits 9, launches nothing ($rc)" $?
grep -qi 'no suspend record' <<<"$out" && grep -qi 'work list' <<<"$out"; check "the message names the missing record and the empty work list" $?
reset; echo '{"jsonrpc":"2.0","id":1,"result":{"value":{"work":[],"approvals":[]},"version":4}}' > "$tmp/stub/doc"
run_script "$script" >/dev/null; rc=$?
[ "$rc" -eq 9 ] && ! launched; check "an empty work array exits 9 as well ($rc)" $?
reset; echo '{"jsonrpc":"2.0","id":1,"result":{"value":null,"version":0}}' > "$tmp/stub/doc"
run_script "$script" >/dev/null; rc=$?
[ "$rc" -eq 9 ] && ! launched; check "an absent org-state document exits 9 as well ($rc)" $?

# No record, but the work list has in-progress work (an unplanned core stop): resume from it.
reset; term w-t1 t1
out=$(run_script "$script"); rc=$?
[ "$rc" -eq 0 ] && ! launched; check "no record, work list has work: plan exits 0, launches nothing ($rc)" $?
grep -qi 'no suspend record' <<<"$out" && grep -qi 'work list' <<<"$out"; check "the output says it resumed from the work list" $?
grep -Eqi 'not restore|cannot restore|could not restore' <<<"$out"; check "the output says what it could not restore" $?
grep -q 't2' <<<"$out" && grep -qi 'continue' <<<"$out"; check "the plan names the gone worker and the --continue attempt" $?
grep -Eq 't1.*(alive|keep)' <<<"$out"; check "the plan keeps the worker whose terminal is alive" $?
reset; term w-t1 t1
out=$(run_script "$script" --apply); rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c '^run ' "$calls")" -eq 1 ]; check "no record: --apply launches one worker for the gone terminal ($rc)" $?
grep -q '^run .*worker-continue' "$calls" && grep -q -- '--label task_id=t2' "$calls" && grep -q -- '--name w-t2' "$calls" && grep -q 'Do beta' "$calls"; check "the launch uses worker-continue, the label, the name and the task from the work list" $?
! grep -Eq '^(kill|rm|server) ' "$calls" && [ -f "$tmp/stub/term-w-t1" ]; check "no record: the alive terminal is left alone and the core is not touched" $?
reset; ENVX=STUB_CONT_FAIL=1 run_script "$script" --apply >/dev/null; rc=$?
grep '^run ' "$calls" | grep -v worker-continue | grep -q 'Do beta'; check "no record: the fresh fallback still works with the task from the work list ($rc)" $?
reset; ENVX=STUB_LS_FAIL=1 run_script "$script" >/dev/null; rc=$?
[ "$rc" -eq 5 ]; check "no record and the core unreachable exits 5" $?

# Record made by org-suspend with t1 alive and t2's terminal gone after a full core stop.
mk() { reset; term w-t1 t1; term w-t2 t2; term other; run_script "$suspend" >/dev/null; rm -f "$tmp/stub/term-w-t2"; : > "$calls"; }

# Plan without --apply: launches nothing.
mk; out=$(run_script "$script"); rc=$?
[ "$rc" -eq 0 ] && ! launched; check "plan without --apply exits 0 and launches nothing ($rc)" $?
grep -q 't2' <<<"$out" && grep -qi 'continue' <<<"$out"; check "plan names the gone worker and the --continue attempt" $?
grep -qi -- '--apply' <<<"$out"; check "plan tells how to apply" $?
! grep -qi "no suspend record" <<<"$out"; check "with a record the output does not claim it is missing" $?
grep -Eq 't1.*(alive|keep)' <<<"$out"; check "plan keeps the worker whose terminal is alive" $?
grep -qi 'missing' <<<"$out"; check "plan reports a missing worktree" $?

# Git comparison: a commit made after the record moves HEAD.
mk; gitc commit -q --allow-empty -m two
out=$(run_script "$script"); grep -Eqi 't1.*(head|commit).*chang' <<<"$out"; check "plan reports a worktree HEAD that moved since the record" $?

# --apply: continue first, fresh only on failure.
mk; out=$(run_script "$script" --apply); rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c '^run ' "$calls")" -eq 1 ]; check "--apply launches one worker for the gone terminal ($rc)" $?
grep -q '^run .*worker-continue' "$calls" && grep -q -- '--outlive-parent' "$calls" && grep -q -- '--label task_id=t2' "$calls" && grep -q -- '--name w-t2' "$calls"; check "launch is from worker-continue with --outlive-parent, the label and the name" $?
grep -q 'Do beta' "$calls"; check "the original task is in the launch" $?
! grep -Eq '^(kill|rm) ' "$calls" && [ -f "$tmp/stub/term-w-t1" ] && [ -f "$tmp/stub/term-other" ]; check "alive and unlabelled terminals are left alone" $?
! grep -q '^server' "$calls"; check "the core is never stopped or restarted" $?

# --continue fails: fall back to a fresh worker with the original task.
mk; out=$(ENVX=STUB_CONT_FAIL=1 run_script "$script" --apply); rc=$?
c=$(line '^run .*worker-continue'); k=$(line '^kill w-t2'); r=$(line '^rm w-t2'); f=$(grep -n '^run ' "$calls" | grep -v worker-continue | head -1 | cut -d: -f1)
[ "$rc" -eq 0 ] && [ -n "$c" ] && [ -n "$k" ] && [ -n "$r" ] && [ -n "$f" ] && [ "$c" -lt "$k" ] && [ "$k" -lt "$r" ] && [ "$r" -lt "$f" ]; check "order: --continue, then end it, then the fresh worker ($rc)" $?
grep '^run ' "$calls" | grep -v worker-continue | grep -q 'Do beta'; check "the fresh worker gets the original task" $?
[ -f "$tmp/stub/term-w-t2" ]; check "the fresh worker's terminal exists afterwards" $?
grep -qi 'fresh' <<<"$out"; check "the output says it fell back to a fresh worker" $?

# Both fail.
mk; ENVX="STUB_CONT_FAIL=1 STUB_FRESH_FAIL=1" run_script "$script" --apply >/dev/null; rc=$?
[ "$rc" -eq 13 ]; check "both launches failing exits 13" $?

# A terminal that exists without a status is not alive: it is ended before the relaunch (name reuse).
mk; term w-t2 t2; echo none > "$tmp/stub/state-w-t2"
run_script "$script" --apply >/dev/null; rc=$?
k=$(line '^kill w-t2'); n=$(line '^run ')
[ "$rc" -eq 0 ] && [ -n "$k" ] && [ "$k" -lt "$n" ]; check "a labelled terminal with no status is ended, then relaunched" $?

# Nothing to do.
mk; term w-t2 t2; run_script "$script" --apply >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ! grep -q '^run ' "$calls"; check "every worker alive: --apply launches nothing" $?
exit $fail
