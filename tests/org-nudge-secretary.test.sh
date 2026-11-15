#!/usr/bin/env bash
# Issue #385: every write to the secretary's mailbox is followed by one nudge to an idle secretary
# (hc send --if idle; a `done` one, read with hc get, gets a plain hc send: Issue #388), after the line is written; a refused or failed nudge never fails
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
# like hc 0.1.18: --if takes only idle|working (else usage error, exit 2); blocked 9, other status 10
st=${STATUS:-idle}
case "$1" in
  get) printf '{\n  "name": "%s",\n  "state": "live",\n  "status": {"app":"claude-code","state":"%s"}\n}\n' "$3" "$st"; exit 0 ;;
  send) [ "$2" = --if ] || exit 0
        case "$3" in idle|working) ;; *) echo "error: invalid value '$3' for '--if <STATUS>'" >&2; exit 2 ;; esac
        [ "$st" != blocked ] || exit 9; [ "$st" = "$3" ] || exit 10 ;;
esac
exit 0
EOS
chmod +x "$tmp/bin/hc"
export CALLS=$tmp/calls STATE=$tmp/state
o() { env -u PADDOCK_ORG_ID -u PADDOCK_SECRETARY_NAME PATH="$tmp/bin:$PATH" PADDOCK_STATE_DIR=$STATE bash "$org" "$@"; }
lines() { cat "$STATE"/events/*/*.jsonl 2>/dev/null | wc -l | tr -d ' '; }

: > "$CALLS"; o --as w-t1 report done --task t1 "finished"; rc=$?
[ $rc -eq 0 ]; check "a worker's report exits 0 ($rc)" $?
grep -q '^send --if idle secretary .*check_messages.* lines=1$' "$CALLS"; check "the report nudges the secretary after the line is written" $?
[ "$(grep -c '^send' "$CALLS")" -eq 1 ] && ! grep -q '^get' "$CALLS"; check "one nudge when the idle send goes through" $?
o --as secretary check_messages >/dev/null

: > "$CALLS"; STATUS=done PADDOCK_NUDGE_RETRY=0 o --as w-t1 report done --task t1 "finished"
grep -q '^send secretary .*check_messages' "$CALLS"; check "a secretary whose turn ended (done) gets the nudge" $?
! grep -q '^send --if done' "$CALLS"; check "the nudge never passes --if done (hc rejects it)" $?
o --as secretary check_messages >/dev/null
: > "$CALLS"; STATUS=working PADDOCK_NUDGE_RETRY=0 o --as w-t1 report done --task t1 "finished"
[ "$(grep -c '^send' "$CALLS")" -eq 1 ] && ! grep -q '^send secretary' "$CALLS"; check "a working secretary is not typed into" $?
o --as secretary check_messages >/dev/null

: > "$CALLS"; o --as person send_message secretary "ANSWER a1 yes"
grep -q '^send --if idle secretary ' "$CALLS"; check "the card's ANSWER nudges the secretary" $?

n=$(lines); : > "$CALLS"; STATUS=working PADDOCK_NUDGE_RETRY=0 o --as w-t1 send_message secretary "q?"; rc=$?
[ $rc -eq 0 ] && [ "$(lines)" -eq $((n + 1)) ]; check "a refused nudge does not fail the write ($rc)" $?
grep -q '^get --json secretary' "$CALLS"; check "a send refused on idle reads the status for done" $?

# refused as working (10): retried in the background while the mail is unread, then it stops
: > "$CALLS"; STATUS=working PADDOCK_NUDGE_RETRY=2 PADDOCK_NUDGE_INTERVAL=0.2 o --as w-t3 send_message secretary "late"; sleep 2
[ "$(grep -c '^send --if idle' "$CALLS")" -eq 3 ]; check "a nudge refused as working is retried (1 + 2 tries)" $?
o --as secretary check_messages >/dev/null
: > "$CALLS"; STATUS=working PADDOCK_NUDGE_RETRY=3 PADDOCK_NUDGE_INTERVAL=0.5 o --as w-t3 send_message secretary "read soon"
o --as secretary check_messages >/dev/null; sleep 2
[ "$(grep -c '^send --if idle' "$CALLS")" -eq 1 ]; check "no retry once the mail is read" $?
: > "$CALLS"; STATUS=blocked PADDOCK_NUDGE_INTERVAL=0.2 o --as w-t3 send_message secretary "blocked"; sleep 1
[ "$(grep -c '^send --if idle' "$CALLS")" -eq 1 ]; check "no retry on another failure (blocked, no core)" $?
o --as secretary check_messages >/dev/null

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
