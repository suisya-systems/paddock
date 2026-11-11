#!/usr/bin/env bash
# Issue #225 (Codex review): a gate whose path does not say codex is still counted, and the gate
# script cannot be run in any other form. Needs bash, coreutils, sed, awk and node.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/scripts/org
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

gate=/opt/review/Review-Gate.sh
hook() { # hook <command>: the hook's exit status for a Bash call
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]}}))' "$1" 2>/dev/null \
    | env -u PADDOCK_ORG_ID PADDOCK_STATE_DIR="$tmp/state" PADDOCK_CODEX_DIR="$tmp/rounds" PADDOCK_CODEX_GATE="$gate" \
        CLAUDE_PROJECT_DIR=/w/workers/t1 bash "$script" --as codex-gate codex_round hook >/dev/null 2>&1
  echo $?
}
call="bash \"$gate\""
for i in 1 2 3; do [ "$(hook "$call")" -eq 0 ]; check "gate call $i is let through" $?; done
[ "$(hook "$call")" -eq 2 ]; check "the fourth gate call is refused" $?
[ "$(cat "$tmp"/rounds/events/*/codex-gate.jsonl | grep -c '"kind":"codex_round_started"')" -eq 3 ]; check "three rounds are counted" $?
for c in "$call; $call" "bash /opt/review/Review-Gate.sh" "sh \"$gate\"" "cd /opt/review && bash review-gate.sh"; do
  [ "$(hook "$c")" -eq 2 ]; check "refused: $c" $?
done
[ "$(hook 'ls /opt/review')" -eq 0 ]; check "a command without the gate name is let through" $?
exit $fail
