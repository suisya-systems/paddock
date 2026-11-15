#!/usr/bin/env bash
# Issue #385: every write to the secretary's mailbox is followed by one nudge to an idle secretary
# (hc send --if idle, then --if done), after the line is written; a refused or failed nudge never fails
# the write, and the nudge writes nothing. `org nudge` (the workers' PostToolUse hook, whose own write
# cannot reach hc from the sandbox) nudges only when the secretary has unread mail.
# hc is a stub on PATH that logs each call and whether the write was already on disk. Needs node.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
org=$here/scripts/org
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
mkdir -p "$tmp/bin"
cat > "$tmp/bin/hc" <<'EOS'
#!/bin/sh
n=$(cat "$STATE"/events/*/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
echo "$* lines=$n" >> "$CALLS"
case "$1 $2 $3" in "send --if idle") exit "${RC_IDLE:-0}" ;; "send --if done") exit "${RC_DONE:-0}" ;; esac
exit 0
EOS
chmod +x "$tmp/bin/hc"
export CALLS=$tmp/calls STATE=$tmp/state
o() { env -u PADDOCK_ORG_ID -u PADDOCK_SECRETARY_NAME PATH="$tmp/bin:$PATH" PADDOCK_STATE_DIR=$STATE bash "$org" "$@"; }
lines() { cat "$STATE"/events/*/*.jsonl 2>/dev/null | wc -l | tr -d ' '; }

: > "$CALLS"; o --as w-t1 report done --task t1 "finished"; rc=$?
[ $rc -eq 0 ]; check "a worker's report exits 0 ($rc)" $?
grep -q '^send --if idle secretary .*check_messages.* lines=1$' "$CALLS"; check "the report nudges the secretary after the line is written" $?
[ "$(grep -c '^send' "$CALLS")" -eq 1 ]; check "one nudge when the idle send goes through" $?

: > "$CALLS"; o --as person send_message secretary "ANSWER a1 yes"
grep -q '^send --if idle secretary ' "$CALLS"; check "the card's ANSWER nudges the secretary" $?

: > "$CALLS"; RC_IDLE=10 RC_DONE=10 o --as w-t1 send_message secretary "q?"; rc=$?
[ $rc -eq 0 ] && [ "$(lines)" -eq 3 ]; check "a refused nudge does not fail the write ($rc)" $?
grep -q '^send --if done secretary ' "$CALLS"; check "a send refused on idle is tried on done" $?

: > "$CALLS"; o --as secretary send_message w-t1 "answer"; o --as secretary send_message secretary "self"
! grep -q "^send" "$CALLS"; check "a message to a worker, or the secretary's own line to itself, nudges no one" $?

: > "$CALLS"; o --as secretary check_messages >/dev/null
! grep -q '^send' "$CALLS"; check "the secretary's acks nudge no one (the nudge cannot loop)" $?

: > "$CALLS"; env PATH="$tmp/bin:$PATH" PADDOCK_SECRETARY_NAME=sec2 PADDOCK_STATE_DIR=$STATE bash "$org" --as w-t1 report blocked --task t1 "?"
grep -q '^send --if idle sec2 ' "$CALLS"; check "the nudge goes to \$PADDOCK_SECRETARY_NAME's terminal" $?
o --as secretary check_messages >/dev/null

: > "$CALLS"; o --as nudge nudge; rc=$?
[ $rc -eq 0 ] && ! grep -q '^send' "$CALLS"; check "org nudge with no unread mail sends nothing ($rc)" $?
o --as w-t2 send_message secretary "hi" 2>/dev/null; n=$(lines)
# the hook as the worker settings ship it, outside the sandbox
hook=$(node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); process.stdout.write(s.hooks.PostToolUse[0].hooks[0].command)' "$here/templates/worker-settings.json")
: > "$CALLS"
printf '{"tool_input":{"command":"bash \\"$PADDOCK_ORG\\" --as w-t2 report done --task t2 x"}}' \
  | env -u PADDOCK_SECRETARY_NAME PATH="$tmp/bin:$PATH" PADDOCK_STATE_DIR=$STATE PADDOCK_ORG=$org sh -c "$hook"; rc=$?
[ $rc -eq 0 ] && grep -q '^send --if idle secretary ' "$CALLS"; check "the worker's PostToolUse hook nudges when the secretary has unread mail ($rc)" $?
[ "$(lines)" -eq "$n" ]; check "org nudge writes nothing" $?
: > "$CALLS"
printf '{"tool_input":{"command":"git status"}}' | env PATH="$tmp/bin:$PATH" PADDOCK_STATE_DIR=$STATE PADDOCK_ORG=$org sh -c "$hook"; rc=$?
[ $rc -eq 0 ] && ! grep -q '^send' "$CALLS"; check "the hook ignores a Bash call that is not a mailbox write ($rc)" $?
: > "$CALLS"
printf '{"tool_input":{"command":"report"}}' | env PATH=/usr/bin:/bin PADDOCK_STATE_DIR=$STATE PADDOCK_ORG=$org sh -c "$hook"; rc=$?
[ $rc -eq 0 ]; check "the hook exits 0 with no hc on PATH ($rc)" $?
exit $fail
