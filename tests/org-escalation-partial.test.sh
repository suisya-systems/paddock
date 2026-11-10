#!/usr/bin/env bash
# Follow-up test (answer sent, removal fails) for skills/org-escalation/scripts/org-escalation.sh (Issue #66). Needs only
# bash and coreutils: hc is a stub on PATH (documents only), so no core runs. scripts/org is
# the real one, writing under a throwaway state dir.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-escalation/scripts/org-escalation.sh
org=$here/scripts/org
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

[ -f "$script" ]; check "script exists" $?
[ -f "$here/skills/org-escalation/SKILL.md" ]; check "SKILL.md exists" $?
bash -n "$script" 2>/dev/null; check "script parses" $?

# Stub hc: only `hc connect` is used. docval-<name> / docver-<name> in $STUB hold the stored
# document. STUB_SET_ERROR=1 makes every doc.set fail.
stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/calls"
[ "$1" = connect ] || exit 0
read -r req
method=$(printf '%s' "$req" | sed 's/.*"method":"\([^"]*\)".*/\1/')
name=$(printf '%s' "$req" | sed 's/.*"name":"\([^"]*\)".*/\1/')
ver() { cat "$STUB/docver-$name" 2>/dev/null || echo 0; }
val() { cat "$STUB/docval-$name" 2>/dev/null || echo null; }
case "$method" in
  doc.get) printf '{"jsonrpc":"2.0","id":1,"result":{"value":%s,"version":%s}}\n' "$(val)" "$(ver)" ;;
  doc.set)
    [ -z "${STUB_SET_ERROR:-}" ] || { echo '{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"boom"}}'; exit 0; }
    v=$(printf '%s' "$req" | sed 's/.*"version":\([0-9]*\)}}$/\1/')
    printf '%s' "$req" | sed 's/.*"value":\(.*\),"version":[0-9]*}}$/\1/' > "$STUB/docval-$name"
    echo $(( v + 1 )) > "$STUB/docver-$name"
    printf '{"jsonrpc":"2.0","id":1,"result":{"version":%s}}\n' "$(ver)" ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"

export STUB=$tmp/stub; state=$tmp/state; mkdir -p "$STUB"
printf '%s\n' '{"approvals":[{"id":"t3-1","task_id":"t3","question":"Q?","asked_at":"x"}]}' > "$STUB/docval-org-state"
out=$(env -u PADDOCK_ORG_ID PADDOCK_HC_HOLD=0 PADDOCK_NOW=2026-11-10T01:02:03Z PADDOCK_STATE_DIR="$state" \
  PATH="$stubdir:$PATH" STUB_SET_ERROR=1 bash "$script" answer --id t3-1 --text yes 2>&1); rc=$?
[ "$rc" -eq 9 ]; check "answer exits 9 when the send worked but the removal failed" $?
case $out in *"run: remove --id t3-1"*) r=0 ;; *) r=1 ;; esac; check "and says to run remove" $r
m=$(env -u PADDOCK_ORG_ID PADDOCK_STATE_DIR="$state" PADDOCK_NOW=2026-11-10T01:02:03Z bash "$org" --as w-t3 check_messages 2>&1)
case $m in *"Answer to your question (t3-1): yes"*) r=0 ;; *) r=1 ;; esac; check "the worker got the answer" $r
grep -q t3-1 "$STUB/docval-org-state"; check "the entry is still there" $?

[ "$fail" -eq 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
