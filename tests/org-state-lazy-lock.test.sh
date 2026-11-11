#!/usr/bin/env bash
# Regression test for Issue #76 (review follow-up): org-state writes hold one document lock, so
# parallel --lazy updates and flushes lose no edit; a staged value is dropped, not written, when
# the core moved on after it was staged; rebuild (which holds the lock) does not wait on itself.
# Needs bash and coreutils; hc is a stateful stub, no core runs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
mkdir -p "$tmp/bin"
cat > "$tmp/bin/hc" <<'EOF2'
#!/bin/sh
[ "$1" = connect ] || exit 0
req=$(cat)
ver=$(cat "$STUB/version"); val=$(cat "$STUB/value")
case "$req" in
  *'"doc.set"'*)
    # a doc.set with a stale version is a conflict, as in the real core
    rv=${req##*'"version":'}; rv=${rv%%[!0-9]*}
    if [ "$rv" != "$ver" ]; then echo '{"jsonrpc":"2.0","id":1,"error":{"message":"conflict"}}'; exit 0; fi
    echo set >> "$STUB/sets"
    v=${req#*'"value":'}; v=${v%%,\"version\":*}
    sleep 0.05
    printf '%s' "$v" > "$STUB/value"; echo $((ver + 1)) > "$STUB/version"
    echo '{"jsonrpc":"2.0","id":1,"result":{"version":'$((ver + 1))'}}' ;;
  *) echo '{"jsonrpc":"2.0","id":1,"result":{"value":'"$val"',"version":'"$ver"'}}' ;;
esac
EOF2
chmod +x "$tmp/bin/hc"
export STUB=$tmp/stub PADDOCK_STATE_DIR=$tmp/state PADDOCK_HC_HOLD=0 PADDOCK_DOC_INTERVAL=3600 PADDOCK_LOCK_WAIT=20 PATH="$tmp/bin:$PATH"
reset() { rm -rf "$STUB" "$PADDOCK_STATE_DIR"; mkdir -p "$STUB" "$PADDOCK_STATE_DIR"
  echo '{"work":[],"approvals":[]}' > "$STUB/value"; echo 1 > "$STUB/version"; : > "$STUB/sets"; }
org() { bash "$here/scripts/org" --as secretary "$@"; }
# add <n>: append task t<n> to work, valid JSON either way.
add() { local n=$1; shift; org doc update org-state "$@" -- sed -e "s/\"work\":\[\]/\"work\":[\"t$n\"]/" -e t -e "s/\"work\":\[/\"work\":[\"t$n\",/"; }

# 1. Parallel lazy updates and flushes: every edit is in the core after the last flush.
reset
add 0 --lazy                       # first write goes through; the rest stage
for n in 1 2 3 4 5 6 7 8; do add $n --lazy 2>/dev/null & org doc flush org-state 2>/dev/null & done
wait
org doc flush org-state
v=$(cat "$STUB/value"); miss=
for n in 0 1 2 3 4 5 6 7 8; do case "$v" in *"\"t$n\""*) ;; *) miss="$miss t$n" ;; esac; done
[ -z "$miss" ]; check "9 parallel lazy edits and flushes: none lost (missing:${miss:- none})" $?
[ ! -e "$PADDOCK_STATE_DIR/org-state.staged" ]; check "nothing is left staged" $?

# 2. The core moved on after the edit was staged.
reset
add 1 --lazy; add 2 --lazy        # t1 written, t2 staged at version 2
printf '%s' '{"work":["t1","other"],"approvals":[]}' > "$STUB/value"; echo 3 > "$STUB/version"
sets_before=$(wc -l < "$STUB/sets")
org doc flush org-state 2>/dev/null; rc=$?
[ "$rc" -eq 9 ] && [ "$(wc -l < "$STUB/sets")" -eq "$sets_before" ] && [ "$(cat "$STUB/value")" = '{"work":["t1","other"],"approvals":[]}' ]
check "flush of a stale stage exits 9 and writes nothing (the other writer's change stays)" $?
[ ! -e "$PADDOCK_STATE_DIR/org-state.staged" ]; check "the stale stage is dropped" $?
reset
add 1 --lazy; add 2 --lazy
printf '%s' '{"work":["t1","other"],"approvals":[]}' > "$STUB/value"; echo 3 > "$STUB/version"
add 3 >/dev/null 2>&1; v=$(cat "$STUB/value")
case "$v" in *other*t3*|*t3*other*) case "$v" in *t2*) ok=1 ;; *) ok=0 ;; esac ;; *) ok=1 ;; esac
[ "$ok" -eq 0 ]; check "a later edit is applied to the core's value, not to the stale stage" $?

# 3. rebuild holds the lock and calls doc set: no wait on its own lock.
reset
printf '%s' '{"work":["x"],"approvals":[]}' > "$STUB/value"
SECONDS=0; PADDOCK_LOCK_WAIT=3 org rebuild >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ "$SECONDS" -lt 3 ] && [ "$(cat "$STUB/value")" = '{"work":[],"approvals":[]}' ]; check "rebuild writes without waiting on its own document lock" $?
[ "$fail" -eq 0 ]
