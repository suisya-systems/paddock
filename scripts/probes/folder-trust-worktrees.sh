#!/bin/sh
# Probe for Q13 (Issue #46): does accepting Claude Code's folder-trust dialog
# in a parent folder cover a new subfolder below it?
#
# Run from the repo root, on a host where herdr core (hc) runs and Claude Code
# is logged in:
#   sh scripts/probes/folder-trust-worktrees.sh
# Takes about 3 to 4 minutes (each launch waits up to WAIT seconds, default 75,
# for the dialog; hc run itself may return after ~58 s). Needs: hc and claude
# on PATH; POSIX sh only. Creates folders under $HOME (NOT /tmp), a temporary
# template, and terminals p46-parent and p46-child. Cleanup removes the
# terminals and the template; the folders are left for inspection.
#
# Reading the output:
#   STEP 1 (parent): `hc read` shows whether "Quick safety check" appeared.
#     If yes, the script presses `down enter` and prints `hc get --json`;
#     expect first_message.sent true afterwards.
#   STEP 2 (child, a new subfolder of the parent, launched after the parent
#     terminal is killed): `hc read` + `hc get --json`.
#     RESULT: first_message.sent true and no dialog in `hc read`
#       = parent trust covers the child (Q13 option b is available).
#     first_message.sent false and "Quick safety check" on screen
#       = trust does not carry down.
#   Paste the whole output back. Note the WAIT value if you change it.

WAIT=${WAIT:-75}
TPL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-core/templates"
TPL="$TPL_DIR/p46-trust.md"
BASE="$HOME/p46-trust-$(date +%Y%m%d-%H%M%S)"
PARENT="$BASE/parent"
CHILD="$PARENT/child-wt"

if [ -e "$TPL" ]; then echo "precondition-failed: $TPL exists; remove it first"; exit 1; fi
for n in p46-parent p46-child; do
  if hc ls 2>&1 | grep -Eq "(^|[^A-Za-z0-9_-])$n([^A-Za-z0-9_-]|\$)"; then
    echo "precondition-failed: terminal $n already exists"; exit 1
  fi
done

cleanup() {
  for n in p46-child p46-parent; do hc kill "$n" >/dev/null 2>&1; hc rm "$n" >/dev/null 2>&1; done
  rm -f "$TPL"
  echo "CLEANUP done. Folders kept: $PARENT and $CHILD"
}
trap cleanup EXIT INT TERM

mkdir -p "$PARENT" "$TPL_DIR" || exit 1
printf '%s\n' '---' 'description: p46 folder-trust probe' 'command: claude --permission-mode default' '---' \
  'This is a probe. Reply with the single word OK and nothing else.' > "$TPL"

echo "== STEP 1: parent folder $PARENT"
hc run --bg --name p46-parent --cwd "$PARENT" p46-trust "Say OK."
sleep "$WAIT"
echo "-- hc read p46-parent (before keys)"
hc read p46-parent
if hc read p46-parent 2>&1 | grep -q "Quick safety check"; then
  echo "-- DIALOG SEEN in parent; accepting with: hc keys p46-parent down enter"
  hc keys p46-parent down enter
  sleep 20
  echo "-- hc read p46-parent (after keys)"
  hc read p46-parent
else
  echo "-- NO DIALOG text in parent"
fi
echo "-- hc get --json p46-parent"
hc get --json p46-parent

echo "== STEP 2: child folder $CHILD (parent terminal killed first)"
hc kill p46-parent >/dev/null 2>&1; hc rm p46-parent >/dev/null 2>&1
mkdir -p "$CHILD" || exit 1
hc run --bg --name p46-child --cwd "$CHILD" p46-trust "Say OK."
sleep "$WAIT"
echo "-- hc read p46-child"
hc read p46-child
echo "-- hc get --json p46-child"
hc get --json p46-child
