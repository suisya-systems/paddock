#!/bin/sh
# Host check for Issue #175: `org wait` reports, against a real core, a worker that is gone
# without a done record, and stays quiet for a worker that is running.
#
# Run from the repo root, on a host where herdr-core (hc) runs, in a plain login shell:
#   sh scripts/probes/worker-gone-wait.sh
# Takes under a minute. Needs hc, sh and bash; no Claude.
#
# What it touches: its OWN core (HC_SESSION=p175-<pid>) and PADDOCK_STATE_DIR under a private
# temp folder. Your real core, mailbox and workers are not read or changed.
#
# Steps:
#   1. org-state gets two tasks: p175a and p175b. Two stand-in workers (shell loops, not Claude)
#      w-p175a and w-p175b run with the task_id label.
#   2. `org wait --timeout 3` with both running.
#   3. w-p175a is stopped with `hc kill` and no `report done` is written. `org wait --timeout 3`.
#   4. w-p175a is removed with `hc rm`. `org wait --timeout 3`.
#   5. w-p175a gets its done record. `org wait --timeout 3`.
#
# Reading the output. Every verdict starts with "RESULT <name>:". PASS / FAIL.
#   quiet-running   step 2: the line has no gone / waiting / unreported / unreadable / watch_error.
#   gone-killed     step 3: "gone" lists p175a, and does not list p175b.
#   gone-removed    step 4: "gone" lists p175a (the terminal is not_found).
#   cleared-by-done step 5: p175a is no longer listed.
# The waiting and unreported cases need a status the stand-in cannot report; the stubbed test
# tests/org-wait-watch.test.sh covers them. Paste the whole output back.
set -u

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
  *) echo "worker-gone-wait: unknown argument: $1" >&2; exit 2 ;;
esac

ROOT=$(pwd)
[ -f "$ROOT/scripts/org" ] || { echo "RESULT precondition-failed: run from the repo root"; exit 1; }
command -v hc >/dev/null 2>&1 || { echo "RESULT precondition-failed: hc not on PATH"; exit 1; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/probe175.XXXXXX") || exit 1
HC_SESSION=p175-$$; export HC_SESSION
PADDOCK_STATE_DIR=$WORK/state; export PADDOCK_STATE_DIR
unset PADDOCK_ORG_ID PADDOCK_SECRETARY_NAME
FAILS=0
cleanup() {
  for n in w-p175a w-p175b; do hc kill $n >/dev/null 2>&1; hc rm $n >/dev/null 2>&1; done
  hc server stop >/dev/null 2>&1 # HC_SESSION is the temp core's: yours is untouched
  rm -rf "$WORK"
}
trap cleanup EXIT; trap 'exit 130' INT TERM
org() { bash "$ROOT/scripts/org" "$@"; }
result() { echo "RESULT $1: $2${3:+ ($3)}"; [ "$2" = FAIL ] && FAILS=$((FAILS + 1)); return 0; }
wait_line() { org --as secretary wait --timeout 3 2>&1 | tr -d '\n'; }

echo "== versions"; hc --version 2>&1
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"work":[{"task_id":"p175a","title":"Probe 175 a","since":"%s"},{"task_id":"p175b","title":"Probe 175 b","since":"%s"}],"approvals":[]}' "$now" "$now" \
  | org --as secretary doc set org-state || { result setup FAIL "cannot write org-state on the temp core"; exit 1; }
for t in p175a p175b; do
  hc run --bg --name w-$t --label task_id=$t -- sh -c 'sleep 3600' >/dev/null 2>&1 || { result setup FAIL "cannot start w-$t"; exit 1; }
done

echo "== step 2: both running"
out=$(wait_line); echo "$out"
printf '%s' "$out" | grep -Eq 'gone|waiting|unreported|unreadable|watch_error' && result quiet-running FAIL "$out" || result quiet-running PASS

echo "== step 3: w-p175a killed, no report"
hc kill w-p175a >/dev/null 2>&1; hc get --json w-p175a 2>&1 | tr -d '\n'; echo
out=$(wait_line); echo "$out"
printf '%s' "$out" | grep -Eq '"gone":\[[^]]*"p175a"' && ! printf '%s' "$out" | grep -Eq '"gone":\[[^]]*"p175b"' \
  && result gone-killed PASS || result gone-killed FAIL "$out"

echo "== step 4: w-p175a removed"
hc rm w-p175a >/dev/null 2>&1
out=$(wait_line); echo "$out"
printf '%s' "$out" | grep -Eq '"gone":\[[^]]*"p175a"' && result gone-removed PASS || result gone-removed FAIL "$out"

echo "== step 5: done record written"
org --as w-p175a report done --task p175a "probe" >/dev/null 2>&1; org --as secretary check_messages >/dev/null 2>&1
out=$(wait_line); echo "$out"
printf '%s' "$out" | grep -q p175a && result cleared-by-done FAIL "$out" || result cleared-by-done PASS

[ $FAILS -eq 0 ]
