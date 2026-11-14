#!/usr/bin/env bash
# Static check for Issue #368: the host probe scripts/probes/trust-resend.sh parses, refuses bad arguments before it
# touches anything, never presses a key or passes --then-send, and prints every RESULT. The probe itself is not run
# (it needs hc and a claude worker).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
p=$here/scripts/probes/trust-resend.sh
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

sh -n "$p" 2>/dev/null; check "sh -n parses" $?
sh "$p" --help 2>&1 | grep -q 'Issue #368'; check "--help prints the usage" $?
LC_ALL=C grep -qP '[^\x00-\x7F]' "$p"; r=$?; [ $r -ne 0 ]; check "the whole probe is ASCII only" $?
for r in delegate-stops saved answer task-reached work-entry files-gone; do
  grep -q "res $r\|RESULT $r" "$p"; check "reports RESULT $r" $?
done
code=$(grep -vE '^[[:space:]]*#' "$p")
printf '%s\n' "$code" | grep -qE 'hc keys|hc send|then-send'; r=$?; [ $r -ne 0 ]; check "no key, no hc send, no --then-send: only answer does it" $?
printf '%s\n' "$code" | grep -qE '\.claude\.json|push|--force'; r=$?; [ $r -ne 0 ]; check "touches no Claude config and pushes nothing" $?
cd "$here" || exit 1
sh "$p" --bogus >/dev/null 2>&1; [ $? -eq 2 ] || false; check "unknown option exits 2" $?
sh "$p" --task-id 'A B' >/dev/null 2>&1; [ $? -eq 2 ] || false; check "a bad --task-id exits 2" $?
exit $fail
