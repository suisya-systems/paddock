#!/usr/bin/env bash
# Acceptance test for Issue #282: an answer forwarded to an idle worker must start its next turn.
# `org-escalation answer` puts the answer in the worker's mailbox; a worker that ended its turn
# (status idle) never reads it, so the script must also nudge it with `hc send --if idle`.
# A working worker is not interrupted. hc is a stub on PATH; scripts/org is the real one.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-escalation/scripts/org-escalation.sh
org=$here/scripts/org
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/calls"
case "$1" in
  get) printf '{"name":"%s","status":{"state":"%s"}}\n' "$3" "${STUB_STATE:-idle}" ;;
  send) exit "${STUB_SEND_RC:-0}" ;;
  connect)
    read -r req
    method=$(printf '%s' "$req" | sed 's/.*"method":"\([^"]*\)".*/\1/')
    ver() { cat "$STUB/docver" 2>/dev/null || echo 0; }
    case "$method" in
      doc.get) printf '{"jsonrpc":"2.0","id":1,"result":{"value":%s,"version":%s}}\n' "$(cat "$STUB/docval" 2>/dev/null || echo null)" "$(ver)" ;;
      doc.set)
        v=$(printf '%s' "$req" | sed 's/.*"version":\([0-9]*\)}}$/\1/')
        printf '%s' "$req" | sed 's/.*"value":\(.*\),"version":[0-9]*}}$/\1/' > "$STUB/docval"
        echo $(( v + 1 )) > "$STUB/docver"
        printf '{"jsonrpc":"2.0","id":1,"result":{"version":%s}}\n' "$(ver)" ;;
    esac ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"

export STUB=$tmp/stub; state=$tmp/state; now=2026-11-10T01:02:03Z
id1=t1-20261110T010203Z
run() { # run <state> <send rc>: ask, then answer, as the secretary
  mkdir -p "$STUB"; : > "$STUB/calls"; rm -f "$STUB"/docver; echo '{"work":[],"approvals":[]}' > "$STUB/docval"
  env -u PADDOCK_ORG_ID -u PADDOCK_SECRETARY_NAME PADDOCK_HC_HOLD=0 PADDOCK_NOW=$now PADDOCK_STATE_DIR="$state" \
    PATH="$stubdir:$PATH" STUB_STATE=$1 STUB_SEND_RC=${2:-0} bash "$script" ask --task t1 --question "Q?" >/dev/null 2>&1
  env -u PADDOCK_ORG_ID -u PADDOCK_SECRETARY_NAME PADDOCK_HC_HOLD=0 PADDOCK_NOW=$now PADDOCK_STATE_DIR="$state" \
    PATH="$stubdir:$PATH" STUB_STATE=$1 STUB_SEND_RC=${2:-0} bash "$script" answer --id "$id1" --text yes >/dev/null 2>&1
}

run idle; rc=$?
[ $rc -eq 0 ]; check "answer to an idle worker exits 0" $?
grep -q '^send --if idle w-t1 ' "$STUB/calls"; check "an idle worker is nudged with hc send --if idle" $?
grep '^send ' "$STUB/calls" | grep -q 'check_messages'; check "the nudge tells it to run check_messages" $?
env -u PADDOCK_ORG_ID PADDOCK_STATE_DIR="$state" PADDOCK_NOW=$now bash "$org" --as w-t1 check_messages 2>&1 | grep -q 'Answer to your question'
check "the answer is still in the mailbox" $?

run working
grep -q '^send ' "$STUB/calls"; [ $? -ne 0 ]; check "a working worker is not nudged" $?

run idle 10; rc=$?
[ $rc -eq 0 ]; check "a refused nudge (exit 10) does not fail the answer" $?

exit $fail
