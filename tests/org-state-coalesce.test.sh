#!/usr/bin/env bash
# Acceptance test for Issue #76: org-state writes are coalesced so doc events do not flood
# `hc events`. Every doc.set is one doc event, so the count of doc.set calls to a stateful hc
# stub is the event count. Measured here (n = 10 edits in a burst):
#   before: 10 doc.set (one per edit)    after: 2 (first edit at once, the rest in one flush)
# and a write that changes nothing makes no doc.set at all. The mods only read (doc.get), so a
# refresh on a doc event never writes. Needs bash and coreutils; no core runs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
mkdir -p "$tmp/bin"
# A stateful hc: doc.get answers the stored value and version, doc.set stores and counts.
cat > "$tmp/bin/hc" <<'EOF2'
#!/bin/sh
[ "$1" = connect ] || exit 0
req=$(cat)
ver=$(cat "$STUB/version"); val=$(cat "$STUB/value")
case "$req" in
  *'"doc.set"'*)
    echo set >> "$STUB/sets"
    v=${req#*'"value":'}; v=${v%%,\"version\":*}
    case "$v" in *",]"*|*"[,"*|*",,"*|*"\"\""*) echo '{"jsonrpc":"2.0","id":1,"error":{"message":"invalid JSON"}}'; exit 0 ;; esac
    printf '%s' "$v" > "$STUB/value"; echo $((ver + 1)) > "$STUB/version"
    echo '{"jsonrpc":"2.0","id":1,"result":{"version":'$((ver + 1))'}}' ;;
  *) echo '{"jsonrpc":"2.0","id":1,"result":{"value":'"$val"',"version":'"$ver"'}}' ;;
esac
EOF2
chmod +x "$tmp/bin/hc"
export STUB=$tmp/stub PADDOCK_STATE_DIR=$tmp/state PADDOCK_HC_HOLD=0 PATH="$tmp/bin:$PATH"
reset() { rm -rf "$STUB" "$PADDOCK_STATE_DIR"; mkdir -p "$STUB" "$PADDOCK_STATE_DIR"
  echo '{"work":[],"approvals":[]}' > "$STUB/value"; echo 1 > "$STUB/version"; : > "$STUB/sets"; }
eq() { local got; got=$(sets); if [ "$got" -eq "$2" ]; then check "$1" 0; else check "$1 (got $got, want $2)" 1; fi; }
sets() { wc -l < "$STUB/sets" | tr -d ' '; }
org() { bash "$here/scripts/org" --as secretary "$@"; }
# An edit that appends task N to work.
add() { org doc update org-state "$@" -- sed -e "s/\"work\":\[\]/\"work\":[\"t$n\"]/" -e t -e "s/\"work\":\[/\"work\":[\"t$n\",/"; }

# 1. Unchanged value: no doc.set, so no doc event.
reset
for n in 1 2 3; do org doc update org-state -- cat; done
eq "an update that changes nothing makes no doc.set (3 tries)" 0
echo '{"work":[],"approvals":[]}' | org doc set org-state
eq "a set of the value already there makes no doc.set" 0

# 2. A burst of lazy edits: the first goes through, the rest wait for the interval or a flush.
reset
export PADDOCK_DOC_INTERVAL=3600
for n in 1 2 3 4 5 6 7 8 9 10; do add --lazy; done
eq "10 lazy edits make 1 doc.set before the flush" 1
org doc flush org-state
eq "the flush makes the 2nd and last doc.set" 2
v=$(cat "$STUB/value"); for n in 1 5 10; do case "$v" in *"t$n"*) ;; *) v= ;; esac; done
[ -n "$v" ]; check "after the flush the core holds every edit" $?
org doc flush org-state
eq "a flush with nothing staged makes no doc.set" 2

# 3. An edit without --lazy (an approval card) is written at once, with the staged edits.
reset
n=1; add --lazy; n=2; add --lazy
org doc update org-state -- sed 's/"approvals":\[\]/"approvals":["a1"]/'
eq "a non-lazy edit is written at once, with the staged edits" 2
v=$(cat "$STUB/value"); case "$v" in *t1*) case "$v" in *t2*) case "$v" in *a1*) ok=0 ;; *) ok=1 ;; esac ;; *) ok=1 ;; esac ;; *) ok=1 ;; esac
[ "$ok" -eq 0 ]; check "that write carries the staged edits and the approval" $?

# 4. wait flushes what is staged (a crash loses at most one wait interval of edits).
reset
n=1; add --lazy; n=2; add --lazy
PADDOCK_WAIT_POLL=0 bash "$here/scripts/org" --as secretary wait --timeout 1 >/dev/null 2>&1
eq "org wait flushes staged org-state before it returns" 2

# 5. Only the secretary flushes.
reset
bash "$here/scripts/org" --as w-1 doc flush org-state >/dev/null 2>&1; [ "$?" -eq 7 ]; check "a worker's doc flush exits 7" $?

# 5b. --record (Issue #77) is written with the document, never ahead of it: --lazy with --record
# is refused (nothing written, no history line); a recorded edit after a staged one writes both
# at once, and its history line comes after the doc.set.
reset
n=1; add --lazy; n=2; add --lazy
org doc update org-state --lazy --record work_added --task t3 --text x -- cat >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ! cat "$PADDOCK_STATE_DIR"/events/*/secretary.jsonl 2>/dev/null | grep -q work_added; check "--lazy with --record exits 2 and records nothing" $?
n=3; org doc update org-state --record work_added --task t3 --text '{"task_id":"t3"}' -- sed -e "s/\"work\":\[/\"work\":[\"t$n\",/" >/dev/null
eq "a recorded edit is written at once with the staged one" 2
v=$(cat "$STUB/value"); case "$v" in *t2*t3*|*t3*t2*) ok=0 ;; *) ok=1 ;; esac
[ "$ok" -eq 0 ] && cat "$PADDOCK_STATE_DIR"/events/*/secretary.jsonl | grep -q '"kind":"work_added"'; check "the core holds the staged edit and the recorded one, and the history line exists" $?
[ ! -s "$PADDOCK_STATE_DIR/org-state.staged" ]; check "nothing is left staged after the recorded write" $?

# 6. The mods read org-state only: a refresh on a doc event cannot write one.
! grep -Eq 'doc\.set|doc (set|update|flush)' "$here"/mods/*/main.js; check "no mod calls doc.set (mods only doc.get)" $?
[ "$fail" -eq 0 ]
