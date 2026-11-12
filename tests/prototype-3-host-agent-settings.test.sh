#!/usr/bin/env bash
# Issue #288: the agent that runs the Prototype 3 host steps has the exact hc calls it needs
# (create a terminal, type into it, end and remove it) pre-allowed, narrower than all of hc,
# and the runbook names the settings file.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here" || exit 1
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
F=templates/host-agent-settings.json
D=docs/design/prototype-3.md

[ -f "$F" ]; check "$F exists" $?
grep -q '"allow"' "$F" 2>/dev/null; check "it has a permissions.allow list" $?
for c in 'hc run --bg' 'hc send' 'hc kill' 'hc rm' 'hc ls'; do
  grep -qF "\"Bash($c:*)\"" "$F" 2>/dev/null; check "allows $c" $?
done
# Narrower than all of hc: no bare hc rule, and none of the calls that reach a worker's keys or run code.
! grep -Eq '"Bash\(hc(:\*| \*|\*)?\)"' "$F" 2>/dev/null; check "no rule allows all of hc" $?
for c in keys exec attach interrupt file; do
  ! grep -q "Bash(hc $c" "$F" 2>/dev/null; check "does not allow hc $c" $?
done
grep -qF 'templates/host-agent-settings.json' "$D"; check "the runbook names the settings file" $?
exit $fail
