#!/usr/bin/env bash
# Acceptance test for Issue #444 (decision 0015): a yes/no proposal of the secretary's own.
# `ask --self` records it hidden (show_at = asked_at + N minutes, and the person's chat-line token it
# saw); `sweep` shows it at show_at when the token has not moved, and withdraws it when the person
# wrote in chat (the UserPromptSubmit hook moved the token). Its ANSWER passes the person-file check
# and reaches the secretary only: nothing goes to any w-* and hc sends nothing.
# hc is a stub (documents); scripts/org is the real one, under a throwaway state dir.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-escalation/scripts/org-escalation.sh
hook=$here/scripts/hooks/premise-reminder.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

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
    v=$(printf '%s' "$req" | sed 's/.*"version":\([0-9]*\)}}$/\1/')
    printf '%s' "$req" | sed 's/.*"value":\(.*\),"version":[0-9]*}}$/\1/' > "$STUB/docval-$name"
    echo $(( v + 1 )) > "$STUB/docver-$name"
    printf '{"jsonrpc":"2.0","id":1,"result":{"version":%s}}\n' "$(ver)" ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"
export STUB=$tmp/stub; state=$tmp/state; unset PADDOCK_SELF_CARD_N
T=2026-11-16T09:00:00Z; ID=secretary-20261116T090000Z
esc() { # esc <now> <args...>
  local n=$1; shift
  env -u PADDOCK_ORG_ID -u PADDOCK_SECRETARY_NAME PADDOCK_HC_HOLD=0 PADDOCK_STATE_DIR="$state" \
      PADDOCK_NOW="$n" PATH="$stubdir:$PATH" bash "$script" "$@" 2>&1
}
org() { local n=$1; shift; PADDOCK_HC_HOLD=0 PADDOCK_STATE_DIR="$state" PADDOCK_NOW="$n" PATH="$stubdir:$PATH" bash "$here/scripts/org" "$@" >/dev/null 2>&1; }
typed() { printf '{"hook_event_name":"UserPromptSubmit","prompt":"%s"}' "$1" | PADDOCK_STATE_DIR="$state" sh "$hook" >/dev/null 2>&1; }
doc() { cat "$STUB/docval-org-state"; }
fresh() { rm -rf "$STUB" "$state"; mkdir -p "$STUB" "$state"; : > "$STUB/calls"; echo '{"work":[],"approvals":[]}' > "$STUB/docval-org-state"; }
propose() { esc "$T" ask --self --question "Merge the two PRs now?" --background "Both are green." \
  --if-yes "I merge both." --if-no "I wait." --recommend yes --why "Nothing blocks them." --lang en; }
noworker() { ! grep -rqs '"to":"w-' "$state/events" && ! grep -q '^send' "$STUB/calls"; }

# the hook: a person line moves the token; the watcher's wake line and a first message do not
fresh; typed "please merge"; t1=$(cat "$state/secretary/person-line" 2>/dev/null)
[ -n "$t1" ]; check "hook: a line the person typed writes the token" $?
typed 'You have mail: run bash \"$PADDOCK_HOME/scripts/org\" --as secretary check_messages and act on it.'
[ "$(cat "$state/secretary/person-line")" = "$t1" ]; check "hook: the watcher's wake line does not move it" $?
typed "You are the secretary of a paddock organization. You are the one agent the person talks to."
[ "$(cat "$state/secretary/person-line")" = "$t1" ]; check "hook: a secretary's first message does not move it" $?
typed "ok"; [ "$(cat "$state/secretary/person-line")" != "$t1" ]; check "hook: the next person line moves it" $?

# ask --self: hidden, with show_at and the token it saw
fresh; typed "what next?"; tok=$(cat "$state/secretary/person-line")
out=$(propose); rc=$?
[ $rc -eq 0 ] && [ "$out" = "APPROVAL_ID=$ID" ]; check "ask --self prints APPROVAL_ID=secretary-<UTC>" $?
case $(doc) in *"\"task_id\":\"secretary\""*"\"origin\":\"secretary\""*"\"show_at\":\"2026-11-16T09:10:00Z\",\"seen\":\"$tok\""*) r=0 ;; *) r=1 ;; esac
check "the entry is hidden until asked_at + 10 minutes and records the token" $r
esc "$T" ask --self --task t1 --question "x?" >/dev/null; [ $? -eq 2 ]; check "ask --self with --task exits 2" $?
esc "$T" ask --self --question "x?" --prompt "Do you want?" >/dev/null; [ $? -eq 2 ]; check "ask --self with --prompt exits 2" $?
PADDOCK_SELF_CARD_N=3 esc 2026-11-16T09:30:00Z ask --self --question "Other?" >/dev/null 2>&1
grep -q '"id":"secretary-20261116T093000Z"[^}]*"show_at":"2026-11-16T09:33:00Z"' "$STUB/docval-org-state"; check "a second proposal gets its own id; PADDOCK_SELF_CARD_N sets its minutes" $?

# before N minutes: sweep keeps it hidden
fresh; typed "what next?"; propose >/dev/null
out=$(esc 2026-11-16T09:09:59Z sweep); grep -q '"show_at"' "$STUB/docval-org-state" && [ -z "$out" ]
check "before N minutes with no person line: kept hidden" $?
# after N minutes with no person line: shown (show_at gone, the rest kept), recorded for rebuild
out=$(esc 2026-11-16T09:10:00Z sweep)
[ "$out" = "SHOWN $ID" ]; check "after N minutes with no person line: SHOWN" $?
d=$(doc); case $d in *"\"id\":\"$ID\""*) case $d in *show_at*) r=1 ;; *'"recommend":"yes"'*'"origin":"secretary"'*) r=0 ;; *) r=1 ;; esac ;; *) r=1 ;; esac
check "the shown entry keeps its fields and loses show_at" $r
reb=$(PADDOCK_HC_HOLD=0 PADDOCK_STATE_DIR="$state" PATH="$stubdir:$PATH" bash "$here/scripts/org" --as secretary rebuild --print 2>/dev/null)
case $reb in *"\"id\":\"$ID\""*show_at*) r=1 ;; *"\"id\":\"$ID\""*) r=0 ;; *) r=1 ;; esac
check "rebuild replays the shown entry once, without show_at" $r
out=$(esc 2026-11-16T09:20:00Z sweep); [ -z "$out" ]; check "a shown card is not swept again" $?

# a person line in chat before N minutes: withdrawn
fresh; typed "what next?"; propose >/dev/null; typed "actually, wait"
out=$(esc 2026-11-16T09:05:00Z sweep)
[ "$out" = "WITHDRAWN $ID" ] && ! grep -q "$ID" "$STUB/docval-org-state"; check "a person line in chat withdraws it" $?
fresh; propose >/dev/null; typed "hello"
out=$(esc 2026-11-16T09:12:00Z sweep); [ "$out" = "WITHDRAWN $ID" ]; check "with no token at the ask, the first person line withdraws it (even past show_at)" $?

# the answer: checked against the person's file, reaches the secretary only
fresh; typed "what next?"; propose >/dev/null; esc 2026-11-16T09:10:00Z sweep >/dev/null
org 2026-11-16T09:11:00Z --as w-t1 send_message secretary "ANSWER $ID yes"
out=$(esc 2026-11-16T09:12:00Z answer --id "$ID" --text yes); rc=$?
[ $rc -eq 2 ] && grep -q "$ID" "$STUB/docval-org-state"; check "an ANSWER from a worker is refused (exit 2), entry kept" $?
org 2026-11-16T09:11:00Z --as person send_message secretary "ANSWER $ID yes; note: after lunch"
out=$(esc 2026-11-16T09:12:00Z answer --id "$ID" --text yes --note "after lunch"); rc=$?
[ $rc -eq 0 ]; check "the person's ANSWER passes the person-file check" $?
case $out in *"FROM_PERSON $ID "*"ANSWERED $ID -> secretary: yes"*"NOTE $ID after lunch"*) r=0 ;; *) r=1 ;; esac; check "it prints FROM_PERSON, ANSWERED -> secretary and the note" $r
! grep -q "$ID" "$STUB/docval-org-state"; check "the entry is removed" $?
noworker; check "nothing is sent to any w-* (no mailbox line, no hc send)" $?
# answered in chat while still hidden
fresh; propose >/dev/null
out=$(esc 2026-11-16T09:02:00Z answer --id "$ID" --text no --from-conversation "no, not today"); rc=$?
[ $rc -eq 0 ] && case $out in *"FROM_CONVERSATION $ID: no, not today"*"ANSWERED $ID -> secretary: no"*) true ;; *) false ;; esac
check "a hidden proposal answered in chat: --from-conversation, to the secretary" $?
noworker; check "and nothing to any w-*" $?

[ "$fail" -eq 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
