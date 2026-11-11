#!/bin/sh
# Probe for Issue #49 (HK-18): which Claude Code hook events fire in a
# template launch? Controls: SessionStart, PreToolUse, Stop (seen before).
# Under test: UserPromptSubmit, PostToolUse, PreCompact, Notification.
#
# Run from the repo root, on a host where herdr core (hc) and claude run:
#   sh scripts/probes/hk18-hook-events/run.sh
# Takes about 2-3 minutes up to the manual step; the manual step is yours.
# Needs: hc and claude on PATH, a logged-in claude, POSIX sh. Starts one
# terminal named hk18 and one temporary template (hk18-probe); both are
# removed by the cleanup trap (and by the manual step at the end).
#
# Markers: one line per hook call, "<Event> <epoch-seconds> <stdin JSON>",
# in $MARKERS. Expected after PHASE 1 (the Bash task):
#   SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop
# Expected after PHASE 2 (the manual /compact):
#   PreCompact (and a second SessionStart if compact re-fires it).
# Notification appears only if Claude Code raises one (permission prompt or
# idle); the task is pre-allowed, so absence after PHASE 1 is not a failure
# by itself. Record exactly what appears; a missing event is the finding.

NAME=hk18
SELF=$(cd "$(dirname "$0")" && pwd)
TPL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-core/templates"
TPL="$TPL_DIR/hk18-probe.md"

has() { hc ls 2>&1 | grep -Eq "(^|[^A-Za-z0-9_-])$1([^A-Za-z0-9_-]|\$)"; }

if [ -e "$TPL" ]; then echo "RESULT precondition-failed: $TPL exists; remove it first"; exit 1; fi
if has $NAME; then echo "RESULT precondition-failed: terminal $NAME already exists"; exit 1; fi

WORK=$(mktemp -d) || exit 1
MARKERS="$WORK/markers.txt"
mkdir -p "$WORK/cwd" || exit 1
: > "$MARKERS"
. "$(dirname "$0")/../claude-link.sh"
claude_link_save
cleanup() {
  claude_link_restore
  hc kill $NAME >/dev/null 2>&1; hc rm $NAME >/dev/null 2>&1
  rm -f "$TPL"
}
trap cleanup EXIT INT TERM
mkdir -p "$TPL_DIR" || exit 1

# Same launch shape as templates/secretary.md (command: claude), plus the
# settings file and the marker path. --permission-mode default: a project
# file cannot set it (inventory PRM-2).
cat > "$TPL" <<T
---
description: probe 49 hook events (temporary)
command: HK18_MARKERS="$MARKERS" claude --permission-mode default --settings "$SELF/settings.json"
---
Probe 49. Ignore.
T

echo "== markers file: $MARKERS"
echo "== start"
hc run --bg --name $NAME --cwd "$WORK/cwd" hk18-probe || { echo "RESULT precondition-failed: hc run failed"; exit 1; }

echo "== wait for the prompt (up to 90 s); answer the folder-trust dialog if shown"
i=0
while [ $i -lt 90 ]; do
  screen=$(hc read $NAME 2>&1)
  case "$screen" in
    *"Quick safety check"*) echo "-- trust dialog: accepting"; hc keys $NAME down enter; sleep 3 ;;
  esac
  if grep -q '^SessionStart ' "$MARKERS"; then
    case "$screen" in *"Quick safety check"*) ;; *) sleep 3; break ;; esac
  fi
  i=$((i + 1)); sleep 1
done
echo "-- SessionStart seen: $(grep -c '^SessionStart ' "$MARKERS")"

echo "== PHASE 1: send one task"
hc send $NAME "Run exactly this one Bash command and nothing else: echo hk18" || echo "hc send exit: $?"

echo "== wait for PostToolUse and the second Stop (up to 90 s)"
i=0
while [ $i -lt 90 ]; do
  if grep -q '^PostToolUse ' "$MARKERS" && [ "$(grep -c '^Stop ' "$MARKERS")" -ge 2 ]; then break; fi
  i=$((i + 1)); sleep 1
done
sleep 3
echo "== MARKERS after PHASE 1"; cat "$MARKERS"
echo "-- counts:"
for e in SessionStart UserPromptSubmit PreToolUse PostToolUse PreCompact Notification Stop; do
  echo "   $e: $(grep -c "^$e " "$MARKERS")"
done
echo "-- screen:"; hc read $NAME 2>&1 | tail -20

cat <<M

== MANUAL STEP (PHASE 2) ===========================================
The terminal $NAME is still running. In another shell, type /compact:
    hc send $NAME /compact
(or hc attach $NAME and type /compact + Enter). Wait until it finishes
(about 10-60 s), then press Enter here to print the markers again.
=====================================================================
M
read dummy
echo "== MARKERS after PHASE 2"; cat "$MARKERS"
echo "-- counts:"
for e in SessionStart UserPromptSubmit PreToolUse PostToolUse PreCompact Notification Stop; do
  echo "   $e: $(grep -c "^$e " "$MARKERS")"
done
echo "== cleanup runs now (hc kill $NAME, hc rm $NAME, template removed)"
