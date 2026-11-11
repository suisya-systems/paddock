#!/bin/sh
# Probe for Issue #244: does org-start get a new secretary past Claude Code's folder-trust dialog by
# itself (read the screen, down, read again, enter only with the cursor on "Yes, I trust this
# folder") and then deliver the first message (template body + launch task) the dialog kept back?
#
# Run from the repo root of the branch under test, on a host where hc and claude run (logged in),
# in a plain login shell with NO agent above it and NO arguments:
#   sh scripts/probes/org-start-trust.sh
# Takes about 1-3 minutes. Needs hc, claude, git, bash, sh, mktemp.
#
# What it does. It clones this checkout (its HEAD) into a fresh folder in a private temp area: a
# git folder no one has trusted, which is where the dialog appears (Q13, measured 2026-11-11). It
# starts its OWN core (HC_SESSION=p244-<pid>, XDG_CONFIG_HOME, PADDOCK_STATE_DIR and the org config
# under the temp area), sets conversation_language to "probe244" in that temp config, and runs the
# clone's org-start with every folder overridden and the terminal named p244-secretary. This probe
# presses NO keys itself: answering the dialog is org-start's job here. It NEVER writes
# ~/.claude.json; it only reads the clone's trust entry for printing (Claude Code itself records the
# answer there; that entry, for a folder that is removed afterwards, is left in your file). It saves
# and restores the ~/.local/bin/claude link (claude-link.sh). Cleanup kills and removes the
# terminal, stops ONLY the temp core and deletes the temp area.
#
# Verdicts ("RESULT <name>:"):
#   dialog-seen      YES = org-start printed that it accepted the dialog. NO = it did not (then
#                    the clone was not asked; the rest says nothing about #244: report it).
#   org-start-exit   PASS = 0. FAIL = other code (printed).
#   hc-get-status    PASS = the secretary reports a status object.
#   task-delivered   PASS = the secretary's screen shows "Conversation language: probe244" (the
#                    end of the resent first message: template body + launch task). PASTED = the
#                    screen shows "[Pasted text" instead (Claude Code folds a long paste); read the
#                    screen tail. FAIL = neither (screen tail printed). NO DATA = empty screen.
#   dialog-gone      PASS = no dialog text on the final screen.
# Paste the whole output back.
set -u

case "${1:-}" in
  "") ;;
  -h|--help) sed -n "2,32p" "$0"; exit 0 ;;
  *) echo "org-start-trust: unknown argument: $1" >&2; exit 2 ;;
esac

NAME=p244-secretary
LANGV=probe244
ROOT=$(pwd)
[ -f "$ROOT/skills/org-start/scripts/org-start.sh" ] || { echo "RESULT precondition-failed: run from the repo root"; exit 1; }
for c in hc claude git bash mktemp; do command -v $c >/dev/null 2>&1 || { echo "RESULT precondition-failed: $c not on PATH"; exit 1; }; done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/probe244.XXXXXX") || exit 1 # private (0700)
CLONE="$WORK/paddock-clone"; XDG="$WORK/xdg"
git clone -q "$ROOT" "$CLONE" || { echo "RESULT precondition-failed: could not clone $ROOT"; exit 1; }
HC_SESSION=p244-$$; export HC_SESSION
XDG_CONFIG_HOME=$XDG; export XDG_CONFIG_HOME
PADDOCK_STATE_DIR=$WORK/state; export PADDOCK_STATE_DIR
PADDOCK_ORG_CONFIG_FILE=$WORK/cfg/org-config.md; export PADDOCK_ORG_CONFIG_FILE
PADDOCK_PROJECTS_FILE=$WORK/cfg/projects.md; export PADDOCK_PROJECTS_FILE
PADDOCK_BIN_DIR=$WORK/bin; export PADDOCK_BIN_DIR # before the first hc call: the temp core inherits it

. "$(dirname "$0")/claude-link.sh"
claude_link_save
cleanup() {
  claude_link_restore
  hc kill "$NAME" >/dev/null 2>&1; hc rm "$NAME" >/dev/null 2>&1
  hc server stop >/dev/null 2>&1 # HC_SESSION is the temp core's: yours is untouched
  rm -rf "$WORK"
  echo "CLEANUP done"
}
trap cleanup EXIT; trap 'exit 130' INT TERM

echo "== versions"; hc --version 2>&1; claude --version 2>&1; echo "branch HEAD $(git -C "$ROOT" rev-parse --short HEAD)"
echo "== temp core session $HC_SESSION; terminal $NAME; secretary root $CLONE"
bash "$CLONE/scripts/org" --as secretary config set conversation_language "$LANGV" >/dev/null \
  || { echo "RESULT precondition-failed: could not set conversation_language in the temp config"; exit 1; }

echo "== org-start (PADDOCK_READY_TRIES=90)"
OUT=$(PADDOCK_CORE_TEMPLATES_DIR="$XDG/herdr-core/templates" PADDOCK_APP_MODS_DIR="$WORK/mods" \
  PADDOCK_APP_LAYOUTS_DIR="$WORK/layouts" PADDOCK_SECRETARY_NAME=$NAME PADDOCK_READY_TRIES=90 \
  bash "$CLONE/skills/org-start/scripts/org-start.sh" 2>&1); RC=$?
printf '%s\n' "$OUT"

echo "== results"
if printf '%s\n' "$OUT" | grep -q 'accepted the folder-trust dialog'; then echo "RESULT dialog-seen: YES"; else echo "RESULT dialog-seen: NO"; fi
if [ "$RC" = 0 ]; then echo "RESULT org-start-exit: PASS (0)"; else echo "RESULT org-start-exit: FAIL ($RC)"; fi
if hc get --json "$NAME" 2>/dev/null | grep -Eq '"status": *\{'; then echo "RESULT hc-get-status: PASS"; else echo "RESULT hc-get-status: FAIL"; fi
sleep 5
SCREEN=$(hc read "$NAME" 2>&1)
if [ -z "$SCREEN" ]; then echo "RESULT task-delivered: NO DATA (empty screen)"
elif printf '%s\n' "$SCREEN" | grep -q "Conversation language: $LANGV"; then echo "RESULT task-delivered: PASS"
elif printf '%s\n' "$SCREEN" | grep -q '\[Pasted text'; then echo "RESULT task-delivered: PASTED (read the screen tail)"
else echo "RESULT task-delivered: FAIL"; fi
if printf '%s\n' "$SCREEN" | grep -Eq 'Quick safety check|trust this folder'; then echo "RESULT dialog-gone: FAIL"; else echo "RESULT dialog-gone: PASS"; fi
echo "== ~/.claude.json entry for the clone (read only)"
tr -d '\n' < "$HOME/.claude.json" 2>/dev/null | grep -Eo "\"$CLONE\": *\{.{0,600}" | grep -Eo 'hasTrustDialogAccepted": *(true|false)' | head -n 1 | sed 's/^/   /'
echo "== screen tail"
printf '%s\n' "$SCREEN" | tail -n 15
echo "== done; paste everything above back"
