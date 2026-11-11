#!/usr/bin/env bash
# Acceptance test for Issue #194: the secretary template sends the shutdown to org-down.
# The line that names org-down tells the person to run it from the login shell and names no kill command.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tpl=$here/templates/secretary.md
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

line=$(grep -m1 'org-down' "$tpl")
[ -n "$line" ]; check "the template names org-down" $?
grep -qi 'login shell' <<<"$line"; check "that line says to run it from the login shell" $?
! grep -Eqi 'hc (kill|rm)|\bkill\b|\bremove\b' <<<"$line"; check "that line names no kill command" $?
! grep -qi 'suspend' <<<"$line"; check "that line does not describe suspending by hand" $?

exit $fail
