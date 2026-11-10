#!/bin/sh
# Probe for Issue #128 (G1): a worker started by org-delegate can run the org
# script, and its `report done` lands in the secretary's box.
#
# Run from the repo root on the host, after `bash skills/org-start/scripts/org-start.sh`
# from THIS checkout (so the org script is placed where the new worker template points):
#   sh scripts/probes/org-script-reach.sh
# Needs a running core and secretary, hc, git, bash, the worker token file, and the
# workers folder already trusted (org-delegate SKILL). Takes up to 180 s
# (PADDOCK_PROBE_WAIT to change). It uses the real mailbox
# (${PADDOCK_STATE_DIR:-~/.local/state/paddock}): the secretary gets one start and one
# done record for task p128-<pid>. It creates a scratch repository in a temp folder and
# one worktree w-p128-<pid> in the workers folder; the trap kills and removes that
# terminal and that worktree. Nothing else is touched.
#
# Reading the output. Every verdict line starts with "RESULT <name>:".
#   placed        PASS = the org script exists at the path the worker template
#                 exports (default ~/.local/share/paddock/bin/org) and equals scripts/org.
#   delegate      PASS = org-delegate exited 0 (code printed otherwise).
#   report-done   PASS = list_runs shows the task as done by w-<id> within the wait.
#                 FAIL = it did not; the worker's screen tail is printed.
#   in-box        PASS = the secretary's unread messages (check_messages --peek) hold
#                 the worker's run_completed text.
#   write-denied  PASS = the worker's done text says its write to $PADDOCK_ORG failed
#                 (rc not 0) AND the placed script still equals scripts/org.
#                 NO DATA = the done text has no "write-rc=" (the worker did not follow it).
# The probe passes when every RESULT is PASS.
set -u
ROOT=$(pwd)
[ -f "$ROOT/skills/org-delegate/scripts/org-delegate.sh" ] || { echo "RESULT precondition-failed: run from the repo root"; exit 1; }
for c in hc git bash; do command -v $c >/dev/null 2>&1 || { echo "RESULT precondition-failed: $c not on PATH"; exit 1; }; done
ID=p128-$$; W=w-$ID; WAIT=${PADDOCK_PROBE_WAIT:-180}
ORGPATH=${PADDOCK_BIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/paddock/bin}/org
TMPD=$(mktemp -d) || exit 1
WT=
cleanup() {
  hc kill "$W" >/dev/null 2>&1; hc rm "$W" >/dev/null 2>&1
  [ -n "$WT" ] && git -C "$TMPD/proj" worktree remove --force "$WT" >/dev/null 2>&1
  rm -rf "$TMPD"
}
trap cleanup EXIT INT TERM
org() { bash "$ROOT/scripts/org" --as secretary "$@"; }

if [ -f "$ORGPATH" ] && cmp -s "$ROOT/scripts/org" "$ORGPATH"; then echo "RESULT placed: PASS ($ORGPATH)"
else echo "RESULT placed: FAIL ($ORGPATH missing or differs; rerun org-start from this checkout)"; fi

git init -q -b main "$TMPD/proj" && git -C "$TMPD/proj" -c user.name=probe -c user.email=probe@invalid \
  commit -q --allow-empty -m init || { echo "RESULT precondition-failed: scratch repository"; exit 1; }
TASK="Probe for paddock Issue #128. Change nothing. Run exactly these two commands, then stop:
1. : >> \"\$PADDOCK_ORG\"; echo write-rc=\$?
2. bash \"\$PADDOCK_ORG\" --as $W report done --task $ID \"probe done write-rc=<the number printed by step 1>\""
out=$(bash "$ROOT/skills/org-delegate/scripts/org-delegate.sh" --project "$TMPD/proj" --task-id "$ID" --task "$TASK" 2>&1); rc=$?
echo "$out"
WT=$(printf '%s\n' "$out" | sed -n 's/.* worktree=\([^ ]*\) .*/\1/p')
[ "$rc" -eq 0 ] && echo "RESULT delegate: PASS" || { echo "RESULT delegate: FAIL (exit $rc)"; exit 1; }

t=0; tab=$(printf '\t')
while [ "$t" -lt "$WAIT" ]; do
  org list_runs 2>/dev/null | grep -q "^$ID$tab$W${tab}done$tab" && break
  t=$((t + 3)); sleep 3
done
if [ "$t" -lt "$WAIT" ]; then echo "RESULT report-done: PASS (${t}s)"
else echo "RESULT report-done: FAIL (no done record from $W in ${WAIT}s)"; echo "== screen tail"; hc read "$W" 2>&1 | tail -n 30; fi

box=$(org check_messages --peek 2>/dev/null | grep -A1 "^\[$W#.* run_completed task=$ID\]" | grep 'probe done')
[ -n "$box" ] && echo "RESULT in-box: PASS" || echo "RESULT in-box: FAIL"
wrc=$(printf '%s\n' "$box" | sed -n 's/.*write-rc=\([0-9]*\).*/\1/p' | tail -n 1)
if [ -z "$wrc" ]; then echo "RESULT write-denied: NO DATA"
elif [ "$wrc" != 0 ] && cmp -s "$ROOT/scripts/org" "$ORGPATH"; then echo "RESULT write-denied: PASS (rc $wrc)"
else echo "RESULT write-denied: FAIL (rc $wrc; script unchanged: $(cmp -s "$ROOT/scripts/org" "$ORGPATH" && echo yes || echo no))"; fi
