#!/bin/sh
# Host check for Issue #285: does `org wait --children` return at once when a line is typed
# into the waiting terminal (hc wait --children any: reason "message")?
#
# Run from the repo root, on a host where herdr-core (hc) runs, in a plain login shell:
#   sh scripts/probes/wait-typed-input.sh
# Takes under a minute. Needs hc, sh and bash; no Claude.
#
# What it touches: its OWN core (HC_SESSION=p285-<pid>) and PADDOCK_STATE_DIR under a private
# temp folder. Your real core, mailbox and workers are not read or changed.
#
# Steps:
#   1. A stand-in parent terminal p285-sec (a shell, not Claude) starts a child p285-kid
#      (sleep 120) and runs `org --as secretary wait --children --timeout 60`, output to a file.
#   2. After 5 s the probe types a line into p285-sec with `hc send`.
#   3. It waits up to 30 s for the wait's output and records how long that took.
#
# Reading the output. Every verdict starts with "RESULT <name>:". PASS / FAIL.
#   message-reason   the wait printed "reason":"message" (not timeout).
#   fast             it returned within 15 s of the typed line (the bound is 60 s).
# A shell is not an agent: if hc counts a typed line only while a Claude turn is working, this
# shows FAIL while the real secretary still works. Then do the real check by hand: in a running
# secretary with a worker in progress, type a line while its `org wait --children` Bash call is
# showing; the call should return within seconds with "reason":"message". Paste the output back.
set -u

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
  *) echo "wait-typed-input: unknown argument: $1" >&2; exit 2 ;;
esac

ROOT=$(pwd)
[ -f "$ROOT/scripts/org" ] || { echo "RESULT precondition-failed: run from the repo root"; exit 1; }
command -v hc >/dev/null 2>&1 || { echo "RESULT precondition-failed: hc not on PATH"; exit 1; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/probe285.XXXXXX") || exit 1
HC_SESSION=p285-$$; export HC_SESSION
PADDOCK_STATE_DIR=$WORK/state; export PADDOCK_STATE_DIR
. "$(dirname "$0")/claude-link.sh"
claude_link_save
unset PADDOCK_ORG_ID PADDOCK_SECRETARY_NAME
cleanup() { claude_link_restore; hc kill p285-sec >/dev/null 2>&1; hc kill p285-kid >/dev/null 2>&1; hc server stop >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

hc run --bg --name p285-sec -- sh -c "hc run --bg --name p285-kid -- sleep 120; bash '$ROOT/scripts/org' --as secretary wait --children --timeout 60 > '$WORK/out' 2>&1; sleep 30" >/dev/null 2>&1 \
  || { echo "RESULT precondition-failed: hc run failed"; exit 1; }
sleep 5
t0=$(date +%s)
hc send p285-sec "typed by the person" >/dev/null 2>&1
i=0; while [ $i -lt 30 ] && ! grep -q reason "$WORK/out" 2>/dev/null; do sleep 1; i=$((i + 1)); done
dt=$(( $(date +%s) - t0 ))
echo "wait output: $(cat "$WORK/out" 2>/dev/null)   (${dt} s after the typed line)"
grep -q '"reason":"message"' "$WORK/out" 2>/dev/null && echo "RESULT message-reason: PASS" || echo "RESULT message-reason: FAIL"
[ "$dt" -le 15 ] && grep -q reason "$WORK/out" 2>/dev/null && echo "RESULT fast: PASS" || echo "RESULT fast: FAIL"
