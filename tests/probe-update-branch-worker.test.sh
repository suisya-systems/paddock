#!/usr/bin/env bash
# Static check for Issue #330 (what is left): the host probe scripts/probes/update-branch-worker.sh
# parses, refuses paddock's own repository and bad arguments before it touches anything, starts a
# worker through org-delegate, has the worker run org-update-branch against side branches (never main
# of the scratch repository), never forces a push, and prints every RESULT. The probe itself is not run
# (it needs GitHub, hc and a claude worker).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
p=$here/scripts/probes/update-branch-worker.sh
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

[ -f "$p" ]; check "probe exists" $?
sh -n "$p" 2>/dev/null; check "sh -n parses" $?
bash -n "$p" 2>/dev/null; check "bash -n parses" $?
sh "$p" --help 2>&1 | grep -q 'Issue #330'; check "--help prints the usage" $?
sh "$p" --help 2>&1 | LC_ALL=C grep -qP '[^\x00-\x7F]'; r=$?; [ $r -ne 0 ]; check "--help is ASCII only (cp932 consoles)" $?

for r in delegate report-done in-box worker-env worker-merge worker-protected-stop host-control; do
  grep -q "RESULT $r\|res $r" "$p"; check "reports RESULT $r" $?
done
code=$(grep -vE '^[[:space:]]*#' "$p")
printf '%s\n' "$code" | grep -qE -- '--force|push -f|--admin|--no-verify'; r=$?; [ $r -ne 0 ]; check "no force push, no --admin" $?
printf '%s\n' "$code" | grep -qE '\.claude\.json|XDG_DATA_HOME='; r=$?; [ $r -ne 0 ]; check "touches no claude config or install folder" $?
printf '%s\n' "$code" | grep -q 'org-delegate.sh'; check "starts the worker through org-delegate" $?
printf '%s\n' "$code" | grep -q 'org-update-branch.sh'; check "the worker runs org-update-branch" $?
printf '%s\n' "$code" | grep -q -- '--base'; check "org-update-branch is pointed at a side branch (--base)" $?
printf '%s\n' "$code" | grep -q 'PADDOCK_ORG'; check "uses PADDOCK_ORG (the worker check and the report)" $?
printf '%s\n' "$code" | grep -q '\.claude/skills/'; check "the protected range touches a .claude/skills path" $?
printf '%s\n' "$code" | grep -q 'push origin --delete'; check "deletes its remote side branches" $?
printf '%s\n' "$code" | grep -qE 'push [^|;&]*refs/heads/main|push origin main'; r=$?; [ $r -ne 0 ]; check "never pushes main" $?

cd "$here" || exit 1
sh "$p" --repo suisya-systems/paddock --project /nonexistent >/dev/null 2>&1; [ $? -eq 6 ]; check "refuses paddock's own repository (exit 6)" $?
sh "$p" --repo Suisya-Systems/Paddock --project /nonexistent >/dev/null 2>&1; [ $? -eq 6 ]; check "refuses it in any case (exit 6)" $?
sh "$p" --bogus >/dev/null 2>&1; [ $? -eq 2 ]; check "unknown option exits 2" $?
sh "$p" --repo a/b >/dev/null 2>&1; [ $? -eq 2 ]; check "missing --project exits 2" $?
exit $fail
