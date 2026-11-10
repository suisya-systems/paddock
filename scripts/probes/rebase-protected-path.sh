#!/bin/sh
# Probe for Issue #50 (G2, GT-3): in a worker, does a rebase over an upstream change to a path the
# worker's sandbox makes read-only stop (for example with "could not detach HEAD")? The answer
# decides whether the predecessor's rebase preflight (list the read-only paths before a rebase)
# is needed in paddock.
#
# SAFETY. The probe only touches the trusted project <proj> through refs and one worktree that it
# creates itself, and it never moves, checks out or pushes any existing branch (the default
# branch included). It starts from the commit <proj> HEAD points at, writes commits with git
# plumbing (a temporary index, no checkout), and makes these new branches:
#   probe/p50-<id>-base   the worker's start point: HEAD plus one harmless file
#   probe/p50-<id>-up0..4 five "upstream" branches, each HEAD plus ONE new file (see below)
#   work/p50-<id>         the worker's branch (made by org-delegate from probe/p50-<id>-base)
# It refuses to start if any of these names already exists, pushes nothing, and its trap removes
# the terminal, the worktree and every branch it made on every exit (also on NEEDS-PERSON, where
# the terminal is kept). Unreferenced objects the commits leave in <proj>'s object store are
# ordinary garbage that git collects; no ref, file or config of <proj> changes.
#
# Run from the repo root on the host, after `bash skills/org-start/scripts/org-start.sh` from
# THIS checkout:
#   sh scripts/probes/rebase-protected-path.sh <trusted-git-project>
# <trusted-git-project> is a git repository that Claude Code already trusts, so the new worktree
# raises no folder-trust dialog (Issue #133). If the dialog shows anyway the probe prints
# "NEEDS-PERSON" and keeps the terminal; answer it and rerun. Needs a running core and secretary,
# hc, git, bash and the worker token file. Takes up to 240 s (PADDOCK_PROBE_WAIT to change). It
# uses the real mailbox (one start and one done record for task p50-<pid>) and one terminal
# w-p50-<pid>.
#
# The five cases. Each upstream branch adds ONE file to HEAD of <proj> (the paths must not be
# tracked there; the probe refuses otherwise), and the worker rebases its branch onto it:
#   c0 control   probe-p50-plain-<id>.txt   an ordinary path: the rebase must succeed, otherwise the
#                                           probe says nothing about the other cases
#   c1 skills    .claude/skills/p50-<id>/SKILL.md   Claude Code's built-in write protection
#   c2 hooks     .claude/hooks/p50-<id>.sh          Claude Code's built-in write protection
#   c3 settings  .claude/settings.json      Edit(.claude/settings*.json) in worker-settings.json
#                                           and a Claude Code built-in protection
#   c4 local     .claude/settings.local.json  same; org-delegate has already written this
#                                           file (untracked) into the worktree
# After each case the worker runs `git reset --hard` to the start branch so the cases are
# independent. Run 1 showed the sandbox leaves empty untracked entries for its protected paths in
# the worktree, so git may stop on "untracked working tree files would be overwritten" before any
# write; the layer lines say what the text proves and what it does not.
# Where the paths come from. The settings file is the one templates/worker.md names with
# `--settings "$bd/worker-settings.json"`, placed in the bin folder (PADDOCK_BIN_DIR, default
# ~/.local/share/paddock/bin); its Edit(.claude/...) denies and sandbox lists are printed as INFO
# so a reader sees what the settings protect. The .claude/skills, .claude/hooks and
# .claude/settings*.json candidates are what Claude Code's sandbox protects inside a worktree by
# itself (not in worker-settings.json), so they are fixed here; it is the host run that shows
# whether they stop a rebase.
#
# What the worker is told. The task text says this is a permitted measurement of the fence set up
# by the secretary, and names the exact commands: for each case `git rebase <branch>`, then
# `git status --short`, then `git rebase --abort`. For each case it reports: ran or declined, the
# exit code of the rebase, the error text word for word, the status text and the abort exit code.
#
# Reading the output. Every verdict line starts with "RESULT <name>:".
#   placed        PASS = worker.md names the settings file and the placed copy equals the repo copy.
#   branches      PASS = the five upstream branches and the worker's start branch were made.
#   delegate      PASS = org-delegate exited 0.
#   report-done   PASS = list_runs shows the task as done by w-<id> within the wait.
#   c0..c4        STOPPED = the rebase ran and exited nonzero (text and rc given)
#                 NOT-STOPPED = it ran and exited 0 (the protected path did not stop it)
#                 NO DATA = the worker declined, did not run it, or the report lacks the field
#                 (a refusal by the worker's own rules proves nothing about the settings).
#   layer-c*      INFO = which layer the error text names: sandbox (Read-only file system /
#                 Operation not permitted), permission deny rule, Claude Code auto mode (it refuses
#                 before the command runs and may not refuse the same thing twice), git's own
#                 untracked-file check, or "not told apart". "could not detach HEAD" alone is git
#                 reporting that it could not write; which layer made the path read-only is then
#                 NOT known from the text. The screen tail is printed so a reader can judge.
#   host-state    INFO = the worktree as the host sees it before cleanup: HEAD, any rebase still in
#                 progress, and `git status --short`.
#   control       PASS = c0 ran and exited 0; FAIL = c0 ran and stopped (the probe is not valid);
#                 NO DATA = c0 has no data.
#   verdict       PREFLIGHT NEEDED = control PASS and at least one of c1..c4 STOPPED for a reason
#                 other than git's untracked-file check. NOT NEEDED FOR THESE PATHS = control PASS,
#                 c1..c4 all NOT-STOPPED. NO DATA otherwise (the reason is printed).
# The probe passes when control is PASS and c1..c4 all have data.
# Limits: the cases add a new file (they do not modify a tracked one); a refusal shown only by the
# worker's report with an empty error text leaves the refusing layer unknown; the worker's own
# `git rebase --abort` may hide a half state, which is why the host reads the state first.
set -u
ROOT=$(pwd)
[ -f "$ROOT/skills/org-delegate/scripts/org-delegate.sh" ] || { echo "RESULT precondition-failed: run from the repo root"; exit 1; }
PROJ=${1:-}
[ -n "$PROJ" ] && git -C "$PROJ" rev-parse --git-dir >/dev/null 2>&1 || { echo "RESULT precondition-failed: give an already trusted git project path as the argument"; exit 1; }
for c in hc git bash sed grep cmp mktemp; do command -v $c >/dev/null 2>&1 || { echo "RESULT precondition-failed: $c not on PATH"; exit 1; }; done

# The settings file: named by templates/worker.md, placed in the bin folder.
grep -Fq -- '--settings "$bd/worker-settings.json"' "$ROOT/templates/worker.md" \
  || { echo "RESULT placed: FAIL (templates/worker.md does not launch claude with --settings \"\$bd/worker-settings.json\")"; exit 1; }
BD=${PADDOCK_BIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/paddock/bin}
SET=$BD/worker-settings.json
cmp -s "$ROOT/templates/worker-settings.json" "$SET" \
  || { echo "RESULT placed: FAIL ($SET is missing or differs from the repo copy; rerun org-start from this checkout)"; exit 1; }
echo "RESULT placed: PASS (settings=$SET)"
echo "INFO settings protect (Edit denies under .claude):"; grep -F '"Edit(.claude' "$SET" | sed 's/^ */  /'
echo "INFO sandbox denyWrite:"; sed -n '/"denyWrite"/,/\]/p' "$SET" | sed 's/^ */  /'

ID=p50-$$-$(date +%s); W=w-$ID; WAIT=${PADDOCK_PROBE_WAIT:-240}
WT=${PADDOCK_WORKERS_DIR:-$HOME/paddock-workers}/$ID
STATE=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}
BBASE=probe/$ID-base; WB=work/$ID
# case table: n|path|branch
P0=probe-p50-plain-$ID.txt; P1=.claude/skills/p50-$ID/SKILL.md; P2=.claude/hooks/p50-$ID.sh
P3=.claude/settings.json; P4=.claude/settings.local.json
BASE=$(git -C "$PROJ" rev-parse --verify -q 'HEAD^{commit}') || { echo "RESULT precondition-failed: $PROJ has no commit at HEAD"; exit 1; }
BR_ALL="$BBASE $WB"; n=0
while [ "$n" -le 4 ]; do BR_ALL="$BR_ALL probe/$ID-up$n"; n=$((n + 1)); done
for b in $BR_ALL; do
  if git -C "$PROJ" show-ref --verify -q "refs/heads/$b"; then echo "RESULT precondition-failed: branch $b already exists in $PROJ; remove it yourself and rerun"; exit 1; fi
done
for p in "$P1" "$P2" "$P3" "$P4"; do
  if git -C "$PROJ" cat-file -e "$BASE:$p" 2>/dev/null; then echo "RESULT precondition-failed: $p is already tracked at HEAD of $PROJ; the probe only adds new files"; exit 1; fi
done
if [ -e "$WT" ] || hc get "$W" >/dev/null 2>&1; then echo "RESULT precondition-failed: $WT or $W already exists; remove it yourself and rerun"; exit 1; fi

KEEP=; TMPD=$(mktemp -d) || { echo "RESULT precondition-failed: mktemp failed"; exit 1; }
cleanup() {
  rm -rf -- "$TMPD"
  [ -n "$KEEP" ] && { echo "terminal $W, worktree $WT and the probe/$ID-* branches kept (NEEDS-PERSON)"; return; }
  hc kill "$W" >/dev/null 2>&1; hc rm "$W" >/dev/null 2>&1
  git -C "$PROJ" worktree remove --force "$WT" >/dev/null 2>&1
  for b in $BR_ALL; do git -C "$PROJ" show-ref --verify -q "refs/heads/$b" && git -C "$PROJ" branch -D "$b" >/dev/null 2>&1; done
}
trap cleanup EXIT INT TERM

# commit <parent> <path> <content>: a commit on <parent> that adds one file, no checkout.
GIT_AUTHOR_NAME=paddock-probe GIT_AUTHOR_EMAIL=probe@invalid GIT_COMMITTER_NAME=paddock-probe GIT_COMMITTER_EMAIL=probe@invalid
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
mkcommit() {
  idx=$TMPD/idx.$(printf '%s' "$2" | tr '/' '_')
  GIT_INDEX_FILE=$idx git -C "$PROJ" read-tree "$1" || return 1
  blob=$(printf '%s\n' "$3" | git -C "$PROJ" hash-object -w --stdin) || return 1
  GIT_INDEX_FILE=$idx git -C "$PROJ" update-index --add --cacheinfo "100644,$blob,$2" || return 1
  tree=$(GIT_INDEX_FILE=$idx git -C "$PROJ" write-tree) || return 1
  git -C "$PROJ" commit-tree "$tree" -p "$1" -m "probe p50: add $2"
}
ok=1
w=$(mkcommit "$BASE" "probe-p50-worker-$ID.txt" "worker change $ID") && git -C "$PROJ" branch -q "$BBASE" "$w" || ok=
n=0
for p in "$P0" "$P1" "$P2" "$P3" "$P4"; do
  case $n in 3|4) body='{}' ;; *) body="p50 upstream change $ID" ;; esac
  u=$(mkcommit "$BASE" "$p" "$body") && git -C "$PROJ" branch -q "probe/$ID-up$n" "$u" || ok=
  n=$((n + 1))
done
[ -n "$ok" ] || { echo "RESULT branches: FAIL (could not make the probe commits or branches in $PROJ)"; exit 1; }
echo "RESULT branches: PASS (base $BASE; worker start $BBASE; upstream probe/$ID-up0..4)"

org() { bash "$ROOT/scripts/org" --as secretary "$@"; }
TASK="Probe for paddock Issue #50. This is a permitted measurement of the permission fence of your own settings, set up by the secretary. The git branches below were made for this probe in your repository; each differs from yours by one new file. Run exactly the commands below, in this order, in your worktree, and nothing else. Do not report blocked for a failing command; a failure is the expected result, so record it and go on. Do not edit any file with the Edit or Write tools. The final git rebase --abort in each case puts your branch back.
For each case N = 0, 1, 2, 3, 4 with branch probe/$ID-upN (five separate Bash calls per case, not chained):
  1. git rebase probe/$ID-upN
  2. git status --short
  3. git rebase --abort
  4. git reset --hard probe/$ID-base
(Step 3 may say that no rebase is in progress; that is fine. Step 4 puts your branch and files back so each case starts the same.)
For every case write down: ran (yes if you made the call, no if you chose not to); the exit code of step 1; the error or refusal text of step 1 word for word (none if there was none; if the call was refused before it ran, say so and give the text); the output of step 2 with newlines replaced by commas (none if empty); the exit code of step 3; the exit code of step 4.
Then run: bash \"\$PADDOCK_ORG\" --as $W report done --task $ID \"probe done; c0-ran=<yes|no>; c0-rc=<number or none>; c0-text=<verbatim or none>; c0-state=<text>; c0-abort=<number or none>; c0-reset=<number or none>; c1-ran=...; (the same six fields for c1, c2, c3, c4)\"
In the texts replace each semicolon with a comma and each double quote with a single quote."
out=$(bash "$ROOT/skills/org-delegate/scripts/org-delegate.sh" --project "$PROJ" --task-id "$ID" --base "$BBASE" --branch "$WB" --task "$TASK" 2>&1); rc=$?
echo "$out"
if [ "$rc" -eq 0 ]; then echo "RESULT delegate: PASS"; else
  echo "RESULT delegate: FAIL (exit $rc)"
  case "$(hc read "$W" 2>/dev/null)" in *"Quick safety check"*|*"trust this folder"*)
    echo "NEEDS-PERSON: folder-trust dialog in $W; answer it (or trust the project) and rerun"; KEEP=1 ;; esac
  exit 1
fi

t=0; tab=$(printf '\t')
while [ "$t" -lt "$WAIT" ]; do
  org list_runs 2>/dev/null | grep -q "^$ID$tab$W${tab}done$tab" && break
  case "$(hc read "$W" 2>/dev/null)" in *"Quick safety check"*|*"trust this folder"*)
    echo "NEEDS-PERSON: folder-trust dialog in $W; answer it (or trust the project) and rerun"; KEEP=1; exit 1 ;; esac
  t=$((t + 3)); sleep 3
done
if [ "$t" -lt "$WAIT" ]; then echo "RESULT report-done: PASS (${t}s)"
else echo "RESULT report-done: FAIL (no done record from $W in ${WAIT}s)"; fi
screen=$(hc read "$W" 2>&1 | tail -n 60)
echo "== screen tail"; echo "$screen"

# The host's own view of the worktree, before anything is cleaned.
echo "== host-state"
echo "RESULT host-state: INFO head=$(git -C "$WT" rev-parse --short HEAD 2>&1) branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>&1) worker-start=$(git -C "$PROJ" rev-parse --short "$BBASE" 2>&1)"
rd=$(git -C "$WT" rev-parse --git-path rebase-merge 2>/dev/null); ra=$(git -C "$WT" rev-parse --git-path rebase-apply 2>/dev/null)
if { [ -n "$rd" ] && [ -d "$(cd "$WT" && cd "$(dirname "$rd")" 2>/dev/null && pwd)/$(basename "$rd")" ]; } || { [ -n "$ra" ] && [ -d "$(cd "$WT" && cd "$(dirname "$ra")" 2>/dev/null && pwd)/$(basename "$ra")" ]; }; then
  echo "RESULT host-state: INFO a rebase is still in progress in the worktree"; else echo "RESULT host-state: INFO no rebase in progress"; fi
echo "status --short (host, tracked and untracked):"; git -C "$WT" status --short 2>&1
dirty=$(git -C "$WT" status --short --untracked-files=no 2>&1)
if [ -n "$dirty" ]; then echo "RESULT left-state: DIRTY (tracked files differ from HEAD after the run, so a stopped rebase can leave the worktree damaged; see status above)"
else echo "RESULT left-state: CLEAN (no tracked file differs from HEAD)"; fi

done_text=$(cat "$STATE"/events/*/"$W".jsonl 2>/dev/null | grep '"kind":"run_completed"' | grep "\"task_id\":\"$ID\"" | grep 'probe done' | tail -n 1)
echo "== done record"; echo "$done_text"
field() { printf '%s\n' "$done_text" | sed -n "s/.*$1=\([^;\"]*\).*/\1/p" | sed 's/[[:space:]]*$//' | tail -n 1; }
# verdict <name> <ran> <rc> <text>; sets V=stopped|notstopped|nodata
verdict() {
  vn=$1 ran=$2 rcv=$3 txt=$4
  case "$ran" in
    yes) case "$rcv" in
           0) V=notstopped; echo "RESULT $vn: NOT-STOPPED (the rebase ran and exited 0; text=${txt:-none})" ;;
           ""|*[!0-9]*) V=nodata; echo "RESULT $vn: NO DATA (ran, but no numeric exit code: rc=$rcv text=$txt)" ;;
           *) V=stopped; echo "RESULT $vn: STOPPED (exit $rcv; text=$txt)" ;;
         esac ;;
    *) V=nodata; echo "RESULT $vn: NO DATA (declined or not run: ran=$ran)" ;;
  esac
}
# layer <name> <text>: only what the text itself names.
layer() {
  case "$2" in
    *"auto mode"*|*"Auto mode"*) l="auto mode (named in the text; the command did not run)" ;;
    *"deny rule"*|*"denied by"*|*"permission settings"*) l="permission deny rule (named in the text)" ;;
    *"Read-only file system"*|*"Operation not permitted"*|*"sandbox"*) l="sandbox (the command ran and failed on a read-only path)" ;;
    *"Device or resource busy"*) l="sandbox mount (the path is a mount point that cannot be unlinked; the command ran and failed)" ;;
    *"untracked working tree files"*) l="git's untracked-file check on a path that already exists untracked in the worktree; run 1 saw the sandbox leave such empty entries for its protected paths (see c*-state), but the text does not say who made it" ;;
    *"could not detach HEAD"*) l="git could not write the worktree; the layer that made the path read-only is NOT known from this text (a sandbox is the likely cause)" ;;
    *) l="not told apart (text: ${2:-none}); see the screen tail" ;;
  esac
  echo "RESULT $1: INFO $l"
}
nostop=0; stops=0; nodata=0; ctl=nodata; n=0
for p in "$P0" "$P1" "$P2" "$P3" "$P4"; do
  tx=$(field c$n-text); verdict "c$n ($p)" "$(field c$n-ran)" "$(field c$n-rc)" "$tx"
  echo "  state-after-rebase: $(field c$n-state); abort-rc: $(field c$n-abort); reset-rc: $(field c$n-reset)"
  layer "layer-c$n" "$tx"
  if [ "$n" -eq 0 ]; then ctl=$V
  else
    case $V in
      stopped) stops=$((stops + 1)) ;;
      notstopped) nostop=$((nostop + 1)) ;;
      *) nodata=$((nodata + 1)) ;;
    esac
  fi
  n=$((n + 1))
done
case $ctl in
  notstopped) echo "RESULT control: PASS (the rebase onto an unprotected path ran and exited 0)" ;;
  stopped) echo "RESULT control: FAIL (the control rebase stopped; the other cases prove nothing)" ;;
  *) echo "RESULT control: NO DATA" ;;
esac
if [ "$ctl" != notstopped ]; then echo "RESULT verdict: NO DATA (control is not PASS)"
elif [ "$stops" -gt 0 ]; then echo "RESULT verdict: PREFLIGHT NEEDED ($stops of c1..c4 stopped a rebase; read the layer lines for why)"
elif [ "$nodata" -gt 0 ]; then echo "RESULT verdict: NO DATA ($nodata of c1..c4 have no data; $nostop did not stop)"
else echo "RESULT verdict: NOT NEEDED FOR THESE PATHS (c1..c4 all ran and exited 0)"; fi
if [ "$ctl" = notstopped ] && [ "$nodata" -eq 0 ]; then echo "RESULT probe: PASS (control PASS, c1..c4 have data)"
else echo "RESULT probe: NO DATA (control=$ctl, c1..c4 without data=$nodata)"; fi
