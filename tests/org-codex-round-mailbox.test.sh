#!/usr/bin/env bash
# Issue #225 (Codex review): the gate hook lets a worker's own mailbox call through when its text
# or id says codex, and still refuses one that chains or expands anything. Needs bash and node.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/scripts/org
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
hook() { # hook <command>: the hook's exit status for a Bash call
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]}}))' "$1" 2>/dev/null \
    | env -u PADDOCK_ORG_ID PADDOCK_STATE_DIR="$tmp/state" PADDOCK_CODEX_DIR="$tmp/rounds" PADDOCK_CODEX_GATE=/opt/codex-gate.sh \
        CLAUDE_PROJECT_DIR=/w/workers/t1 bash "$script" --as codex-gate codex_round hook >/dev/null 2>&1
  echo $?
}
o='bash "$PADDOCK_ORG" --as'
for c in "$o w-t1 report blocked --task t1 \"Codex review reached its cap (CODEX_ROUND_DENIED)\"" \
         "$o w-t1 send_message secretary 'codex said: \$x; fine'" \
         "$o w-codex-1 wait" "$o w-codex-1 check_messages" \
         "$o w-t1 report done --task t1 \"line one
codex line two\""; do
  [ "$(hook "$c")" -eq 0 ]; check "let through: $c" $?
done
for c in "$o w-t1 report blocked --task t1 \"x\"; codex exec y" "$o w-t1 send_message secretary \"\$(codex exec y)\"" \
         "$o w-t1 send_message secretary codex | sh" "$o w-t1 send_message secretary \`codex\`" \
         "$o codex-gate codex_round start --task t1" "$o w-t1 report blocked --task t1 \"open
\" && codex" "$o w-t1 send_message secretary 'codex
'
codex exec y"; do
  [ "$(hook "$c")" -eq 2 ]; check "refused: $c" $?
done
exit $fail
