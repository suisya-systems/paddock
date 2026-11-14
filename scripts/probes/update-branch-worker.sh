#!/bin/sh
# Host probe for Issue #330 (the part left open): org-update-branch's worker check, with PADDOCK_ORG
# set by a real worker's launch command, in a real worker session. The skill
# (skills/org-update-branch/SKILL.md "Not measured") was only tested against a local bare repository.
#
#   sh scripts/probes/update-branch-worker.sh --repo OWNER/NAME --project DIR [--task-id T]
#
# Run from the paddock repository root, on the host, in a terminal that hc launched, after
# `bash skills/org-start/scripts/org-start.sh` from THIS checkout (so the org script is placed where
# the worker template points), with a running core and secretary. --repo is the scratch repository
# (happy-ryo/paddock-proto2-scratch); --project is a clone of it that Claude Code already trusts
# (no folder-trust dialog; if one shows the probe prints NEEDS-PERSON and keeps the terminal). The
# gh/git login must be able to push branches to --repo. Never suisya-systems/paddock (exit 6).
# About 1-3 minutes (PADDOCK_PROBE_WAIT seconds at most, default 240).
#
# What it does: pushes two side branches of --repo from its main (never main itself, which may be
# protected): p330w-<T>-ok (adds one plain file) and p330w-<T>-prot (adds .claude/skills/p330w-<T>/NOTE.md,
# a path the sandbox protects). It starts one worker w-p330w-<T> with org-delegate. The worker runs
# org-update-branch.sh from this checkout twice, --base <ok> then --base <prot>, and returns the
# result with `report done` (its text carries env, ok-rc, ok-moved, ok-has-base, prot-rc, prot-moved,
# prot-listed). Afterwards the host runs the same <prot> merge with PADDOCK_ORG unset.
# On exit it removes the terminal, worktree, local branch and the two remote side branches. It writes
# the mailbox of the real state folder (one start and one done record) and the run folder
# ${XDG_STATE_HOME:-~/.local/state}/paddock-p330w/<T>.
#
# Reading the output. Every verdict line starts with "RESULT <name>:".
#   delegate              PASS = org-delegate exited 0.
#   report-done           PASS = list_runs shows the task done by w-<id> within the wait.
#   in-box                PASS = the worker's event file holds a run_completed record for the secretary.
#   worker-env            PASS = the worker saw PADDOCK_ORG set (env=set), so the check was active.
#   worker-merge          PASS = org-update-branch in the worker exited 0 on the plain range, HEAD
#                         moved, and the branch holds origin/<ok>. FAIL prints the exit code (5 = the
#                         origin/<base> not visible to the worker (it cannot fetch); 6 = merge failed, e.g. no git identity).
#   worker-protected-stop PASS = on the range touching .claude/skills the worker run exited 4, named
#                         the path (prot-listed=yes) and HEAD did not move.
#   host-control          PASS = the same range with PADDOCK_ORG unset (the secretary's case) exits 0
#                         and merges. NO DATA = a step before it did not run.
# NO DATA = the worker's done text lacks the field (it did not follow the task). The probe passes
# (exit 0) when every RESULT is PASS. Paste the whole output back.
# Exit: 0 all PASS, 1 a FAIL or NO DATA, 2 bad argument, 3 a tool is missing, 6 a precondition failed.
set -u

die() { c=$1; shift; echo "update-branch-worker: $*" >&2; exit "$c"; }
usage() { sed -n '2,38p' "$0"; }

repo= project= T=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo|--project|--task-id) [ $# -ge 2 ] || die 2 "$1 needs a value"
      case "$1" in --repo) repo=$2 ;; --project) project=$2 ;; *) T=$2 ;; esac; shift 2 ;;
    *) die 2 "unknown option: $1" ;;
  esac
done

for c in git bash; do command -v "$c" >/dev/null 2>&1 || die 3 "$c not found on PATH"; done
ROOT=$(pwd)
OUB="$ROOT/skills/org-update-branch/scripts/org-update-branch.sh"
DELEGATE="$ROOT/skills/org-delegate/scripts/org-delegate.sh"
[ -f "$DELEGATE" ] && [ -f "$OUB" ] || die 2 "run from the paddock repository root"
PADDOCK=suisya-systems/paddock
[ -n "$repo" ] && [ -n "$project" ] || die 2 "needs --repo OWNER/NAME and --project DIR"
repo=$(printf '%s' "$repo" | tr 'A-Z' 'a-z')
case "$repo" in */*/*|*/|/*) die 2 "--repo must be OWNER/NAME" ;; */*) ;; *) die 2 "--repo must be OWNER/NAME" ;; esac
[ "$repo" != "$PADDOCK" ] || die 6 "never this repository: name the scratch repository"
command -v hc >/dev/null 2>&1 || die 3 "hc not found on PATH (run inside a terminal that hc launched)"
git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || die 6 "$project is not a git repository"
url=$(git -C "$project" remote get-url origin 2>/dev/null) || die 6 "$project has no origin"
got=$(printf '%s' "$url" | sed -n 's#^\(https://github\.com/\|git@github\.com:\|ssh://git@github\.com/\)\([^/]*/[^/]*\)$#\2#p' | sed 's#\.git$##' | tr 'A-Z' 'a-z')
[ "$got" = "$repo" ] || die 6 "origin of $project is ${got:-not a GitHub URL}, not $repo"

[ -n "$T" ] || T=$(date -u +%m%d%H%M)
case "$T" in *[!a-z0-9]*|"") die 2 "--task-id may hold only a-z and 0-9" ;; esac
ID=p330w-$T; W=w-$ID; WAIT=${PADDOCK_PROBE_WAIT:-240}
[ "${#ID}" -le 30 ] || die 2 "--task-id too long"
OK=$ID-ok PROT=$ID-prot
RUN=${XDG_STATE_HOME:-$HOME/.local/state}/paddock-p330w/$T
[ ! -e "$RUN" ] || die 6 "$RUN exists; use another --task-id"
mkdir -p "$RUN" || die 6 "cannot make $RUN"
WT=${PADDOCK_WORKERS_DIR:-$HOME/paddock-workers}/$ID
KEEP= PUSHED=
fail=0
res() { echo "RESULT $1: $2${3:+ ($3)}"; case "$2" in FAIL|"NO DATA") fail=1 ;; esac; }

. "$(dirname "$0")/claude-link.sh"
claude_link_save
cleanup() {
  claude_link_restore
  for b in $PUSHED; do git -C "$RUN/c" push origin --delete "$b" >/dev/null 2>&1; done
  [ -n "$KEEP" ] && { echo "terminal $W and worktree $WT kept; run folder: $RUN"; return; }
  hc kill "$W" >/dev/null 2>&1; hc rm "$W" >/dev/null 2>&1
  git -C "$project" worktree remove -f "$WT" >/dev/null 2>&1
  git -C "$project" branch -D "work/$ID" >/dev/null 2>&1
  echo "cleanup: terminal, worktree, branch work/$ID and remote branches $OK $PROT removed; run folder kept: $RUN"
}
[ ! -e "$WT" ] && ! hc get "$W" >/dev/null 2>&1 && ! git -C "$project" rev-parse -q --verify "refs/heads/work/$ID" >/dev/null || die 6 "$W, $WT or branch work/$ID already exists (leftover of an earlier run)"
trap cleanup EXIT; trap 'exit 130' INT TERM
dialog() { case "$(hc read "$W" 2>/dev/null)" in *"Quick safety check"*|*"trust this folder"*) return 0 ;; esac; return 1; }
needs_person() { echo "NEEDS-PERSON: folder-trust dialog in $W; answer it (or trust the project) and rerun"; KEEP=1; exit 1; }
org() { bash "$ROOT/scripts/org" --as secretary "$@"; }

# Two side branches from main: one plain file, one protected path. Never main itself.
git clone -q "$url" "$RUN/c" || die 6 "cannot clone $url"
git -C "$RUN/c" switch -q main 2>/dev/null || die 6 "no main in $repo"
for b in $OK $PROT; do
  git -C "$RUN/c" switch -q -c "$b" origin/main || die 6 "cannot branch $b"
  if [ "$b" = "$OK" ]; then echo "p330w $T" > "$RUN/c/$ID-ok.txt"; f=$ID-ok.txt
  else mkdir -p "$RUN/c/.claude/skills/$ID"; echo "p330w $T" > "$RUN/c/.claude/skills/$ID/NOTE.md"; f=.claude/skills/$ID/NOTE.md; fi
  git -C "$RUN/c" add "$f" && git -C "$RUN/c" commit -q -m "p330w probe: $b" || die 6 "cannot commit $b"
  git -C "$RUN/c" push -q origin "$b" || die 6 "cannot push $b to $repo"
  PUSHED="$PUSHED $b"
  git -C "$RUN/c" switch -q main
done

# The worker's commands, one Bash call. \$ stays for the worker's shell; $OUB, $OK etc. are filled in here.
TASK="Probe for paddock Issue #330. Change nothing else. Run this block in ONE Bash call exactly as written, then stop:
OUB='$OUB'
FE=\$(git fetch origin 2>&1 | tr '\\n\"\\\\' '   ' | cut -c1-160)
H0=\$(git rev-parse HEAD)
bash \"\$OUB\" --worktree \"\$PWD\" --base $OK >/dev/null 2>&1; A=\$?
H1=\$(git rev-parse HEAD)
git merge-base --is-ancestor origin/$OK HEAD && AH=yes || AH=no
[ \"\$H0\" = \"\$H1\" ] && AM=no || AM=yes
E=\$(bash \"\$OUB\" --worktree \"\$PWD\" --base $PROT 2>&1 >/dev/null); B=\$?
H2=\$(git rev-parse HEAD)
[ \"\$H1\" = \"\$H2\" ] && BM=no || BM=yes
case \"\$E\" in *'protected: .claude/skills/'*) BL=yes ;; *) BL=no ;; esac
bash \"\$PADDOCK_ORG\" --as $W report done --task $ID \"probe done env=\${PADDOCK_ORG:+set} ok-rc=\$A ok-moved=\$AM ok-has-base=\$AH prot-rc=\$B prot-moved=\$BM prot-listed=\$BL fetch-err=[\$FE]\""
out=$(bash "$DELEGATE" --project "$project" --task-id "$ID" --task "$TASK" 2>&1); rc=$?
echo "$out" > "$RUN/delegate.out"
if [ "$rc" -eq 0 ]; then res delegate PASS
else res delegate FAIL "exit $rc; see $RUN/delegate.out"; [ "$rc" -eq 10 ] && dialog && needs_person; exit 1; fi

t=0; tab=$(printf '\t')
while [ "$t" -lt "$WAIT" ]; do
  org list_runs 2>/dev/null | grep -q "^$ID$tab$W${tab}done$tab" && break
  dialog && needs_person
  t=$((t + 3)); sleep 3
done
if [ "$t" -lt "$WAIT" ]; then res report-done PASS "${t}s"
else res report-done FAIL "no done record from $W in ${WAIT}s"; echo "== screen tail"; hc read "$W" 2>&1 | tail -n 30; fi

STATE=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}
box=$(cat "$STATE"/events/*/"$W".jsonl 2>/dev/null | grep '"kind":"run_completed","to":"secretary"' | grep "\"task_id\":\"$ID\"" | grep 'probe done' | tail -n 1)
if [ -n "$box" ]; then res in-box PASS; else res in-box FAIL; fi
echo "done text: $(printf '%s' "$box" | sed -n 's/.*\(probe done[^"]*\).*/\1/p')"
printf '%s\n' "$box" > "$RUN/done.json"
fe=$(printf '%s' "$box" | sed -n 's/.*fetch-err=\[\([^]]*\)\].*/\1/p'); echo "worker plain git fetch origin output: ${fe:-<empty: fetch printed nothing>}"
f() { printf '%s' "$box" | sed -n "s/.*[ \"]$1=\([a-z0-9]*\).*/\1/p" | tail -n 1; } # f <field>: value in the done text
env=$(f env); okrc=$(f ok-rc); okm=$(f ok-moved); okh=$(f ok-has-base); prc=$(f prot-rc); pm=$(f prot-moved); pl=$(f prot-listed)

if [ -z "$env" ] && [ -z "$okrc" ]; then res worker-env "NO DATA" "no fields in the done text"
elif [ "$env" = set ]; then res worker-env PASS "PADDOCK_ORG set in the worker"
else res worker-env FAIL "env=${env:-empty}"; fi
if [ -z "$okrc" ]; then res worker-merge "NO DATA"
elif [ "$okrc" = 0 ] && [ "$okm" = yes ] && [ "$okh" = yes ]; then res worker-merge PASS "exit 0, HEAD moved, origin/$OK in the branch"
else res worker-merge FAIL "exit $okrc, moved=$okm, has-base=$okh (5: no origin/<base> visible to the worker; 6: merge failed)"; fi
if [ -z "$prc" ]; then res worker-protected-stop "NO DATA"
elif [ "$prc" = 4 ] && [ "$pm" = no ] && [ "$pl" = yes ]; then res worker-protected-stop PASS "exit 4, path named, HEAD unchanged"
else res worker-protected-stop FAIL "exit $prc, moved=$pm, listed=$pl (expected 4, no, yes)"; fi

# Control, on the host: the secretary's case (no PADDOCK_ORG) merges the same protected range.
if [ -n "$okrc" ] && [ -d "$WT" ]; then
  hc kill "$W" >/dev/null 2>&1 # the worker is done; nothing else writes the worktree now
  env -u PADDOCK_ORG bash "$OUB" --worktree "$WT" --base "$PROT" >"$RUN/host-control.out" 2>&1; rc=$?
  if [ "$rc" -eq 0 ] && git -C "$WT" merge-base --is-ancestor "origin/$PROT" HEAD; then res host-control PASS "exit 0, origin/$PROT merged without the check"
  else res host-control FAIL "exit $rc; see $RUN/host-control.out"; fi
else res host-control "NO DATA" "no worker result or no worktree"; fi

echo "run folder: $RUN"
exit $fail
