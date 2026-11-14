#!/bin/sh
# Probe for Issue #128 (G1): a worker started by org-delegate can run the org
# script, and its `report done` lands in the secretary's box.
#
# Run from the repo root on the host, after `bash skills/org-start/scripts/org-start.sh`
# from THIS checkout (so the org script is placed where the new worker template points):
#   sh scripts/probes/org-script-reach.sh <trusted-git-project>
# <trusted-git-project> is a git repository (with a branch `main`) that Claude Code already
# trusts, so the new worktree raises no folder-trust dialog (Issue #133). If the dialog
# shows anyway the probe prints "NEEDS-PERSON" and keeps the terminal; answer the dialog
# and rerun. Needs a running core and secretary, hc, git, bash, and
# the workers folder already trusted (org-delegate SKILL). Takes up to 180 s
# (PADDOCK_PROBE_WAIT to change). It uses the real mailbox
# (${PADDOCK_STATE_DIR:-~/.local/state/paddock}): the secretary gets one start and one
# done record for task p128-<pid>. It creates one worktree + branch in <project> via
# org-delegate and one terminal w-p128-<pid>; the trap removes the terminal and the
# worktree (the branch work/p128-<pid> is deleted too). Nothing else is touched.
#
# Reading the output. Every verdict line starts with "RESULT <name>:".
#   placed        PASS = the org script exists at the path the worker template
#                 exports (default ~/.local/share/paddock/bin/org) and equals scripts/org.
#   delegate      PASS = org-delegate exited 0 (code printed otherwise).
#   report-done   PASS = list_runs shows the task as done by w-<id> within the wait.
#                 FAIL = it did not; the worker's screen tail is printed.
#   in-box        PASS = the worker's event file holds a run_completed record for the
#                 task addressed to the secretary (read or not).
#   write-denied  PASS = the worker's done text says its write to $PADDOCK_ORG failed
#                 (rc not 0) AND the placed script still equals scripts/org.
#                 NO DATA = the done text has no "write-rc=" (the worker did not follow it).
# The probe passes when every RESULT is PASS.
set -u
ROOT=$(pwd)
[ -f "$ROOT/skills/org-delegate/scripts/org-delegate.sh" ] || { echo "RESULT precondition-failed: run from the repo root"; exit 1; }
for c in hc git bash; do command -v $c >/dev/null 2>&1 || { echo "RESULT precondition-failed: $c not on PATH"; exit 1; }; done
PROJ=${1:-}
[ -n "$PROJ" ] && git -C "$PROJ" rev-parse --git-dir >/dev/null 2>&1 || { echo "RESULT precondition-failed: give an already trusted git project path as the argument"; exit 1; }
ID=p128-$$-$(date +%s); W=w-$ID; WAIT=${PADDOCK_PROBE_WAIT:-180}
ORGPATH=${PADDOCK_BIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/paddock/bin}/org
# Known before delegating, so cleanup works on every exit (10 keeps the worktree and prints no path).
WT=${PADDOCK_WORKERS_DIR:-$HOME/paddock-workers}/$ID
KEEP=
. "$(dirname "$0")/claude-link.sh"
claude_link_save
cleanup() {
  claude_link_restore
  [ -n "$KEEP" ] && { echo "terminal $W and worktree $WT kept"; return; }
  hc kill "$W" >/dev/null 2>&1; hc rm "$W" >/dev/null 2>&1
  git -C "$PROJ" worktree remove --force "$WT" >/dev/null 2>&1
  git -C "$PROJ" branch -D "work/$ID" >/dev/null 2>&1
}
[ ! -e "$WT" ] && ! hc get "$W" >/dev/null 2>&1 || { echo "RESULT precondition-failed: $W or $WT already exists (leftover of an earlier run)"; exit 1; }
trap cleanup EXIT INT TERM
dialog() { case "$(hc read "$W" 2>/dev/null)" in *"Quick safety check"*|*"trust this folder"*) return 0 ;; esac; return 1; }
needs_person() { echo "NEEDS-PERSON: folder-trust dialog in $W; answer it (or trust the project) and rerun"; KEEP=1; exit 1; }
org() { bash "$ROOT/scripts/org" --as secretary "$@"; }

if [ -f "$ORGPATH" ] && cmp -s "$ROOT/scripts/org" "$ORGPATH"; then echo "RESULT placed: PASS ($ORGPATH)"
else echo "RESULT placed: FAIL ($ORGPATH missing or differs; rerun org-start from this checkout)"; fi

TASK="Probe for paddock Issue #128. Change nothing. Run exactly these two commands, then stop:
1. : >> \"\$PADDOCK_ORG\"; echo write-rc=\$?
2. bash \"\$PADDOCK_ORG\" --as $W report done --task $ID \"probe done write-rc=<the number printed by step 1>\""
out=$(bash "$ROOT/skills/org-delegate/scripts/org-delegate.sh" --project "$PROJ" --task-id "$ID" --task "$TASK" 2>&1); rc=$?
echo "$out"
if [ "$rc" -eq 0 ]; then echo "RESULT delegate: PASS"
else echo "RESULT delegate: FAIL (exit $rc)"; [ "$rc" -eq 10 ] && dialog && needs_person; exit 1; fi

t=0; tab=$(printf '\t')
while [ "$t" -lt "$WAIT" ]; do
  org list_runs 2>/dev/null | grep -q "^$ID$tab$W${tab}done$tab" && break
  dialog && needs_person
  t=$((t + 3)); sleep 3
done
if [ "$t" -lt "$WAIT" ]; then echo "RESULT report-done: PASS (${t}s)"
else echo "RESULT report-done: FAIL (no done record from $W in ${WAIT}s)"; echo "== screen tail"; hc read "$W" 2>&1 | tail -n 30; fi

# The worker's own event file, not the unread cursor: the secretary may already have read it.
STATE=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}
box=$(cat "$STATE"/events/*/"$W".jsonl 2>/dev/null | grep '"kind":"run_completed","to":"secretary"' | grep "\"task_id\":\"$ID\"" | grep 'probe done')
[ -n "$box" ] && echo "RESULT in-box: PASS" || echo "RESULT in-box: FAIL"
wrc=$(printf '%s\n' "$box" | sed -n 's/.*write-rc=\([0-9]*\).*/\1/p' | tail -n 1)
if [ -z "$wrc" ]; then echo "RESULT write-denied: NO DATA"
elif [ "$wrc" != 0 ] && cmp -s "$ROOT/scripts/org" "$ORGPATH"; then echo "RESULT write-denied: PASS (rc $wrc)"
else echo "RESULT write-denied: FAIL (rc $wrc; script unchanged: $(cmp -s "$ROOT/scripts/org" "$ORGPATH" && echo yes || echo no))"; fi
