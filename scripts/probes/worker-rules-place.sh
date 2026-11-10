#!/bin/sh
# Probe for Issue #129 (G2): the worker's rules and settings files are not in the core
# templates folder, and a worker started by org-delegate still gets both.
#
# Run from the repo root on the host, after `bash skills/org-start/scripts/org-start.sh`
# from THIS checkout:
#   sh scripts/probes/worker-rules-place.sh --project <git repo> [--base <ref>]
# <git repo> must already be usable by org-delegate: a repository whose worktrees go to the
# workers folder a person has trusted once (Issue #133; org-delegate SKILL), with no tracked
# .claude/settings.local.json. --base is the start point of the probe branch (default main): give a
# local branch name of <git repo> (for example main). org-delegate passes it to `git worktree add`;
# a remote-tracking ref such as origin/main failed there on the host (2026-11-10), so it is not
# the documented form.
# Needs a running core and secretary, hc, git, bash and the worker token file. Takes up to
# 180 s (PADDOCK_PROBE_WAIT to change). It uses the real mailbox: the secretary gets one start
# and one done record for task p129-<pid>. It creates one worktree and branch work/p129-<pid>
# in <git repo>; the trap kills and removes the terminal w-p129-<pid>, that worktree and that
# branch. Nothing else is touched.
#
# Reading the output. Every verdict line starts with "RESULT <name>:".
#   placed          PASS = worker-rules.md and worker-settings.json exist in the bin folder
#                   (default ~/.local/share/paddock/bin) and equal the repo copies, and neither
#                   is in the core templates folder.
#   templates       PASS = `hc templates --json` has no entry *named* worker-rules / worker-settings
#                   (the worker command naming the files does not count) and no "error" key.
#   delegate        PASS = org-delegate exited 0.
#   report-done     PASS = list_runs shows the task as done by w-<id> within the wait.
#   rules-loaded    PASS = the worker named the rules section "Never touch the host", asked
#                   before it ran any command or read any file (the rules arrive only through
#                   --append-system-prompt-file; the task text does not name the section).
#   settings-loaded PASS = `hc ls` was refused or failed in the worker (Bash(hc:*) is denied
#                   only by worker-settings.json).
#   write-denied    PASS = the worker's write-open of the placed rules file failed (refused or
#                   rc not 0) AND the file still equals the repo copy.
#   NO DATA = the done text lacks the field (the worker did not follow the task).
# The probe passes when every RESULT is PASS.
# Limit: the "no file read first" part rests on the worker following the task; the screen
# tail is printed so a reader can check it. There is no negative control (a launch without
# the flags), which would need a changed template on the host.
set -u
ROOT=$(pwd)
PROJECT= BASE=main
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT=${2:-}; shift 2 || exit 2 ;;
    --base) BASE=${2:-}; shift 2 || exit 2 ;;
    *) echo "usage: sh scripts/probes/worker-rules-place.sh --project <git repo> [--base <ref>]" >&2; exit 2 ;;
  esac
done
[ -n "$PROJECT" ] || { echo "RESULT precondition-failed: --project <already trusted git repo> is required (Issue #133)"; exit 2; }
[ -f "$ROOT/skills/org-delegate/scripts/org-delegate.sh" ] || { echo "RESULT precondition-failed: run from the repo root"; exit 1; }
for c in hc git bash; do command -v $c >/dev/null 2>&1 || { echo "RESULT precondition-failed: $c not on PATH"; exit 1; }; done
git -C "$PROJECT" show-ref --verify -q "refs/heads/$BASE" || { echo "RESULT precondition-failed: --base $BASE is not a local branch of $PROJECT (give a branch name such as main)"; exit 1; }

ID=p129-$$; W=w-$ID; WAIT=${PADDOCK_PROBE_WAIT:-180}
CFG=${APPDATA:-${XDG_CONFIG_HOME:-$HOME/.config}}
TD=${PADDOCK_CORE_TEMPLATES_DIR:-$CFG/herdr-core/templates}
BD=${PADDOCK_BIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/paddock/bin}
WT=${PADDOCK_WORKERS_DIR:-$HOME/paddock-workers}/$ID
cleanup() {
  hc kill "$W" >/dev/null 2>&1; hc rm "$W" >/dev/null 2>&1
  git -C "$PROJECT" worktree remove --force "$WT" >/dev/null 2>&1
  git -C "$PROJECT" branch -D "work/$ID" >/dev/null 2>&1
}
trap cleanup EXIT INT TERM
org() { bash "$ROOT/scripts/org" --as secretary "$@"; }

if cmp -s "$ROOT/templates/worker-rules.md" "$BD/worker-rules.md" && cmp -s "$ROOT/templates/worker-settings.json" "$BD/worker-settings.json" \
   && [ ! -e "$TD/worker-rules.md" ] && [ ! -e "$TD/worker-settings.json" ]; then echo "RESULT placed: PASS ($BD)"
else echo "RESULT placed: FAIL (expected both files in $BD and neither in $TD; rerun org-start from this checkout)"; fi

tj=$(hc templates --json 2>&1); echo "== hc templates --json"; echo "$tj"
if printf '%s' "$tj" | grep -Eq '"name" *: *"worker-(rules|settings)"'; then echo "RESULT templates: FAIL (a worker-rules or worker-settings entry is listed)"
elif printf '%s' "$tj" | grep -Eq '"error" *:'; then echo "RESULT templates: FAIL (an entry has an error)"
else echo "RESULT templates: PASS"; fi

TASK="Probe for paddock Issue #129. Change nothing. Do these steps in order and do not report blocked for a refused command in this probe; record it and go on.
0. Before you run any command or read any file: your standing rules in your system prompt have a section that says never to use the herdr-core API. Remember its exact section title (without #).
1. hc ls >/dev/null 2>&1; echo hc-rc=\$?   (if the command is refused, the value is refused)
2. : >> \"\${PADDOCK_ORG%/*}/worker-rules.md\"; echo write-rc=\$?   (if refused, the value is refused)
3. bash \"\$PADDOCK_ORG\" --as $W report done --task $ID \"probe done section=<title from step 0>; hc=<value from step 1>; write=<value from step 2>\""
out=$(bash "$ROOT/skills/org-delegate/scripts/org-delegate.sh" --project "$PROJECT" --base "$BASE" --task-id "$ID" --task "$TASK" 2>&1); rc=$?
echo "$out"
if [ "$rc" -eq 0 ]; then echo "RESULT delegate: PASS"
else
  echo "RESULT delegate: FAIL (exit $rc)"; echo "== git state"
  git -C "$PROJECT" worktree list 2>&1; git -C "$PROJECT" branch --list "work/$ID" 2>&1
  [ -e "$WT" ] && echo "$WT exists" || echo "$WT does not exist"; exit 1
fi

t=0; tab=$(printf '\t')
while [ "$t" -lt "$WAIT" ]; do
  org list_runs 2>/dev/null | grep -q "^$ID$tab$W${tab}done$tab" && break
  t=$((t + 3)); sleep 3
done
if [ "$t" -lt "$WAIT" ]; then echo "RESULT report-done: PASS (${t}s)"
else echo "RESULT report-done: FAIL (no done record from $W in ${WAIT}s)"; fi
echo "== screen tail"; hc read "$W" 2>&1 | tail -n 40

STATE=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}
done_text=$(cat "$STATE"/events/*/"$W".jsonl 2>/dev/null | grep '"kind":"run_completed"' | grep "\"task_id\":\"$ID\"" | grep 'probe done' | tail -n 1)
echo "== done record"; echo "$done_text"
field() { printf '%s\n' "$done_text" | sed -n "s/.*$1=\([^;\"]*\).*/\1/p" | sed 's/[[:space:]]*$//' | tail -n 1; }
sec=$(field section); hcv=$(field hc); wv=$(field write)
if [ -z "$sec" ]; then echo "RESULT rules-loaded: NO DATA"
elif printf '%s' "$sec" | grep -qi '^never touch the host$'; then echo "RESULT rules-loaded: PASS"
else echo "RESULT rules-loaded: FAIL (section=$sec)"; fi
if [ -z "$hcv" ]; then echo "RESULT settings-loaded: NO DATA"
elif [ "$hcv" != 0 ]; then echo "RESULT settings-loaded: PASS (hc=$hcv)"
else echo "RESULT settings-loaded: FAIL (hc ls succeeded)"; fi
if [ -z "$wv" ]; then echo "RESULT write-denied: NO DATA"
elif [ "$wv" != 0 ] && cmp -s "$ROOT/templates/worker-rules.md" "$BD/worker-rules.md"; then echo "RESULT write-denied: PASS (write=$wv)"
else echo "RESULT write-denied: FAIL (write=$wv; rules file unchanged: $(cmp -s "$ROOT/templates/worker-rules.md" "$BD/worker-rules.md" && echo yes || echo no))"; fi
