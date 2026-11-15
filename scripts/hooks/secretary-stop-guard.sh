#!/bin/sh
# Secretary Stop guard (Issues #380, #385): a Stop hook (templates/secretary-settings.json). Every write
# to the secretary's mailbox nudges an idle secretary (scripts/org, hc send --if idle), but a write that
# lands while it is still working is refused that nudge. So before the turn ends, this looks at the
# mailbox once: unread mail refuses the stop (exit 2) and tells it to read the mail; otherwise exit 0.
# It never holds the secretary in a wait; open work or approvals alone do not refuse (the next write wakes it).
# - Allowed: secretary-handover written (the handover script needs it idle; the new secretary reads the
#   mailbox on resume, so mail that came in meanwhile is not lost).
# - stop_hook_active is ignored: reading the mail clears the refusal, so it cannot loop. Esc still stops the
#   secretary, and Claude Code ends the turn after 8 blocks in a row with no tool call.
# - Fails open: if the mailbox (or the handover document) cannot be read, the stop is allowed and stderr says why.
cat >/dev/null 2>&1   # the payload is not needed
org="$(dirname "$0")/org"
m=$(bash "$org" --as secretary check_messages --peek 2>&1) || { echo "org: secretary-stop-guard: cannot read the mailbox, stop allowed: $(printf '%s' "$m" | head -c 200)" >&2; exit 0; }
[ "$m" != "no new messages" ] || exit 0
ho=$(bash "$org" --as secretary doc get secretary-handover 2>&1) || { echo "org: secretary-stop-guard: cannot read secretary-handover, stop allowed: $(printf '%s' "$ho" | head -c 200)" >&2; exit 0; }
[ "$(printf '%s' "$ho" | tr -d ' \n')" = null ] || [ -z "$ho" ] || exit 0
echo "org: refused: you have unread mail, which came while you were working. Read it now (bash scripts/org --as secretary check_messages) and act on it before ending the turn (Issue #385)." >&2
exit 2
