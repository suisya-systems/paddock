#!/bin/sh
# Probe for Issue #58 (GT-5): can a worker's first mailbox message serve as the durable
# start record, instead of `first_message.sent` (which only says the task was pasted and
# goes away with `hc rm`)?
#
# Run from the repo root on the host, after `bash skills/org-start/scripts/org-start.sh`
# from THIS checkout (so the org script is placed where the worker template points):
#   sh scripts/probes/first-mailbox-message.sh <trusted-git-project>
# <trusted-git-project> is a git repository (with a branch `main`) that Claude Code already
# trusts, so the new worktree raises no folder-trust dialog (Issue #133). If the dialog
# shows anyway the probe prints "NEEDS-PERSON" and keeps the terminal; answer the dialog
# and rerun. Needs a running core and secretary, hc, git, bash, the worker token file, and
# the workers folder already trusted. Takes up to 180 s (PADDOCK_PROBE_WAIT to change).
# It uses the real mailbox (${PADDOCK_STATE_DIR:-~/.local/state/paddock}): one record by the
# secretary (org-delegate's own start) and two by the worker for task p58-<pid>. It creates
# one worktree + branch in <project> via org-delegate and one terminal w-p58-<pid>; the trap
# removes the terminal and the worktree (the branch work/p58-<pid> is deleted too).
#
# What it measures. The worker is told to send its FIRST mailbox message as
# `report start`, then `report done`. org-delegate also writes a start record, but under the
# secretary's id; only a record in the worker's own file (events/<month>/w-<id>.jsonl) is
# the worker's first message.
#
# Reading the output. Every verdict line starts with "RESULT <name>:".
#   delegate        PASS = org-delegate exited 0 (code printed otherwise).
#   hc-first-msg    INFO = first_message of `hc get --json` while the terminal exists.
#   first-msg       PASS = the worker's own file holds a run_started record for the task
#                   addressed to the secretary, within the wait. This is the worker
#                   reaching the mailbox, which first_message.sent cannot show.
#   first-is-first  PASS = that run_started is line 1 of the worker's file (seq 1).
#   in-box          PASS = list_runs, as the secretary, shows the task from w-<id>.
#   after-rm        PASS = (hc get answers not_found) and after `hc kill` + `hc rm` of the terminal, the same run_started
#                   line is still in the file AND list_runs still shows the task.
#   hc-after-rm     INFO = `hc get` of the removed terminal (expected: not found, so
#                   first_message.sent is gone).
#   survives-hc     PASS = after-rm PASS and hc-after-rm shows the terminal gone, i.e. the
#                   mailbox record outlives what first_message.sent cannot.
# GT-5 verdict: Feasible (mailbox half) when first-msg, first-is-first, in-box and after-rm
# are PASS. Copy the RESULT lines and the hc-first-msg / hc-after-rm lines into the GT-5 row.
set -u
ROOT=$(pwd)
[ -f "$ROOT/skills/org-delegate/scripts/org-delegate.sh" ] || { echo "RESULT precondition-failed: run from the repo root"; exit 1; }
PROJ=${1:-}
[ -n "$PROJ" ] && git -C "$PROJ" rev-parse --git-dir >/dev/null 2>&1 || { echo "RESULT precondition-failed: give an already trusted git project path as the argument"; exit 1; }
for c in hc git bash; do command -v $c >/dev/null 2>&1 || { echo "RESULT precondition-failed: $c not on PATH"; exit 1; }; done
ID=p58-$$-$(date +%s); W=w-$ID; WAIT=${PADDOCK_PROBE_WAIT:-180}
WT=${PADDOCK_WORKERS_DIR:-$HOME/paddock-workers}/$ID
STATE=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}
KEEP=
cleanup() {
  [ -n "$KEEP" ] && { echo "terminal $W and worktree $WT kept"; return; }
  hc kill "$W" >/dev/null 2>&1; hc rm "$W" >/dev/null 2>&1
  git -C "$PROJ" worktree remove --force "$WT" >/dev/null 2>&1
  git -C "$PROJ" branch -D "work/$ID" >/dev/null 2>&1
}
[ ! -e "$WT" ] && ! hc get "$W" >/dev/null 2>&1 || { echo "RESULT precondition-failed: $W or $WT already exists (leftover of an earlier run)"; exit 1; }
org() { bash "$ROOT/scripts/org" --as secretary "$@"; }
# The worker's own events (not the unread cursor: only that file proves who wrote it).
mine() { cat "$STATE"/events/*/"$W".jsonl 2>/dev/null; }

TASK="Probe for paddock Issue #58. Change nothing. Run exactly these two commands in this order, then stop:
1. bash \"\$PADDOCK_ORG\" --as $W report start --task $ID \"probe start\"
2. bash \"\$PADDOCK_ORG\" --as $W report done --task $ID \"probe done\""
out=$(bash "$ROOT/skills/org-delegate/scripts/org-delegate.sh" --project "$PROJ" --task-id "$ID" --task "$TASK" 2>&1); rc=$?
echo "$out"
if [ "$rc" -eq 0 ]; then echo "RESULT delegate: PASS"; trap cleanup EXIT INT TERM; else echo "RESULT delegate: FAIL (exit $rc)"; exit 1; fi
echo "RESULT hc-first-msg: INFO $(hc get --json "$W" 2>&1 | tr -d '\n' | cut -c1-300)"

t=0
while [ "$t" -lt "$WAIT" ]; do
  mine | grep -q '"kind":"run_started","to":"secretary"' && break
  case "$(hc read "$W" 2>/dev/null)" in *"Quick safety check"*|*"trust this folder"*)
    echo "NEEDS-PERSON: folder-trust dialog in $W; answer it (or trust the project) and rerun"; KEEP=1; exit 1 ;; esac
  t=$((t + 3)); sleep 3
done
line=$(mine | grep '"kind":"run_started","to":"secretary"' | grep "\"task_id\":\"$ID\"" | head -n 1)
if [ -n "$line" ]; then echo "RESULT first-msg: PASS (${t}s) $line"
else echo "RESULT first-msg: FAIL (no run_started from $W in ${WAIT}s)"; echo "== screen tail"; hc read "$W" 2>&1 | tail -n 30; exit 1; fi
[ "$(mine | head -n 1)" = "$line" ] && echo "RESULT first-is-first: PASS" || echo "RESULT first-is-first: FAIL (file line 1: $(mine | head -n 1))"
tab=$(printf '\t')
runs() { org list_runs 2>/dev/null | grep "^$ID$tab$W$tab"; }
# Let the worker finish its second command before the terminal goes away.
t=0; while [ "$t" -lt 60 ] && ! mine | grep -q '"kind":"run_completed"'; do t=$((t + 3)); sleep 3; done
[ -n "$(runs)" ] && echo "RESULT in-box: PASS ($(runs))" || echo "RESULT in-box: FAIL"

hc kill "$W" >/dev/null 2>&1; hc rm "$W" >/dev/null 2>&1
after=$(hc get --json "$W" 2>&1 | tr -d "\n")
echo "RESULT hc-after-rm: INFO $(printf %s "$after" | cut -c1-200)"
gone=; case "$after" in *not_found*) gone=1 ;; esac
if [ -n "$gone" ] && mine | grep -qF "$line" && [ -n "$(runs)" ]; then
  echo "RESULT after-rm: PASS"
  echo "RESULT survives-hc: PASS"
else echo "RESULT after-rm: FAIL (terminal not confirmed removed (no not_found), or record missing from the file or list_runs)"; fi
