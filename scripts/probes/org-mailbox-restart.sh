#!/bin/sh
# Probe (Issue #60): messages written through scripts/org survive a window restart.
# Usage: sh scripts/probes/org-mailbox-restart.sh send | check   (run from your login shell, on the host)
# Steps: 1) `send`  2) close and reopen herdr-app (optionally also `hc server stop` then any hc command)
#        3) `check`; paste the output of both phases into the Issue. It uses its own state folder
#        and ids (probe-*), never org-state or the real mailbox.
set -u
here=$(cd "$(dirname "$0")/../.." && pwd)
export PADDOCK_STATE_DIR=${PADDOCK_PROBE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock-probe}
org() { bash "$here/scripts/org" "$@"; }

case "${1:-}" in
  send)
    org --as probe-w1 send_message probe-secretary "probe message 1" || exit 1
    org --as probe-w1 report start --task probe-t1 --to probe-secretary "probe start record" || exit 1
    org --as probe-w1 report done --task probe-t1 --to probe-secretary "probe completion record" || exit 1
    echo "sent 3 records to $PADDOCK_STATE_DIR"
    echo "-- read-only check of the document path (hc connect doc.get org-state):"
    org --as probe-w1 doc get org-state; echo "doc get exit status: $?"
    echo "Now close and reopen herdr-app (and, if you want, hc server stop), then run: sh $0 check" ;;
  check)
    out=$(org --as probe-secretary check_messages); echo "$out"
    n=$(printf '%s\n' "$out" | grep -c 'probe-w1#')
    if [ "$n" -eq 3 ]; then echo "RESULT: pass (3 records read after the restart)"
    else echo "RESULT: fail ($n of 3 records read)"; exit 1; fi
    echo "-- list_runs:"; org --as probe-secretary list_runs ;;
  *) echo "usage: sh $0 send | check" >&2; exit 2 ;;
esac
