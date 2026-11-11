#!/usr/bin/env bash
# Acceptance test for Issue #183: the secretary template does not tell the secretary to put the worker's org id into the task text.
# org-delegate already adds it; the template only says that it does.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tpl=$here/templates/secretary.md
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

! grep -Eqi '\bput\b[^.]*"?Your org id' "$tpl"; check "no line tells the secretary to put the org id in the task text" $?
[ "$(grep -c 'Your org id' "$tpl")" -le 1 ]; check "the org id sentence appears at most once (org-delegate's note)" $?
grep -q 'w-<task_id>' "$tpl"; check "the template still names the worker id w-<task_id>" $?

exit $fail
