#!/bin/sh
# Secretary Stop guard (Issue #380): a Stop hook (templates/secretary-settings.json). While org-state
# has a work or approvals entry, a worker's report or the card's ANSWER reaches the secretary only on
# its own turn, so an idle secretary never sees it. Exit 2 refuses the stop and tells it to wait;
# exit 0 lets it stop.
# - Allowed: both lists empty, or secretary-handover written (the handover script needs it idle; the new
#   secretary reads the mailbox on resume, so an ANSWER that came in meanwhile is not lost).
# - stop_hook_active is ignored on purpose: honouring it would let the second stop through and reopen
#   the bug. Each refusal leads to org wait --children, which holds up to its timeout, so a refusal costs
#   at most one turn per wait. Esc still stops the secretary (a Stop hook does not run on an interrupt), and
#   Claude Code ends the turn after 8 blocks in a row with no tool call (CLAUDE_CODE_STOP_HOOK_BLOCK_CAP).
# - Fails open: if org-state (or the handover document) cannot be read, the stop is allowed and stderr says why.
# ponytail: "non-empty" is a grep on the joined value for a key followed by "[" and a non-"]" character;
# a string value holding the literal text "work":[x is escaped (\"work\") and does not match.
cat >/dev/null 2>&1   # the payload is not needed
org="$(dirname "$0")/org"
get() { bash "$org" --as secretary doc get "$1" 2>&1; }
state=$(get org-state) || { echo "org: secretary-stop-guard: cannot read org-state, stop allowed: $(printf '%s' "$state" | head -c 200)" >&2; exit 0; }
printf '%s' "$state" | tr -d '\n' | grep -Eq '(^|[^\\])"(work|approvals)" *: *\[ *[^] ]' || exit 0
ho=$(get secretary-handover) || { echo "org: secretary-stop-guard: cannot read secretary-handover, stop allowed: $(printf '%s' "$ho" | head -c 200)" >&2; exit 0; }
[ "$(printf '%s' "$ho" | tr -d ' \n')" = null ] || [ -z "$ho" ] || exit 0
echo "org: refused: org-state has a work or approvals entry, so do not end the turn idle: a worker's report or the card's ANSWER reaches you only on your own turn. End the turn with ONE Bash call, its tool timeout set to 200000: bash scripts/org --as secretary wait --children (Issue #380). Only after writing secretary-handover may you end the turn without waiting." >&2
exit 2
