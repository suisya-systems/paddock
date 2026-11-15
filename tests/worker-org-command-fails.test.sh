#!/usr/bin/env bash
# Acceptance test for Issue #249: when an org command fails, the worker's turn still ends where a
# mailbox answer can reach it. Since decision 0013 stage 3 that is idle at its prompt (org-watch wakes
# it on mail); `org wait` stays as a hint.
# Checks the rule text in templates/worker-rules.md and the pointer in templates/worker.md.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
rules=$here/templates/worker-rules.md
tpl=$here/templates/worker.md
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
# The section, joined into one line so a rule may wrap.
sec=$(sed -n '/^## When an org command fails/,$p' "$rules" 2>/dev/null | sed '1d;/^## /,$d' | tr '\n' ' ')

[ -n "$sec" ]; check "worker-rules.md has a 'When an org command fails' section" $?
grep -qi 'once' <<<"$sec" && grep -qi 'again' <<<"$sec"; check "the failed command is run again once" $?
grep -qi 'refus' <<<"$sec" && grep -q 'exit 2' <<<"$sec" && grep -q 'exit 11' <<<"$sec"; check "a refusal (exit 2, exit 11) is an answer, not retried" $?
grep -qi 'screen' <<<"$sec" && grep -qi 'exit code' <<<"$sec"; check "the worker writes the command and its exit code on its screen" $?
grep -Eq -- '--as <your id> wait([[:space:]]|`|$)' <<<"$sec"; check "the org wait hint names the worker's own id" $?
grep -qi 'timeout' <<<"$sec" && grep -q 'check_messages' <<<"$sec"; check "on timeout wait again, on mail read check_messages" $?
grep -q 'PADDOCK_ORG' <<<"$sec" && grep -Eqi 'empty[^.]*stop' <<<"$sec"; check "no org command: say so on screen and stop" $?
grep -qi 'watcher wakes you' <<<"$sec" && grep -qi 'hint' <<<"$sec"; check "the watcher wakes the worker; the wait is a hint" $?
grep -qi 'never[^.]*hc send' <<<"$sec"; check "the section forbids hc send" $?

! grep -q 'say so once in your reply and wait' "$tpl"; check "worker.md no longer ends the turn idle on a failed command" $?
grep -q 'When an org command fails' "$tpl"; check "worker.md points to the rule" $?
! grep -q 'If the command is missing, say so and wait' "$rules"; check "worker-rules.md mailbox line no longer says 'say so and wait'" $?

exit $fail
