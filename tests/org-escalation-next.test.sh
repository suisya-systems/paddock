#!/usr/bin/env bash
# Decision 0014, wave 2 unit 4: org-escalation. Every non-zero exit of the script prints one
# `next: <action>` line; SKILL.md has the 0014 form (when_to_use, body cap, no exit-code table,
# allowed-tools for its own script); the escalation rules left the secretary template for the skill.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-escalation/scripts/org-escalation.sh
skill=$here/skills/org-escalation/SKILL.md
tpl=$here/templates/secretary.md
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# Stub hc: documents (docval-<name>) and a screen for `hc read` ($STUB/screen).
stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
case "$1" in
  read) cat "$STUB/screen" 2>/dev/null; exit 0 ;;
  connect) ;;
  *) exit 0 ;;
esac
read -r req
method=$(printf '%s' "$req" | sed 's/.*"method":"\([^"]*\)".*/\1/')
name=$(printf '%s' "$req" | sed 's/.*"name":"\([^"]*\)".*/\1/')
case "$method" in
  doc.get) printf '{"jsonrpc":"2.0","id":1,"result":{"value":%s,"version":0}}\n' "$(cat "$STUB/docval-$name" 2>/dev/null || echo null)" ;;
  doc.set) printf '{"jsonrpc":"2.0","id":1,"result":{"version":1}}\n' ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"
export STUB=$tmp/stub; mkdir -p "$STUB"
esc() { env -u PADDOCK_ORG_ID PADDOCK_HC_HOLD=0 PADDOCK_NOW=2026-11-10T01:02:03Z PADDOCK_STATE_DIR="$tmp/state" PATH="$stubdir:$PATH" bash "$script" "$@" 2>&1; }

# nextcase <name> <expected exit> <expected next: prefix> <args...>
nextcase() {
  local name=$1 want=$2 pre=$3 out rc n; shift 3
  out=$(esc "$@"); rc=$?
  n=$(printf '%s\n' "$out" | grep -c '^next: ')
  [ "$rc" -eq "$want" ] && [ "$n" -eq 1 ] && printf '%s\n' "$out" | tail -n 1 | grep -q "^next: $pre"
  check "$name: exit $want ends in one 'next: $pre...' line" $?
}
printf '{"approvals":[]}\n' > "$STUB/docval-org-state"
nextcase "ask without --task" 2 "" ask
nextcase "unknown command" 2 "" bogus
nextcase "answer without an id" 2 "" answer
nextcase "answer to an unknown id" 6 "run list" answer --id t9-20261110T010203Z --text yes
nextcase "remove an unknown id" 6 "run list" remove --id t9-20261110T010203Z
nextcase "prompt on an empty screen" 11 "" prompt --task t1
printf '[1,2]\n' > "$STUB/docval-org-state"
nextcase "ask into a document that is not an object" 5 "tell the person" ask --task t1 --question q
printf '{"approvals":[]}\n' > "$STUB/docval-org-state"
printf 'Allow it to run rm?\n  1. Yes\n  2. No\n' > "$STUB/screen"
nextcase "prompt not in the policy list" 3 "ask --task t1" prompt --task t1
out=$(esc --help); printf '%s\n' "$out" | grep -q 'next:'; check "--help names the next: line" $?

# SKILL.md form
fm=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$skill")
body=$(awk 'f { print } NR > 1 && $0 == "---" { f = 1 }' "$skill")
printf '%s\n' "$fm" | grep -Eq '^when_to_use:[[:space:]]*[^[:space:]]'; check "SKILL.md has when_to_use" $?
[ "$(printf '%s' "$fm" | wc -c)" -lt 1536 ]; check "front matter under 1,536 characters" $?
[ "$(printf '%s' "$body" | wc -c)" -lt 12288 ]; check "body under 12 KB" $?
printf '%s\n' "$fm" | grep -Eq '^allowed-tools:.*org-escalation\.sh'; check "allowed-tools names the skill's own script" $?
! grep -q '^## Exit codes' "$skill"; check "no exit-code table in SKILL.md (it is next: lines)" $?
grep -q 'next:' "$skill"; check "SKILL.md points at the next: line" $?

# The template L95-L96 moved into the skill
! grep -q 'org-escalation.sh ask --task' "$tpl"; check "template no longer carries the ask command line" $?
grep -q 'paddock:org-escalation' "$tpl"; check "template names the paddock:org-escalation skill" $?
grep -q 'fresh read' "$here/templates/secretary-rules.md"; check "the rules file keeps: a prompt is answered only after a fresh read of its screen" $?
grep -q -- '--from-conversation "<their line, as typed>"' "$skill" && grep -q 'remove --id <approval_id> --text yes|no' "$skill"; check "SKILL.md carries remove --text and --from-conversation" $?
[ "$fail" -eq 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
