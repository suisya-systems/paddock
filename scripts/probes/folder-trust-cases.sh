#!/bin/sh
# Probe for Issue #216, step 1 (Q13; G2): what does Claude Code key folder trust on, and does
# trusting the workers folder cover a NEW worktree below it? Q13 (Issue #46) measured a plain
# sub-folder; on 2026-11-11 a worker in a new worktree under the trusted ~/paddock-workers still
# stopped at the dialog. This probe launches Claude Code in several kinds of folder and only
# LOOKS at the screen.
#
# Run from the repo root, on a host where hc and claude run (logged in), in a plain login shell,
# with NO arguments, after a person has accepted the trust dialog once for ~/paddock-workers
# (case-plain below is the control and says so if it did not hold):
#   sh scripts/probes/folder-trust-cases.sh
# Takes about 5 minutes (each launch may wait about 60 s). Needs hc, claude, git, sh.
# Environment (optional): PADDOCK_WORKERS_DIR (default $HOME/paddock-workers, must exist),
# PADDOCK_TRUSTED_REPO (default this checkout; the git repository for case-trusted-repo).
#
# Safety. It starts its OWN hc core (HC_SESSION=p216-<pid>, XDG_CONFIG_HOME under a private temp
# folder); it never touches XDG_DATA_HOME; it saves and restores the ~/.local/bin/claude link
# (claude-link.sh). It NEVER answers a trust dialog (no keys are sent) and NEVER writes
# ~/.claude.json (your config): it only reads trust entries from it for printing. Each launch is
# read once and the terminal is killed. Cleanup removes the terminals, the temp core, the folders
# and worktrees it made, and the worktree it added to the trusted repository.
#
# Cases (each prints the observed screen, the launch's first_message and a verdict line):
#   case-untrusted     control: a folder in the temp area, trusted by nothing. Expect DIALOG
#                      (shows that the probe can see the dialog).
#   case-plain         a plain sub-folder of the workers folder. Expect NO-DIALOG (Q13's result).
#                      If DIALOG, the workers folder is not trusted: run it by hand once, rerun.
#   case-worktree      a git worktree (git worktree add) created under the workers folder, of a
#                      repository that is NOT under it and not trusted.
#   case-clone         a git repository (git clone) created under the workers folder.
#   case-trusted-repo  a git worktree of a repository that is itself trusted, created OUTSIDE the
#                      workers folder (so only the repository's trust can cover it).
# Reading the verdicts: "RESULT <case>: DIALOG" = the dialog (Quick safety check / Accessing
# workspace) is on the screen and first_message.sent is false; "NO-DIALOG" = no dialog and
# first_message.sent true; "UNKNOWN" = neither (read the screen). Paste the whole output back.
set -u

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
  *) echo "folder-trust-cases: unknown argument: $1" >&2; exit 2 ;;
esac

ROOT=$(pwd)
[ -f "$ROOT/templates/worker.md" ] || { echo "RESULT precondition-failed: run from the repo root"; exit 1; }
for c in hc claude git mktemp; do command -v $c >/dev/null 2>&1 || { echo "RESULT precondition-failed: $c not on PATH"; exit 1; }; done
WORKERS=${PADDOCK_WORKERS_DIR:-$HOME/paddock-workers}
[ -d "$WORKERS" ] || { echo "RESULT precondition-failed: $WORKERS does not exist"; exit 1; }
TRUSTED_REPO=${PADDOCK_TRUSTED_REPO:-$ROOT}
git -C "$TRUSTED_REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "RESULT precondition-failed: $TRUSTED_REPO is not a git repository"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/probe216.XXXXXX") || exit 1 # private (0700)
XDG="$WORK/xdg"; TPL_DIR="$XDG/herdr-core/templates"; MAIN="$WORK/main-repo"
BASE="$WORKERS/p216-$$-$(date +%s)"; WT4="$WORK/wt-of-trusted"
mkdir -p "$TPL_DIR" "$BASE" || exit 1
HC_SESSION=p216-$$; export HC_SESSION
XDG_CONFIG_HOME=$XDG; export XDG_CONFIG_HOME

. "$(dirname "$0")/claude-link.sh"
claude_link_save
cleanup() {
  claude_link_restore
  for n in untrusted plain worktree clone trusted-repo; do hc kill "p216-$n" >/dev/null 2>&1; hc rm "p216-$n" >/dev/null 2>&1; done
  hc server stop >/dev/null 2>&1 # HC_SESSION is the temp core's: yours is untouched
  git -C "$TRUSTED_REPO" worktree remove --force "$WT4" >/dev/null 2>&1
  case "$BASE" in "$WORKERS"/p216-*) rm -rf "$BASE" ;; esac
  rm -rf "$WORK"
  echo "CLEANUP done"
}
trap cleanup EXIT; trap 'exit 130' INT TERM

printf '%s\n' '---' 'description: p216 folder-trust probe' 'command: claude --permission-mode default' '---' \
  'This is a probe. Reply with the single word OK and nothing else.' > "$TPL_DIR/p216-trust.md"

trust_entries() { # INFO only (grep only: a flag may be misread for long entries; the verdicts do not use it). Read-only: the trust flag of every ~/.claude.json project key that names the workers folder or this probe
  tr -d '\n' < "$HOME/.claude.json" 2>/dev/null | grep -Eo '"[^"]*(paddock-workers|p216-|probe216)[^"]*": *\{' | sed 's/": *{$//; s/^"//' | while IFS= read -r k; do
    f=$(tr -d '\n' < "$HOME/.claude.json" | grep -Eo "\"$k\": *\{.{0,600}" | grep -Eo 'hasTrustDialogAccepted": *(true|false)' | head -n 1)
    echo "   $k -> ${f:-no hasTrustDialogAccepted}"
  done
}

run_case() { # run_case <name> <folder>: launch, read once, never answer, kill
  n=$1; dir=$2; t=p216-$n
  echo "== case-$n: $dir"
  out=$(hc run --bg --name "$t" --cwd "$dir" p216-trust "Say OK." 2>&1); echo "-- hc run: $out" | head -n 8
  sleep 3
  screen=$(hc read "$t" 2>&1)
  fm=$(hc get --json "$t" 2>/dev/null | tr -d '\n' | grep -Eo '"first_message": *\{[^{}]*\}')
  echo "-- hc read $t (last 20 lines)"; printf '%s\n' "$screen" | tail -n 20
  echo "-- first_message: ${fm:-not found}"
  if printf '%s\n' "$screen" | grep -Eq 'Quick safety check|Accessing workspace|trust this folder'; then v=DIALOG
  elif printf '%s\n' "$fm" | grep -Eq '"sent": *true'; then v=NO-DIALOG
  else v=UNKNOWN; fi
  echo "RESULT case-$n: $v"
  hc kill "$t" >/dev/null 2>&1; hc rm "$t" >/dev/null 2>&1
}

echo "== versions"; hc --version 2>&1; claude --version 2>&1
echo "== temp core session $HC_SESSION; workers folder $WORKERS; folders under $BASE"
echo "== ~/.claude.json trust entries before (read only)"; trust_entries

git init -q "$MAIN" && git -C "$MAIN" -c user.name=probe -c user.email=probe@example.invalid commit -q --allow-empty -m probe \
  || { echo "RESULT precondition-failed: could not make the probe repository"; exit 1; }
mkdir -p "$WORK/untrusted" "$BASE/plain-sub" || exit 1
(cd "$MAIN" && git worktree add -q --detach "$BASE/wt") \
  && git clone -q "$MAIN" "$BASE/clone" \
  && git -C "$TRUSTED_REPO" worktree add -q --detach "$WT4" \
  || { echo "RESULT precondition-failed: could not make the case folders"; exit 1; }

run_case untrusted "$WORK/untrusted"
run_case plain "$BASE/plain-sub"
run_case worktree "$BASE/wt"
run_case clone "$BASE/clone"
run_case trusted-repo "$WT4"

echo "== ~/.claude.json trust entries after (read only; new entries show what Claude Code recorded for each folder)"; trust_entries
