#!/usr/bin/env bash
# The Prototype 3 request names only options the commands it names have (Issue #283: it named
# `org-escalation ask --answer-in`, which does not exist; the secretary dropped it).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here" || exit 1
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
S=scripts/probes/prototype-3.sh
E=skills/org-escalation/scripts/org-escalation.sh

req=$(grep -F 'org-escalation ask' "$S")
[ -n "$req" ]; check "the request names org-escalation ask" $?
opts=$(grep -o 'org-escalation ask --[a-z-]*' <<<"$req" | sed 's/.* //' | sort -u)
bad=0
for o in $opts; do grep -qF -e "$o)" -e "$o " "$E" || { echo "  no such option in $E: $o"; bad=1; }; done
[ "$bad" -eq 0 ]; check "every option the request gives org-escalation ask exists" $?
! grep -n -e '--answer-in' "$S" | grep -q .; check "the runbook does not name --answer-in" $?
! sed '/^## Result/,$d' docs/design/prototype-3.md | grep -q -e '--answer-in'; check "the design text does not name --answer-in" $?
exit $fail
