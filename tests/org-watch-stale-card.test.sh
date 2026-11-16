#!/usr/bin/env bash
# Acceptance test for issue #400 (items 1 and 2): org-watch writes one line to the secretary's
# mailbox for a PR head whose CI is green, with no card for its task and no landing (the task is
# still in org-state.work), N minutes after the green ci_completed; and one line for a card whose
# ANSWER has been in the person's history for N minutes. Once each, not once per pass.
# Stubbed hc (tests/hc-stub.sh), the real scripts/org; no core, no GitHub.
. "$(dirname "${BASH_SOURCE[0]}")/hc-stub.sh"
script=$here/skills/org-watch/scripts/org-watch.sh
T=2026-11-10T00:00:00Z; T0=$(date -u -d "$T" +%s)
o() { local who=$1; shift; PATH="$stubdir:$PATH" STUB="$tmp/stub" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_NOW="$T" \
        PADDOCK_HC_HOLD=0 PADDOCK_NUDGE_RETRY=0 bash "$here/scripts/org" --as "$who" "$@" >/dev/null 2>&1; }
doc() { # doc <work task ids> <approvals json>
  local w= t; for t in $1; do w="$w${w:+,}{\"task_id\":\"$t\"}"; done
  printf '{"jsonrpc":"2.0","id":1,"result":{"value":{"work":[%s],"approvals":[%s]},"version":3}}\n' "$w" "$2" > "$tmp/stub/doc"
}
pass() { ENVX="PADDOCK_WATCH_NOW=$1 PADDOCK_WATCH_N=10 PADDOCK_HC_HOLD=0 PADDOCK_NUDGE_RETRY=0" run_script "$script" --once >/dev/null; }
lines() { o_out=$(PATH="$stubdir:$PATH" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_NOW="$T" bash "$here/scripts/org" --as secretary check_messages --peek 2>/dev/null)
          printf '%s\n' "$o_out" | grep -cF "$1"; }
green() { o secretary ci_requested --pr 42 --sha abc1234 --repo o/r --task t1
          o watcher ci_completed --pr 42 --sha abc1234 --repo o/r --run-id 7 --exit-code 0 --task t1; }
G='PR #42 is green and no card asks about it'
CARD='{"id":"t2-20261110T000000Z","task_id":"t2","question":"Merge?"}'
A='answer for t2-20261110T000000Z arrived; the card is still up'

reset; doc "t1" ""; green
pass $((T0 + 300)); [ "$(lines "$G")" -eq 0 ]; check "green PR before N minutes: no line" $?
pass $((T0 + 700)); [ "$(lines "$G")" -eq 1 ]; check "green PR, no card, no landing after N minutes: one line" $?
pass $((T0 + 730)); [ "$(lines "$G")" -eq 1 ]; check "green PR: not repeated on the next pass" $?
doc "t1" '{"id":"t1-x","task_id":"t1","question":"Merge PR 42?"}'; pass $((T0 + 760)); doc "t1" ""; pass $((T0 + 790))
[ "$(lines "$G")" -eq 1 ]; check "green PR: not told again after a card came and went" $?
T=2026-11-10T00:05:00Z; o secretary ci_requested --pr 42 --sha abc1234 --repo o/r --task t1; T=2026-11-10T00:00:00Z
command rm -f "$tmp/state/watcher/told"; pass $((T0 + 820)); [ "$(lines "$G")" -eq 1 ]; check "green PR: an older success does not answer a newer request of the same head" $?

reset; doc "t1" '{"id":"t1-x","task_id":"t1","question":"Merge PR 42?"}'; green
pass $((T0 + 700)); [ "$(lines "$G")" -eq 0 ]; check "green PR with a card for its task: no line" $?

reset; doc "" ""; green
pass $((T0 + 700)); [ "$(lines "$G")" -eq 0 ]; check "green PR whose task left org-state.work (landed): no line" $?

reset; doc "t1" ""; o secretary ci_requested --pr 42 --sha abc1234 --repo o/r --task t1
o watcher ci_completed --pr 42 --sha abc1234 --repo o/r --run-id 7 --exit-code 1 --task t1
pass $((T0 + 700)); [ "$(lines "is green")" -eq 0 ]; check "red PR: no line" $?

reset; doc "t2" "$CARD"; o person send_message secretary "ANSWER t2-20261110T000000Z yes"
pass $((T0 + 300)); [ "$(lines "$A")" -eq 0 ]; check "answered card before N minutes: no line" $?
pass $((T0 + 700)); [ "$(lines "$A")" -eq 1 ]; check "answered card still up after N minutes: one line" $?
pass $((T0 + 730)); [ "$(lines "$A")" -eq 1 ]; check "answered card: not repeated on the next pass" $?

reset; doc "t2" "$CARD"; o person send_message secretary "hello"
pass $((T0 + 700)); [ "$(lines "arrived; the card")" -eq 0 ]; check "card with no answer: no line" $?

exit "$fail"
