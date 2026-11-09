#!/usr/bin/env bash
# Review fixes for org-suspend and org-resume (stubbed hc). Separate file: the acceptance tests stay as declared.
. "$(dirname "${BASH_SOURCE[0]}")/hc-stub.sh"
suspend=$here/skills/org-suspend/scripts/org-suspend.sh
resume=$here/skills/org-resume/scripts/org-resume.sh
rec=$tmp/state/suspend.record

# A failed hc connect keeps the previous record and fails.
reset; term w-t1 t1; run_script "$suspend" >/dev/null; cp "$rec" "$tmp/before"
sed -i 's/^  connect) cat >\/dev\/null;/  connect) cat >\/dev\/null; [ -z "${STUB_CONNECT_FAIL:-}" ] || exit 1;/' "$stubdir/hc"
ENVX=STUB_CONNECT_FAIL=1 run_script "$suspend" >/dev/null; rc=$?
[ "$rc" -eq 5 ] && cmp -s "$rec" "$tmp/before"; check "hc connect failing exits 5 and keeps the previous record" $?

# Braces inside a task string: the entry is kept, or suspension fails; never silently dropped.
reset; term w-t1 t1
printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"value\":{\"work\":[{\"task_id\":\"t1\",\"title\":\"A\",\"since\":\"x\",\"worktree\":\"$wt\",\"task\":\"Implement {foo} now\"}]},\"version\":1}}" > "$tmp/stub/doc"
run_script "$suspend" >/dev/null; rc=$?
{ [ "$rc" -eq 5 ] && [ ! -e "$rec" ]; } || { [ "$rc" -eq 0 ] && grep -q '^work.t1' "$rec"; }; check "an unreadable work entry is not dropped silently" $?

# Resume finds a worker recreated under another name by its label (no duplicate launch).
reset; term w-t1 t1; term w-t2 t2; run_script "$suspend" >/dev/null
rm "$tmp/stub/term-w-t2"; term renamed-t2 t2; : > "$calls"
run_script "$resume" --apply >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ! grep -q '^run ' "$calls"; check "a worker recreated under another name is found by its label" $?
# An unrelated terminal that took the old name is not mistaken for the worker.
reset; term w-t1 t1; term w-t2 t2; run_script "$suspend" >/dev/null
rm "$tmp/stub/term-w-t2"; term w-t2 other-task; : > "$calls"
out=$(run_script "$resume"); grep -Eq 't2.*gone' <<<"$out"; check "a terminal with another label under the old name does not count as alive" $?
exit $fail
