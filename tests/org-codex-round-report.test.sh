#!/usr/bin/env bash
# Issue #307: a worker's done report that quotes the review gate's last line (it names the reviewing
# CLI) passes the round hook in the forms a worker writes it, and is not counted as a round; a call
# that could still run the CLI stays refused. Needs bash and node.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/scripts/org
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
org=/opt/paddock/bin/org
hook() { # hook <command>: the hook's exit status for a Bash call, as the worker settings run it
  node -e 'process.stdout.write(JSON.stringify({session_id:"s",tool_name:"Bash",tool_input:{command:process.argv[1],description:"report"}}))' "$1" 2>/dev/null \
    | env -u PADDOCK_ORG_ID PADDOCK_ORG="$org" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_CODEX_DIR="$tmp/rounds" \
        PADDOCK_CODEX_GATE=/opt/paddock/bin/second-model-review.sh CLAUDE_PROJECT_DIR=/w/workers/t1 \
        bash "$script" --as codex-gate codex_round hook >/dev/null 2>&1
  echo $?
}
line='CODEX_GATE: passed (succeeded=3 failed=0 status=0 log=/tmp/second-review-diff.S10iOR)'
v='bash "$PADDOCK_ORG" --as w-t1'
w="bash \"$org\" --as w-t1"
for c in "$v report done --task t1 'Commits 6a98c70 and 0dbc4d4. Gate: $line'" \
         "$v report done --task t1 \"Commits 6a98c70 and 0dbc4d4. Gate: $line\"" \
         "$w report done --task t1 'Gate: $line'" \
         "$w send_message secretary \"Gate: $line\"" \
         "$v report done --task t1 \"\$(cat <<'EOF'
Commits 6a98c70 and 0dbc4d4; git log -1 --format='%(trailers)' showed the trailer.
Gate: $line
EOF
)\"" \
         "$w report done --task t1 \"\$(cat <<'EOF'
Gate: $line (\$x and \`y\` stay text here)
EOF
)\""; do
  [ "$(hook "$c")" -eq 0 ]; check "let through: $c" $?
done
# A report is not a round: none of the calls above was counted.
n=$(cat "$tmp"/rounds/events/*/codex-gate.jsonl 2>/dev/null | grep -c codex_round_started)
[ "$n" -eq 0 ]; check "no round counted for the reports ($n)" $?
for c in "$v report done --task t1 \"Gate: \`codex exec y\`\"" \
         "$v report done --task t1 \"\$(cat <<EOF
\$(codex exec y)
EOF
)\"" \
         "$v report done --task t1 \"\$(cat <<'EOF'
Gate: $line
EOF
)\"; codex exec y" \
         "$v report done --task t1 \"\$(cat <<'EOF'
Gate: $line
EOF
codex exec y)\"" \
         "$v report done --task t1 \"\$(cat <<'EOF'
Gate: $line
EOF)\"" \
         "bash \"/elsewhere/org\" --as w-t1 report done --task t1 'Gate: $line'" \
         "$w report done --task t1 'x' && codex exec y"; do
  [ "$(hook "$c")" -eq 2 ]; check "refused: $c" $?
done
exit $fail
