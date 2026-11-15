#!/bin/sh
# Secretary Stop guard (Issues #380, #385): a Stop hook (templates/secretary-settings.json). Every write
# to the secretary's mailbox nudges an idle secretary (scripts/org, hc send --if idle), but a write that
# lands while it is still working is refused that nudge. So before the turn ends, this looks at the
# mailbox once: unread mail refuses the stop (exit 2) and tells it to read the mail.
# TEMPORARY (Issue #388): while org-state has a work or approvals entry, the stop is refused too and the
# secretary is told to end the turn in org wait --children (the #380 hold); remove once the nudge is
# confirmed on the host.
# - Allowed: secretary-handover written (the handover script needs it idle; the new secretary reads the
#   mailbox on resume, so mail that came in meanwhile is not lost).
# - stop_hook_active is ignored: reading the mail clears that refusal, and each work refusal leads to
#   org wait --children, which holds up to its timeout. Esc still stops the secretary, and Claude Code ends
#   the turn after 8 blocks in a row with no tool call.
# - Fails open: if the mailbox, org-state or the handover document cannot be read, that check allows the
#   stop and stderr says why.
# ponytail: "non-empty" is a grep on the joined value for a key followed by "[" and a non-"]" character;
# a string value holding the literal text "work":[x is escaped (\"work\") and does not match.
cat >/dev/null 2>&1   # the payload is not needed
org="$(dirname "$0")/org"
why=
m=$(bash "$org" --as secretary check_messages --peek 2>&1) || { echo "org: secretary-stop-guard: cannot read the mailbox, stop allowed: $(printf '%s' "$m" | head -c 200)" >&2; m="no new messages"; }
[ "$m" = "no new messages" ] || why=mail
if [ -z "$why" ]; then
  st=$(bash "$org" --as secretary doc get org-state 2>&1) || { echo "org: secretary-stop-guard: cannot read org-state, stop allowed: $(printf '%s' "$st" | head -c 200)" >&2; exit 0; }
  printf '%s' "$st" | tr -d '\n' | grep -Eq '(^|[^\\])"(work|approvals)" *: *\[ *[^] ]' || exit 0
  why=work
fi
ho=$(bash "$org" --as secretary doc get secretary-handover 2>&1) || { echo "org: secretary-stop-guard: cannot read secretary-handover, stop allowed: $(printf '%s' "$ho" | head -c 200)" >&2; exit 0; }
[ "$(printf '%s' "$ho" | tr -d ' \n')" = null ] || [ -z "$ho" ] || exit 0
if [ "$why" = mail ]; then
  echo "org: refused: you have unread mail, which came while you were working. Read it now (bash scripts/org --as secretary check_messages) and act on it before ending the turn (Issue #385)." >&2
else
  echo "org: refused: org-state has a work or approvals entry, so do not end the turn idle: a worker's report or the card's ANSWER may not reach you (Issue #388). End the turn with ONE Bash call, its tool timeout set to 200000: bash scripts/org --as secretary wait --children (Issue #380). Only after writing secretary-handover may you end the turn without waiting." >&2
fi
exit 2
