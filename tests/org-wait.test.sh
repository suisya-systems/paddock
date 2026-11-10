#!/usr/bin/env bash
# Acceptance test for `org wait` (Issue #140): a mailbox message reaches a secretary that is
# waiting between turns. Needs only bash and coreutils: hc is a stub on PATH, so no core runs.
# scripts/org and the org-escalation skill are the real ones, writing under a throwaway state dir.
# Checked: `org wait` returns {"reason":"mail"} at once on unread mail and within seconds when
# the card's `ANSWER <id> yes` arrives during the wait, leaving it unread; returns
# {"reason":"timeout"} after --timeout; with --children passes through hc wait's `children`
# line and ignores an hc wait that fails at once; bad usage exits 2; the whole chain card
# message -> org wait -> check_messages -> org-escalation answer reaches the worker's mailbox;
# and the secretary template tells it to end its turns in `org wait` while work or approvals
# are in progress, except right after a handover.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
org=$here/scripts/org
esc_script=$here/skills/org-escalation/scripts/org-escalation.sh
tmp=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

# Stub hc. `hc wait` behaves per $STUB_WAIT: "children" prints a children line after 1 s,
# "fail" exits 7 at once (needs_target), anything else sleeps past every test bound.
# `hc connect` serves the org-state document from $STUB (as in org-escalation.test.sh).
stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/calls"
case "$1" in
  wait)
    case "${STUB_WAIT:-}" in
      children) sleep 1; echo '{"reason":"children","children":[{"address":"t2","ended":true,"exit_code":0}]}' ;;
      fail) echo 'hc: needs_target: run it inside a terminal, or name the parent' >&2; exit 7 ;;
      *) sleep 60; echo '{"reason":"timeout"}' ;;
    esac
    exit 0 ;;
  connect) ;;
  *) exit 0 ;;
esac
read -r req
method=$(printf '%s' "$req" | sed 's/.*"method":"\([^"]*\)".*/\1/')
name=$(printf '%s' "$req" | sed 's/.*"name":"\([^"]*\)".*/\1/')
ver() { cat "$STUB/docver-$name" 2>/dev/null || echo 0; }
val() { cat "$STUB/docval-$name" 2>/dev/null || echo null; }
case "$method" in
  doc.get) printf '{"jsonrpc":"2.0","id":1,"result":{"value":%s,"version":%s}}\n' "$(val)" "$(ver)" ;;
  doc.set)
    v=$(printf '%s' "$req" | sed 's/.*"version":\([0-9]*\)}}$/\1/')
    printf '%s' "$req" | sed 's/.*"value":\(.*\),"version":[0-9]*}}$/\1/' > "$STUB/docval-$name"
    echo $(( v + 1 )) > "$STUB/docver-$name"
    printf '{"jsonrpc":"2.0","id":1,"result":{"version":%s}}\n' "$(ver)" ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"

export STUB=$tmp/stub; mkdir -p "$STUB"; : > "$STUB/calls"
state=$tmp/state
now=2026-11-10T01:02:03Z
o() { # o <id> <args...>: the real org as <id>, against the throwaway state and the stub hc
  local who=$1; shift
  env -u PADDOCK_ORG_ID -u PADDOCK_SECRETARY_NAME PADDOCK_HC_HOLD=0 PADDOCK_NOW=$now \
      PADDOCK_STATE_DIR="$state" PADDOCK_WAIT_POLL=0.2 PATH="$stubdir:$PATH" \
      bash "$org" --as "$who" "$@"
}
elapsed_since() { echo $(( $(date +%s) - $1 )); }

# --help names the command.
o secretary --help 2>&1 | grep -q '^  wait '; check "--help lists wait" $?

# Bad usage exits 2.
o secretary wait --timeout x >/dev/null 2>&1; [ $? -eq 2 ]; check "wait --timeout x exits 2" $?
o secretary wait --bogus >/dev/null 2>&1; [ $? -eq 2 ]; check "wait --bogus exits 2" $?

# No mail: it holds until --timeout, then checks in like hc wait.
t0=$(date +%s); out=$(o secretary wait --timeout 2 2>&1); rc=$?; el=$(elapsed_since "$t0")
[ $rc -eq 0 ]; check "timeout exits 0" $?
printf '%s' "$out" | grep -q '"reason":"timeout"'; check "timeout prints reason timeout" $?
[ "$el" -ge 2 ] && [ "$el" -le 6 ]; check "timeout held about 2 s (held ${el}s)" $?

# A message that arrives during the wait (what the card sends) ends it within seconds.
o secretary wait --timeout 30 > "$tmp/w1.out" 2>&1 & wpid=$!
sleep 1
t0=$(date +%s)
o person send_message secretary "ANSWER t1-20261110T010203Z yes"
wait $wpid; rc=$?; el=$(elapsed_since "$t0")
[ $rc -eq 0 ]; check "mail during the wait exits 0" $?
grep -q '"reason":"mail"' "$tmp/w1.out" && grep -q '"unread":1' "$tmp/w1.out"
check "mail during the wait prints reason mail, unread 1" $?
[ "$el" -le 5 ]; check "mail ended the wait within seconds (${el}s)" $?
o secretary check_messages --peek | grep -q 'ANSWER t1-20261110T010203Z yes'
check "the wait left the message unread" $?

# Unread mail already there: it returns at once.
t0=$(date +%s); out=$(o secretary wait --timeout 30 2>&1); el=$(elapsed_since "$t0")
printf '%s' "$out" | grep -q '"reason":"mail"' && [ "$el" -le 3 ]; check "unread at start returns at once" $?

# Another agent's mail does not wake this one.
o secretary check_messages >/dev/null
o person send_message w-t1 "not for the secretary"
out=$(o secretary wait --timeout 2 2>&1)
printf '%s' "$out" | grep -q '"reason":"timeout"'; check "mail for someone else does not end the wait" $?

# --children: hc wait's children line comes through.
out=$(STUB_WAIT=children o secretary wait --children --timeout 20 2>&1)
printf '%s' "$out" | grep -q '"reason":"children"'; check "--children passes through hc wait's children line" $?
grep -q '^wait --children any' "$STUB/calls"; check "--children runs hc wait --children any" $?

# --children with an hc wait that fails at once: ignored, mail still ends the wait.
STUB_WAIT=fail o secretary wait --children --timeout 30 > "$tmp/w2.out" 2>&1 & wpid=$!
sleep 2
kill -0 $wpid 2>/dev/null; check "--children: a failing hc wait does not end the wait" $?
o person send_message secretary "ANSWER t1-x no"
wait $wpid
grep -q '"reason":"mail"' "$tmp/w2.out"; check "--children: mail still ends the wait" $?
o secretary check_messages >/dev/null

# The whole chain, stubbed: an approval is pending, the secretary waits, the card's answer
# arrives, the wait returns, the secretary reads it and forwards it with org-escalation.
printf '%s\n' '{"work":[{"task_id":"t1","title":"A","since":"2026-11-10T00:00:00Z"}],"approvals":[{"id":"t1-20261110T010203Z","task_id":"t1","question":"Run npm publish?","asked_at":"2026-11-10T01:02:03Z"}]}' > "$STUB/docval-org-state"
o secretary wait --children --timeout 30 > "$tmp/w3.out" 2>&1 & wpid=$!
sleep 1
o person send_message secretary "ANSWER t1-20261110T010203Z yes"
wait $wpid
grep -q '"reason":"mail"' "$tmp/w3.out"; check "chain: the wait returns on the card's answer" $?
msg=$(o secretary check_messages)
aid=$(printf '%s\n' "$msg" | sed -n 's/^ANSWER \([A-Za-z0-9_-]*\) \(yes\|no\)$/\1/p' | head -1)
ans=$(printf '%s\n' "$msg" | sed -n 's/^ANSWER [A-Za-z0-9_-]* \(yes\|no\)$/\1/p' | head -1)
[ "$aid" = t1-20261110T010203Z ] && [ "$ans" = yes ]; check "chain: the secretary reads ANSWER <id> yes" $?
env -u PADDOCK_ORG_ID -u PADDOCK_SECRETARY_NAME PADDOCK_HC_HOLD=0 PADDOCK_NOW=$now \
  PADDOCK_STATE_DIR="$state" PATH="$stubdir:$PATH" bash "$esc_script" answer --id "$aid" --text "$ans" >/dev/null 2>&1
check "chain: org-escalation answer exits 0" $?
o w-t1 check_messages | grep -q 'Answer to your question (t1-20261110T010203Z): yes'
check "chain: the worker's mailbox holds the answer" $?
! grep -q t1-20261110T010203Z "$STUB/docval-org-state"; check "chain: the approval is gone from org-state" $?

# The secretary template: end turns in org wait while work or approvals are in progress.
tpl=$here/templates/secretary.md
grep -q 'scripts/org --as secretary wait --children' "$tpl"; check "template names org wait --children" $?
grep -Eq '`work` or `approvals`' "$tpl"; check "template ties the wait to work or approvals in org-state" $?
grep -qi 'handover' "$tpl" && grep -Eiq 'except.*handover|handover.*(end the turn|ends? your turn)' "$tpl"
check "template makes the handover an exception to the wait" $?
grep -q 'Esc' "$tpl"; check "template says how a person interrupts the wait (Esc)" $?

exit $fail
