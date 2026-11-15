#!/usr/bin/env bash
# Issue #282, rewritten for decision 0013 stage 3: an answer forwarded to an idle worker must start its
# next turn. `org-escalation answer` only puts the answer in the worker's mailbox and types nothing;
# org-watch wakes an idle or done worker with unread mail (tests/org-watch-wake.test.sh, "idle worker
# with unread mail"), and what it reads is the worker's check_messages --peek, checked here.
# hc is a stub on PATH; scripts/org is the real one.
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
    PATH="$stubdir:$PATH" STUB_STATE=$1 STUB_SEND_RC=${2:-0} bash "$script" answer --from-conversation "test: the person typed it" --id "$id1" --text yes >/dev/null 2>&1
}

run idle; rc=$?
[ $rc -eq 0 ]; check "answer to an idle worker exits 0" $?
! grep -q '^send' "$STUB/calls"; check "answer types nothing into the worker (no #282 nudge; the watcher wakes it)" $?
env -u PADDOCK_ORG_ID PADDOCK_STATE_DIR="$state" PADDOCK_NOW=$now bash "$org" --as w-t1 check_messages --peek 2>&1 | grep -q 'Answer to your question'
check "the answer is unread in the worker's mailbox, which is what the watcher's wake reads" $?
! grep -q 'hc send --if idle' "$script"; check "org-escalation.sh has no idle-worker send left" $?

exit $fail
