#!/bin/sh
# Host probe for Issue #362 (decision 0011): what the sandbox could not measure. (1) Does the clone pick up
# the login the secretary has, with the GitHub CLI and with plain git? (2) Is the base read from origin/HEAD?
# (3) With a real worker on a fresh clone: is the folder-trust dialog held (not answered), and after a yes
# does `answer` press it and does the worker start?
#
#   sh scripts/probes/clone-trust.sh [--repo OWNER/NAME] [--no-worker] [--task-id T]
#
# Run from the paddock repository root, on the host, in a terminal that hc launched, after
# `bash skills/org-start/scripts/org-start.sh` from THIS checkout, with a running core, a gh login (gh auth
# status) and a logged-in claude. --repo is the repository to clone (default octocat/Hello-World: public, and its
# default branch is master, not main, so the base check means something; name a private one to measure
# private access). Never clones into your real projects folder: it uses a private temp folder for
# PADDOCK_PROJECTS_DIR and PADDOCK_PROJECTS_FILE. --no-worker stops after the clone checks (no hc, no claude).
# About 1-3 minutes with the worker (PADDOCK_PROBE_WAIT seconds at most, default 120).
#
# The worker part starts one worker w-p362-<T> through org-delegate on the temp clone; its first message stops at
# the trust dialog (org-delegate exit 10 is expected). The probe NEVER presses a key itself: only
# org-escalation prompt and answer do, as the secretary would. Claude Code stores its own trust entry for the
# clone's worktree in ~/.claude.json (the probe does not touch that file); it is a path in a temp folder.
# On exit it removes the terminal, worktree, branch and the temp folder.
#
# Reading the output. Every verdict line starts with "RESULT <name>:".
#   clone-cli      PASS = org-clone exited 0 with the GitHub CLI on PATH (the login worked for the clone).
#   clone-git      PASS = org-clone exited 0 with the GitHub CLI hidden from PATH (plain git clone: the person's
#                  git credential or an anonymous public clone worked). NO DATA = no gh was found to hide.
#   base           PASS = the projects.md base equals the remote's default branch (git ls-remote --symref).
#   rerun-skip     PASS = a second run printed the same name, exited 0 and added no row.
#   no-access      PASS = a repository that does not exist exits 4 and records nothing.
#   trust-held     PASS = org-escalation prompt on the worker's dialog exited 3 (PROMPT=) and the dialog was
#                  still on the screen afterwards (nothing pressed).
#   trust-answer   PASS = answer --text yes exited 0 and the worker reported a status afterwards.
#   marker-cleared PASS = the marker file is gone after the yes.
# NO DATA = a step before it did not run. The probe passes (exit 0) when every RESULT is PASS. Paste the whole output back.
# Exit: 0 all PASS, 1 a FAIL or NO DATA, 2 bad argument, 3 a tool is missing, 6 a precondition failed.
set -u

die() { c=$1; shift; echo "clone-trust: $*" >&2; exit "$c"; }
usage() { sed -n '2,38p' "$0"; }

repo=octocat/Hello-World T= noworker=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --no-worker) noworker=1; shift ;;
    --repo|--task-id) [ $# -ge 2 ] || die 2 "$1 needs a value"
      case "$1" in --repo) repo=$2 ;; *) T=$2 ;; esac; shift 2 ;;
    *) die 2 "unknown option: $1" ;;
  esac
done
case "$repo" in */*/*|*/|/*|*/) die 2 "--repo must be OWNER/NAME" ;; */*) ;; *) die 2 "--repo must be OWNER/NAME" ;; esac
for c in git bash awk mktemp; do command -v "$c" >/dev/null 2>&1 || die 3 "$c not found on PATH"; done
ROOT=$(pwd)
CLONE="$ROOT/skills/org-clone/scripts/org-clone.sh"
[ -f "$CLONE" ] && [ -f "$ROOT/skills/org-delegate/scripts/org-delegate.sh" ] || die 6 "run from the paddock repository root"
GHBIN=$(command -v gh 2>/dev/null)
[ -n "$noworker" ] || for c in hc claude; do command -v "$c" >/dev/null 2>&1 || die 3 "$c not found on PATH (run inside a terminal that hc launched, or use --no-worker)"; done

[ -n "$T" ] || T=$(date -u +%m%d%H%M)
case "$T" in *[!a-z0-9]*|"") die 2 "--task-id may hold only a-z and 0-9" ;; esac
ID=p362-$T; W=w-$ID; WAIT=${PADDOCK_PROBE_WAIT:-120}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/probe362.XXXXXX") || die 6 "cannot make a temp folder"
NAME=${repo#*/}
fail=0; KEEP=
res() { echo "RESULT $1: $2${3:+ ($3)}"; case "$2" in FAIL|"NO DATA") fail=1 ;; esac; }
cleanup() {
  claude_link_restore
  if [ -z "$noworker" ]; then
    hc kill "$W" >/dev/null 2>&1; hc rm "$W" >/dev/null 2>&1
    git -C "$WORK/pp/${repo%%/*}/$NAME" worktree remove -f "${PADDOCK_WORKERS_DIR:-$HOME/paddock-workers}/$ID" >/dev/null 2>&1
  fi
  case "$WORK" in "${TMPDIR:-/tmp}"/probe362.*) rm -rf "$WORK" ;; esac
  echo "cleanup: terminal $W, worktree, and $WORK removed"
}
. "$(dirname "$0")/claude-link.sh"
claude_link_save
trap cleanup EXIT; trap 'exit 130' INT TERM
export PADDOCK_PROJECTS_DIR="$WORK/pp" PADDOCK_PROJECTS_FILE="$WORK/projects.md"
org() { bash "$ROOT/scripts/org" --as secretary "$@"; }
esc() { bash "$ROOT/skills/org-escalation/scripts/org-escalation.sh" "$@"; }

# 1. The clone with the GitHub CLI (when there is one), and the base.
out=$(bash "$CLONE" "$repo" 2>"$WORK/clone.err"); rc=$?
if [ $rc -eq 0 ] && [ "$out" = "$NAME" ]; then res clone-cli PASS "${GHBIN:-no gh on PATH: this was plain git}"; else res clone-cli FAIL "exit $rc: $(tr '\n' ' ' < "$WORK/clone.err" | cut -c1-200)"; fi
want=$(git ls-remote --symref "https://github.com/$repo.git" HEAD 2>/dev/null | sed -n 's#^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$#\1#p')
got=$(awk -F'|' -v n="$NAME" '{ g = $2; gsub(/ /, "", g) } g == n { b = $4; gsub(/ /, "", b); print b }' "$WORK/projects.md" 2>/dev/null)
if [ -z "$want" ] || [ -z "$got" ]; then res base "NO DATA" "remote default='$want' row base='$got'"
elif [ "$want" = "$got" ]; then res base PASS "$got"; else res base FAIL "remote $want, row $got"; fi
rows=$(grep -c "^| $NAME |" "$WORK/projects.md" 2>/dev/null)
out2=$(bash "$CLONE" "https://github.com/$repo.git" 2>/dev/null); rc2=$?
[ $rc2 -eq 0 ] && [ "$out2" = "$NAME" ] && [ "$(grep -c "^| $NAME |" "$WORK/projects.md")" = "$rows" ] && res rerun-skip PASS || res rerun-skip FAIL "exit $rc2, name '$out2'"
out3=$(bash "$CLONE" "p362-no-such-owner/none-$T" 2>"$WORK/na.err"); rc3=$?
[ $rc3 -eq 4 ] && [ "$(wc -l < "$WORK/projects.md")" -eq "$(( rows + 2 ))" ] && res no-access PASS || res no-access FAIL "exit $rc3: $(tr '\n' ' ' < "$WORK/na.err" | cut -c1-160)"

# 2. The plain git path: the same repository under another folder, the GitHub CLI hidden from PATH.
if [ -n "$GHBIN" ]; then
  HID="$WORK/nogh"; mkdir -p "$HID"
  for d in $(printf '%s' "$PATH" | tr ':' ' '); do for f in "$d"/*; do [ -x "$f" ] && [ "$(basename "$f")" != gh ] && [ ! -e "$HID/$(basename "$f")" ] && ln -s "$f" "$HID/$(basename "$f")" 2>/dev/null; done; done
  out4=$(PADDOCK_PROJECTS_DIR="$WORK/pp2" PADDOCK_PROJECTS_FILE="$WORK/projects2.md" PATH="$HID" bash "$CLONE" "$repo" 2>"$WORK/git.err"); rc4=$?
  [ $rc4 -eq 0 ] && [ "$out4" = "$NAME" ] && res clone-git PASS || res clone-git FAIL "exit $rc4: $(tr '\n' ' ' < "$WORK/git.err" | cut -c1-200)"
else res clone-git "NO DATA" "no gh found to hide"; fi

[ -z "$noworker" ] || { echo "worker part skipped (--no-worker)"; exit "$fail"; }

# 3. A real worker on the fresh clone: the dialog is held, then answered by the person's yes.
CL="$WORK/pp/${repo%%/*}/$NAME"
M=$(git -C "$CL" rev-parse --absolute-git-dir 2>/dev/null)/paddock-trust-pending
TASK="Probe for paddock Issue #362. Change nothing. Reply with the single word OK and stop."
bash "$ROOT/skills/org-delegate/scripts/org-delegate.sh" --project "$NAME" --task-id "$ID" --task "$TASK" >"$WORK/delegate.out" 2>&1; rc=$?
[ "$rc" -eq 0 ] || [ "$rc" -eq 10 ] || { res trust-held FAIL "org-delegate exit $rc; see $WORK/delegate.out"; res trust-answer "NO DATA"; res marker-cleared "NO DATA"; exit 1; }
t=0; until hc read "$W" 2>/dev/null | grep -q "trust this folder"; do
  t=$((t + 3)); [ "$t" -lt "$WAIT" ] || break; sleep 3
done
if hc read "$W" 2>/dev/null | grep -q "trust this folder"; then
  p=$(esc prompt --task "$ID" 2>"$WORK/prompt.err"); rc=$?
  if [ "$rc" -eq 3 ] && hc read "$W" 2>/dev/null | grep -q "trust this folder"; then res trust-held PASS; else res trust-held FAIL "prompt exit $rc: $p"; fi
  aid=$(esc ask --task "$ID" --question "Probe: trust the folder of $repo?" --prompt "${p#PROMPT=}" --background "Host probe for the clone step." --if-yes "The probe worker starts." --if-no "It stays stopped." --recommend yes --why "Probe." --lang en 2>/dev/null | sed -n 's/^APPROVAL_ID=//p')
  if [ -n "$aid" ] && esc answer --id "$aid" --text yes --then-send "$TASK" >"$WORK/answer.out" 2>&1; then
    s=0; until hc get --json "$W" 2>/dev/null | tr -d '\n' | grep -Eq '"status": *\{'; do s=$((s + 3)); [ "$s" -lt 30 ] || break; sleep 3; done
    [ "$s" -lt 30 ] && res trust-answer PASS || res trust-answer FAIL "no status after the answer"
  else res trust-answer FAIL "ask/answer failed: $(tr '\n' ' ' < "$WORK/answer.out" 2>/dev/null | cut -c1-200)"; [ -z "$aid" ] || esc remove --id "$aid" >/dev/null 2>&1; fi
  [ ! -e "$M" ] && res marker-cleared PASS || res marker-cleared FAIL "$M still exists"
else
  res trust-held "NO DATA" "no dialog on $W within ${WAIT}s: the clone's path may already be trusted; screen: $(hc read "$W" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
  res trust-answer "NO DATA"; res marker-cleared "NO DATA"
fi
exit "$fail"
