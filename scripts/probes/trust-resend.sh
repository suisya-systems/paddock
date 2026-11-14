#!/bin/sh
# Host probe for Issue #368: with a real claude on a fresh clone, after ONE yes on the trust card, does the worker
# get its task (the first message org-delegate could not send) and does the work entry (--title) appear, with no
# step by the secretary in between?
#
#   sh scripts/probes/trust-resend.sh [--task-id T]
#
# Run from the paddock repository root, on the host, in a terminal that hc launched, after
# `bash skills/org-start/scripts/org-start.sh` from THIS checkout, with a running core and a logged-in claude.
# Needs no network: the "clone" is a private temp git repository with the trust-pending marker org-clone leaves.
# Its worktree path is new, so Claude Code raises the folder-trust dialog (measured in #362). About 1-2 minutes
# (PADDOCK_PROBE_WAIT seconds at most, default 120).
#
# The probe starts one worker w-p368-<T> through org-delegate --title (exit 10 is expected: the dialog stopped the
# first message). It NEVER presses a key itself and never passes --then-send: only org-escalation prompt, ask and
# answer do, as the secretary would, and the answer is the one call under test. On exit it removes the terminal,
# worktree, branch and temp folder. Claude Code keeps its own trust entry for the worktree path in ~/.claude.json
# (the probe does not touch it). The work entry p368-<T> stays in org-state: remove it from the secretary.
#
# Reading the output. Every verdict line starts with "RESULT <name>:".
#   delegate-stops  PASS = org-delegate exited 10 and the terminal showed the trust dialog.
#   saved           PASS = the first message and the entry were saved in <state>/resend/<id> (exit 10 saved them).
#   answer          PASS = answer --text yes (no --then-send) exited 0 and printed RESENT.
#   task-reached    PASS = the worker reported a status and its screen shows the task text (it got the message).
#   work-entry      PASS = org-state "work" holds task_id p368-<T> with the title.
#   files-gone      PASS = <state>/resend/<id> is gone and the marker file is cleared.
# NO DATA = a step before it did not run. The probe passes (exit 0) when every RESULT is PASS. Paste the whole output back.
# Exit: 0 all PASS, 1 a FAIL or NO DATA, 2 bad argument, 3 a tool is missing, 6 a precondition failed.
set -u

die() { c=$1; shift; echo "trust-resend: $*" >&2; exit "$c"; }
usage() { sed -n '2,28p' "$0"; }

T=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --task-id) [ $# -ge 2 ] || die 2 "$1 needs a value"; T=$2; shift 2 ;;
    *) die 2 "unknown option: $1" ;;
  esac
done
[ -n "$T" ] || T=$(date -u +%m%d%H%M)
case "$T" in *[!a-z0-9]*|"") die 2 "--task-id may hold only a-z and 0-9" ;; esac
for c in git bash awk mktemp hc claude; do command -v "$c" >/dev/null 2>&1 || die 3 "$c not found on PATH (run inside a terminal that hc launched)"; done
ROOT=$(pwd)
[ -f "$ROOT/skills/org-delegate/scripts/resend.sh" ] || die 6 "run from the paddock repository root, on a checkout with #368"

ID=p368-$T; W=w-$ID; WAIT=${PADDOCK_PROBE_WAIT:-120}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/probe368.XXXXXX") || die 6 "cannot make a temp folder"
STATE=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}
fail=0
res() { echo "RESULT $1: $2${3:+ ($3)}"; case "$2" in FAIL|"NO DATA") fail=1 ;; esac; }
cleanup() {
  claude_link_restore
  hc kill "$W" >/dev/null 2>&1; hc rm "$W" >/dev/null 2>&1
  git -C "$WORK/repo" worktree remove -f "${PADDOCK_WORKERS_DIR:-$HOME/paddock-workers}/$ID" >/dev/null 2>&1
  case "$WORK" in "${TMPDIR:-/tmp}"/probe368.*) rm -rf "$WORK" ;; esac
  echo "cleanup: terminal $W, worktree and $WORK removed (the work entry $ID stays in org-state)"
}
. "$(dirname "$0")/claude-link.sh"
claude_link_save
trap cleanup EXIT; trap 'exit 130' INT TERM
esc() { bash "$ROOT/skills/org-escalation/scripts/org-escalation.sh" "$@"; }

git init -q -b main "$WORK/repo" 2>/dev/null || { git init -q "$WORK/repo"; git -C "$WORK/repo" checkout -q -b main; }
git -C "$WORK/repo" -c user.name=probe -c user.email=probe@invalid commit -q --allow-empty -m init
M=$(git -C "$WORK/repo" rev-parse --absolute-git-dir)/paddock-trust-pending
: > "$M"
TASK="Probe for paddock Issue #368. Change nothing. Reply with the single word OK and stop."
bash "$ROOT/skills/org-delegate/scripts/org-delegate.sh" --project "$WORK/repo" --no-fetch --task-id "$ID" --title "Probe 368" --task "$TASK" >"$WORK/delegate.out" 2>&1; rc=$?
t=0; until hc read "$W" 2>/dev/null | grep -q "trust this folder"; do t=$((t + 3)); [ "$t" -lt "$WAIT" ] || break; sleep 3; done
if [ "$rc" -eq 10 ] && hc read "$W" 2>/dev/null | grep -q "trust this folder"; then res delegate-stops PASS
else res delegate-stops FAIL "org-delegate exit $rc; see: $(tr '\n' ' ' < "$WORK/delegate.out" | cut -c1-200)"; res saved "NO DATA"; res answer "NO DATA"; res task-reached "NO DATA"; res work-entry "NO DATA"; res files-gone "NO DATA"; exit 1; fi
[ -f "$STATE/resend/$ID/message" ] && [ -f "$STATE/resend/$ID/entry" ] && res saved PASS || res saved FAIL "no files in $STATE/resend/$ID"

p=$(esc prompt --task "$ID" 2>/dev/null)
aid=$(esc ask --task "$ID" --question "Probe: trust the folder of the probe repository?" --prompt "${p#PROMPT=}" --background "Host probe for the resend after the trust card." --if-yes "The probe worker gets its task." --if-no "It stays stopped." --recommend yes --why "Probe." --lang en 2>/dev/null | sed -n 's/^APPROVAL_ID=//p')
out=$(esc answer --id "${aid:-none}" --text yes 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q RESENT; then res answer PASS; else res answer FAIL "exit $rc: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"; [ -z "$aid" ] || esc remove --id "$aid" >/dev/null 2>&1; fi

s=0; until hc get --json "$W" 2>/dev/null | tr -d '\n' | grep -Eq '"status": *\{' && hc read "$W" 2>/dev/null | grep -q "Issue #368"; do s=$((s + 3)); [ "$s" -lt 60 ] || break; sleep 3; done
[ "$s" -lt 60 ] && res task-reached PASS || res task-reached FAIL "no status, or the task text is not on the screen: $(hc read "$W" 2>/dev/null | tail -5 | tr '\n' ' ' | cut -c1-200)"
bash "$ROOT/scripts/org" --as secretary doc get org-state 2>/dev/null | tr -d '\n' | grep -Eq "\"task_id\": *\"$ID\", *\"title\": *\"Probe 368\"|\"title\": *\"Probe 368\".*\"task_id\": *\"$ID\"" \
  && res work-entry PASS || res work-entry FAIL "no work entry with title Probe 368 for $ID"
[ ! -e "$STATE/resend/$ID" ] && [ ! -e "$M" ] && res files-gone PASS || res files-gone FAIL "resend folder or marker still there"
exit "$fail"
