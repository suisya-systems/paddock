#!/bin/sh
# Probe for decision 0010 (Issue #359), step 1: does trusting a PARENT folder (stand-in for
# ~/paddock-local) cover a git repository made inside it LATER, and a worktree of that
# repository placed OUTSIDE the parent (where org-delegate puts workers)?
#
# Run from the repo root, on a host where hc and claude run (logged in), in a plain login shell,
# with NO arguments:
#   sh scripts/probes/folder-trust-local-parent.sh
# Takes about 4 minutes (each launch waits WAIT s, default 60). Needs hc, claude, git, sh.
# Safety: own hc core (HC_SESSION=p359-<pid>, private XDG_CONFIG_HOME); saves/restores the
# ~/.local/bin/claude link; folders live under $HOME/p359-<time> (a stand-in, NOT your real
# ~/paddock-local) and are removed at exit. The ONLY keys sent are `down enter` to the trust
# dialog of the PARENT in step 1 (same as folder-trust-worktrees.sh). Claude Code itself records
# the accepted parent in ~/.claude.json; the script never writes that file (it only prints
# trust entries). Those entries stay after cleanup; they name only p359-* paths.
#
# Steps / cases:
#   STEP 1 parent      launch in the (non-git) parent, accept the dialog. Needed to trust it.
#   control            a folder outside the parent. Expect DIALOG (the probe can see the dialog).
#   repo-in-parent     a repository made inside the parent AFTER step 1 (git init + empty commit),
#                      launched in the repository itself.
#   wt-outside         a different new repository inside the parent, launched in its worktree
#                      placed outside the parent (the real org-delegate shape).
# Reading: "RESULT <case>: DIALOG" = Quick safety check on screen; "NO-DIALOG" = none;
# "UNKNOWN" = empty screen.
#   repo-in-parent NO-DIALOG and wt-outside NO-DIALOG = trusting the parent once is enough
#     (decision 0010 point 3: person trusts the folder once per machine).
#   either DIALOG = it is not enough (the secretary answers once per repository).
# If STEP 1 prints "RESULT parent-accept: FAIL" the later cases mean nothing. Paste the whole output.
set -u

case "${1:-}" in
  "") ;;
  -h|--help) sed -n "2,29p" "$0"; exit 0 ;;
  *) echo "folder-trust-local-parent: unknown argument: $1" >&2; exit 2 ;;
esac

ROOT=$(pwd)
[ -f "$ROOT/templates/worker.md" ] || { echo "RESULT precondition-failed: run from the repo root"; exit 1; }
for c in hc claude git; do command -v $c >/dev/null 2>&1 || { echo "RESULT precondition-failed: $c not on PATH"; exit 1; }; done

WAIT=${WAIT:-60}
BASE="$HOME/p359-$(date +%Y%m%d-%H%M%S)"
PARENT="$BASE/local"; OUT="$BASE/outside"
XDG="$BASE/xdg"; TPL_DIR="$XDG/herdr-core/templates"
mkdir -p "$PARENT" "$OUT" "$TPL_DIR" || exit 1
HC_SESSION=p359-$$; export HC_SESSION
XDG_CONFIG_HOME=$XDG; export XDG_CONFIG_HOME

. "$(dirname "$0")/claude-link.sh"
claude_link_save
cleanup() {
  claude_link_restore
  for n in parent control repo wt; do hc kill "p359-$n" >/dev/null 2>&1; hc rm "p359-$n" >/dev/null 2>&1; done
  hc server stop >/dev/null 2>&1 # HC_SESSION is the temp core's: yours is untouched
  case "$BASE" in "$HOME"/p359-*) rm -rf "$BASE" ;; esac
  echo "CLEANUP done"
}
trap cleanup EXIT; trap 'exit 130' INT TERM

printf '%s\n' '---' 'description: p359 folder-trust probe' 'command: claude --permission-mode default' '---' \
  'This is a probe. Reply with the single word OK and nothing else.' > "$TPL_DIR/p359-trust.md"

DIALOG_RE='Quick safety check|Accessing workspace|trust this folder'

launch() { # launch <name> <folder>: start, wait, print the screen; sets SCREEN
  hc run --bg --name "p359-$1" --cwd "$2" p359-trust "Say OK." 2>&1 | head -n 4
  sleep "$WAIT"
  SCREEN=$(hc read "p359-$1" 2>&1)
  echo "-- hc read p359-$1 (last 20 lines)"; printf '%s\n' "$SCREEN" | tail -n 20
  echo "-- first_message: $(hc get --json "p359-$1" 2>/dev/null | tr -d '\n' | grep -Eo '"first_message": *\{[^{}]*\}')"
}
verdict() { # verdict <case>: from $SCREEN
  if printf '%s\n' "$SCREEN" | grep -Eq "$DIALOG_RE"; then v=DIALOG
  elif [ -n "$SCREEN" ]; then v=NO-DIALOG; else v=UNKNOWN; fi
  echo "RESULT $1: $v"
}
stop() { hc kill "p359-$1" >/dev/null 2>&1; hc rm "p359-$1" >/dev/null 2>&1; }

echo "== versions"; hc --version 2>&1; claude --version 2>&1
echo "== STEP 1: trust the parent $PARENT"
launch parent "$PARENT"
if printf '%s\n' "$SCREEN" | grep -Eq "$DIALOG_RE"; then
  hc keys p359-parent down enter; sleep 20
  echo "-- hc read p359-parent (after keys, last 12 lines)"; hc read p359-parent 2>&1 | tail -n 12
  if hc read p359-parent 2>&1 | grep -Eq "$DIALOG_RE"; then echo "RESULT parent-accept: FAIL (dialog still on screen)"; exit 1; fi
  echo "RESULT parent-accept: ok (dialog answered once)"
else
  echo "RESULT parent-accept: FAIL (no dialog on a new folder; cannot tell what was trusted)"; exit 1
fi
stop parent

echo "== control: $OUT/untrusted"
mkdir -p "$OUT/untrusted"; launch control "$OUT/untrusted"; verdict control; stop control

echo "== repo-in-parent: repository made inside the parent after it was trusted"
git init -q "$PARENT/r1" && git -C "$PARENT/r1" -c user.name=probe -c user.email=probe@example.invalid commit -q --allow-empty -m probe \
  || { echo "RESULT precondition-failed: could not make r1"; exit 1; }
launch repo "$PARENT/r1"; verdict repo-in-parent; stop repo

echo "== wt-outside: worktree of a second new repository, placed outside the parent"
git init -q "$PARENT/r2" && git -C "$PARENT/r2" -c user.name=probe -c user.email=probe@example.invalid commit -q --allow-empty -m probe \
  && git -C "$PARENT/r2" worktree add -q -b wt "$OUT/wt" \
  || { echo "RESULT precondition-failed: could not make r2 and its worktree"; exit 1; }
launch wt "$OUT/wt"; verdict wt-outside; stop wt
