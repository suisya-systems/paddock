#!/bin/sh
# Probe for Issue #176: does org-resume resume from the work list when the core was stopped
# without a suspend? Measures once: a worker in progress, `hc server stop` with no org-suspend,
# then org-resume (plan, then --apply).
#
# Run from the repo root, in a LOGIN SHELL (not from inside an agent), on a host where herdr-core
# (hc) runs and claude is logged in:
#   sh scripts/probes/org-resume-no-record.sh
# Takes about 3 to 5 minutes (a Claude Code launch, then a relaunch; each waits up to 90 s).
# Needs hc, claude, git, bash, POSIX sh, grep, sed, tr, sleep.
#
# What it touches. It starts its OWN core (HC_SESSION=p176-<pid>, XDG_CONFIG_HOME under a private
# temp folder), so your real core, templates, org-state and suspend record are not read or
# changed. Its state folder (PADDOCK_STATE_DIR) is private too, and it never runs org-suspend.
# It creates a git folder under $HOME (not /tmp: the folder-trust dialog; it answers that dialog
# itself) and two temporary templates, `worker` and `worker-continue`, in the private core's
# templates folder. The cleanup trap kills and removes the terminal, stops ONLY that core and
# deletes the temp folder; the git folder under $HOME is left for inspection.
#
# Reading the output. Every verdict line starts with "RESULT <name>:".
#   runner-env           clean = no agent variable is set. agent = org-resume refuses (exit 4);
#                        nothing can be measured. Rerun from a login shell.
#   worker-up            PASS = the first worker reported a status.
#   org-state-survived   PASS = after `hc server stop` and a new core, org-state still names the
#                        task (the work list is what org-resume reads). FAIL = it is gone: then
#                        org-resume cannot resume and exits 9 (that is the finding).
#   terminal-gone        PASS = the worker's terminal is gone after the stop. FAIL = it survived
#                        (then org-resume only keeps it; the apply step proves nothing).
#   no-record            PASS = no suspend.record exists before the resume (the arrangement).
#   plan-exit            PASS = exit 0.
#   plan-says-so         PASS = the plan names the missing record and the work list, and says
#                        what it could not restore.
#   plan-launched        PASS = the plan launched nothing (no worker terminal exists after it).
#   apply-exit           PASS = exit 0 (13 = a worker could not be relaunched; read the output).
#   apply-path           continue = relaunched with worker-continue; fresh = fell back to a fresh
#                        worker; none = neither came up.
#   worker-after-apply   PASS = the relaunched terminal reports a status.
# The whole probe passes when every RESULT is PASS (apply-path is continue or fresh). Pasted
# output may be recorded in the Issue; it contains no secrets, only paths under $HOME.
set -u

NAME=w-p176
TASK=p176
VARS4="CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN"
ROOT=$(pwd)
[ -f "$ROOT/skills/org-resume/scripts/org-resume.sh" ] || { echo "RESULT precondition-failed: run from the repo root"; exit 1; }
for c in hc claude git bash; do command -v $c >/dev/null 2>&1 || { echo "RESULT precondition-failed: $c not on PATH"; exit 1; }; done

RUNNER=
for v in CLAUDECODE $VARS4; do [ -n "$(printenv "$v" 2>/dev/null)" ] && RUNNER="$RUNNER $v"; done
if [ -z "$RUNNER" ]; then echo "RESULT runner-env: clean"; else echo "RESULT runner-env: agent (set:$RUNNER) - nothing can be measured"; exit 1; fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/probe176.XXXXXX") || exit 1
XDG="$WORK/xdg"; TPLS="$XDG/herdr-core/templates"; STATE="$WORK/state"
BASE="$HOME/p176-resume-$(date +%Y%m%d-%H%M%S)"; WT="$BASE/wt"
mkdir -p "$TPLS" "$STATE" "$WT" || exit 1
WT=$(cd "$WT" && pwd -P) || exit 1
HC_SESSION=p176-$$; export HC_SESSION
XDG_CONFIG_HOME=$XDG; export XDG_CONFIG_HOME
cleanup() {
  hc kill "$NAME" >/dev/null 2>&1; hc rm "$NAME" >/dev/null 2>&1
  hc server stop >/dev/null 2>&1 # HC_SESSION is the temp core's: yours is untouched
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

ENVU="env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN"
printf -- '---\ndescription: probe 176 fresh worker (temporary)\ncommand: %s claude\n---\nProbe 176. Ignore.\n' "$ENVU" > "$TPLS/worker.md"
printf -- '---\ndescription: probe 176 continued worker (temporary)\ncommand: %s claude --continue\n---\nProbe 176. Ignore.\n' "$ENVU" > "$TPLS/worker-continue.md"
git -C "$WT" init -q && git -C "$WT" -c user.name=probe -c user.email=probe@example.invalid commit -q --allow-empty -m probe

echo "== versions"; hc --version 2>&1; claude --version 2>&1
echo "== temp core session $HC_SESSION; terminal $NAME; worktree $WT"

status_json() { hc get --json "$NAME" 2>/dev/null | tr -d '\n'; }
has_status() { status_json | grep -Eq '"status": *\{'; }
wait_status() { # wait_status <seconds>: answer the trust dialog while waiting
  i=0
  while [ $i -lt "$1" ]; do
    screen=$(hc read "$NAME" 2>/dev/null)
    case "$screen" in *"Quick safety check"*|*"trust this folder"*) echo "-- answering the folder-trust dialog"; hc keys "$NAME" enter >/dev/null 2>&1 ;; esac
    has_status && return 0
    i=$((i + 2)); sleep 2
  done
  return 1
}

# 1. A worker in progress, recorded in the work list (org-state), no suspend.
hc run --bg --outlive-parent --name "$NAME" --cwd "$WT" --label "task_id=$TASK" worker "Probe 176. Reply with the single word READY and wait." >/dev/null 2>&1 \
  || { echo "RESULT worker-up: FAIL (hc run failed)"; exit 1; }
if wait_status 90; then echo "RESULT worker-up: PASS"; else echo "RESULT worker-up: FAIL (no status in 90 s)"; hc read "$NAME" 2>&1 | tail -n 8; exit 1; fi
printf '{"work":[{"task_id":"%s","title":"probe","since":"2026-11-11T00:00:00Z","worktree":"%s","task":"Probe 176. Reply with the single word READY and wait."}],"approvals":[]}' "$TASK" "$WT" \
  | PADDOCK_STATE_DIR="$STATE" bash "$ROOT/scripts/org" --as secretary doc set org-state || { echo "RESULT worker-up: FAIL (doc set org-state failed)"; exit 1; }
sleep 5 # let the first turn finish so the conversation is on disk

# 2. The core stops without a suspend.
[ ! -f "$STATE/suspend.record" ] && echo "RESULT no-record: PASS" || echo "RESULT no-record: FAIL (a record exists)"
hc server stop; echo "hc server stop exit: $?"
sleep 3
hc ls >/dev/null 2>&1 # starts the core again if hc starts it on demand
if hc get "$NAME" >/dev/null 2>&1; then echo "RESULT terminal-gone: FAIL (the terminal survived the stop)"; else echo "RESULT terminal-gone: PASS"; fi
if PADDOCK_STATE_DIR="$STATE" bash "$ROOT/scripts/org" --as secretary doc get org-state 2>&1 | grep -q "\"$TASK\""; then
  echo "RESULT org-state-survived: PASS"; else echo "RESULT org-state-survived: FAIL"; fi

# 3. Resume: plan first, then --apply.
export PADDOCK_STATE_DIR="$STATE" PADDOCK_READY_TRIES=90
echo "== org-resume (plan)"
PLAN=$(bash "$ROOT/skills/org-resume/scripts/org-resume.sh" 2>&1); RC=$?
printf '%s\n' "$PLAN"
[ $RC -eq 0 ] && echo "RESULT plan-exit: PASS" || echo "RESULT plan-exit: FAIL ($RC)"
if printf '%s' "$PLAN" | grep -qi 'no suspend record' && printf '%s' "$PLAN" | grep -qi 'work list' && printf '%s' "$PLAN" | grep -Eqi 'could not restore'; then
  echo "RESULT plan-says-so: PASS"; else echo "RESULT plan-says-so: FAIL"; fi
if hc get "$NAME" >/dev/null 2>&1; then echo "RESULT plan-launched: FAIL"; else echo "RESULT plan-launched: PASS"; fi

echo "== org-resume --apply"
OUT=$(bash "$ROOT/skills/org-resume/scripts/org-resume.sh" --apply 2>&1); RC=$?
printf '%s\n' "$OUT"
[ $RC -eq 0 ] && echo "RESULT apply-exit: PASS" || echo "RESULT apply-exit: FAIL ($RC)"
if printf '%s' "$OUT" | grep -q 'resumed with worker-continue'; then echo "RESULT apply-path: continue"
elif printf '%s' "$OUT" | grep -q 'started a fresh worker'; then echo "RESULT apply-path: fresh"
else echo "RESULT apply-path: none"; fi
sleep 3
if has_status; then echo "RESULT worker-after-apply: PASS"; else echo "RESULT worker-after-apply: FAIL"; fi
echo "== screen tail (check by eye for a dialog)"
hc read "$NAME" 2>&1 | tail -n 8
echo "== done; paste everything above back"
