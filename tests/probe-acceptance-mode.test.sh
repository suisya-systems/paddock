#!/usr/bin/env bash
# Static check for Issue #330: the host probe scripts/probes/acceptance-mode.sh parses, refuses
# paddock's own repository and bad arguments before it touches anything, never forces a push or
# bypasses protection, never touches claude or ~/.claude.json, and prints every RESULT the issue asks
# for. The probe itself is not run (it needs GitHub and hc).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
p=$here/scripts/probes/acceptance-mode.sh
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

[ -f "$p" ]; check "probe exists" $?
sh -n "$p" 2>/dev/null; check "sh -n parses" $?
bash -n "$p" 2>/dev/null; check "bash -n parses" $?
sh "$p" --help 2>&1 | grep -q 'Issue #330'; check "--help prints the usage" $?
sh "$p" --help 2>&1 | LC_ALL=C grep -qP '[^\x00-\x7F]'; r=$?; [ $r -ne 0 ]; check "--help is ASCII only (cp932 consoles)" $?

for r in settings-acceptance-required settings-up-to-date settings-paddock-protection 1-green-merge \
         2-update-branch 2-push-no-force 2-merge-after-update 3-stale-base-refused 3-stale-head-refused; do
  grep -q "$r" "$p"; check "reports RESULT $r" $?
done
code=$(grep -vE '^[[:space:]]*#' "$p")
printf '%s\n' "$code" | grep -qE -- '--force|push -f|--admin|--auto|--no-verify'; r=$?; [ $r -ne 0 ]; check "no force push, no --admin, no --auto" $?
printf '%s\n' "$code" | grep -qE 'claude|\.claude\.json|XDG_DATA_HOME='; r=$?; [ $r -ne 0 ]; check "touches no claude install or config" $?
printf '%s\n' "$code" | grep -q 'match-head-commit'; check "tries a merge pinned to a stale head" $?
printf '%s\n' "$code" | grep -q 'org-update-branch'; check "runs org-update-branch" $?
printf '%s\n' "$code" | grep -q -- '--mode acceptance'; check "runs org-pull-request in acceptance mode" $?
printf '%s\n' "$code" | grep -q 'PADDOCK_STATE_DIR='; check "keeps ci_completed out of the real history" $?

cd "$here" || exit 1
sh "$p" --repo suisya-systems/paddock --project /nonexistent >/dev/null 2>&1; [ $? -eq 6 ]; check "refuses paddock's own repository (exit 6)" $?
sh "$p" --repo Suisya-Systems/Paddock --project /nonexistent >/dev/null 2>&1; [ $? -eq 6 ]; check "refuses it in any case (exit 6)" $?
sh "$p" --bogus >/dev/null 2>&1; [ $? -eq 2 ]; check "unknown option exits 2" $?
sh "$p" --repo a/b >/dev/null 2>&1; [ $? -eq 2 ]; check "missing --project exits 2" $?
exit $fail
