#!/usr/bin/env bash
# Acceptance test for Issue #370 (L-N3): the worker-prompt-relay probe's auto case must reach a
# prompt that auto mode documents as still shown (an explicit permissions.ask rule), and relay
# Yes and No to it on an auto-mode terminal. Static checks only: the probe itself needs a host.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
probe=$here/scripts/probes/worker-prompt-relay.sh
inv=$here/docs/design/predecessor-inventory.md
arch=$here/docs/design/architecture.md
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

sh -n "$probe"; check "the probe parses" $?
grep -q '"ask"' "$probe"; check "the probe writes a settings file with a permissions.ask rule" $?
grep -q 'p260-auto-ask' "$probe" && grep -A4 'p260-auto-ask.md' "$probe" | grep -q -- '--permission-mode auto.*--settings'
check "an auto-mode template starts claude with --permission-mode auto and --settings" $?
grep -Eq '^relay +[a-z0-9]+ +"[^"]*" +yes +p260-auto-ask' "$probe" && grep -Eq '^relay +[a-z0-9]+ +"[^"]*" +no +p260-auto-ask' "$probe"
check "the probe relays yes and no to the auto-mode terminal" $?
grep -q 'RESULT ${pre}relay-yes' "$probe" && grep -q 'RESULT ${pre}relay-no' "$probe"
check "the relay results carry a prefix, so the auto ones are told apart" $?
grep -q 'permissions.ask' "$inv" && grep -q 'permission-modes' "$inv"; check "L-N3 records the ask rule and the vendor page" $?
grep -q 'permissions.ask' "$arch" && grep -q 'permission-modes' "$arch"; check "architecture 7.1 records the ask rule and the vendor page" $?

[ "$fail" -eq 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
