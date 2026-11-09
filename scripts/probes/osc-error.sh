#!/bin/sh
# Probe for MON-6 (Issue #54): does Claude Code report OSC 7501 `error`?
# Launches `claude --model no-such-model` from a temporary template with a task,
# then polls `hc get --json` every 2 s for up to 90 s, printing the `status`
# object whenever it changes, and prints `hc read` at the end.
#
# Run from the repo root, on a host where herdr core (hc) runs:
#   sh scripts/probes/osc-error.sh
# Takes up to about 2 minutes (90 s of polling plus startup). Needs hc on PATH
# and a core that can start; POSIX sh only. No person's action is needed: if the
# folder-trust dialog appears, the script accepts it with `hc keys`.
# Creates one template and one terminal, both named p54-*, and removes both
# on exit.
#
# Reading the output:
#   "STATUS ..." lines are each change of the `status` object (with seconds
#   since start). A line with state "error" means Claude Code reports it
#   (MON-6 positive). Only idle / done / working / no status at all means
#   error detection stays a screen read (MON-6 negative).
#   The final "== hc read" block is the screen: look for how the bad model is
#   reported (error text, or claude exited back to a shell).
#   "RESULT precondition-failed" means the setup did not work; no conclusion.

NAME=p54-badmodel
TPL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-core/templates"
TPL="$TPL_DIR/p54-badmodel.md"
TASK="Reply with the single word OK."

has() { hc ls 2>&1 | grep -Eq "(^|[^A-Za-z0-9_-])$1([^A-Za-z0-9_-]|\$)"; }

if [ -e "$TPL" ]; then echo "RESULT precondition-failed: $TPL exists; remove it first"; exit 1; fi
if has "$NAME"; then echo "RESULT precondition-failed: terminal $NAME already exists"; exit 1; fi

WORK=$(mktemp -d) || exit 1
cleanup() {
  hc kill "$NAME" >/dev/null 2>&1; hc rm "$NAME" >/dev/null 2>&1
  rm -f "$TPL"
  rmdir "$WORK" 2>/dev/null
}
trap cleanup EXIT INT TERM
mkdir -p "$TPL_DIR" || exit 1

cat > "$TPL" <<T
---
description: probe 54 bad-model claude (temporary)
command: claude --model no-such-model --permission-mode default
---
Probe 54. Ignore.
T

echo "== hc run"
hc run --bg --name "$NAME" --cwd "$WORK" p54-badmodel "$TASK" || { echo "RESULT precondition-failed: hc run failed"; exit 1; }

# status object of `hc get --json`, on one line ("none" if absent)
status() {
  s=$(hc get --json "$NAME" 2>&1 | tr -d '\n' | sed -n 's/.*"status" *: *\({[^}]*}\).*/\1/p')
  echo "${s:-none}"
}

echo "== polling every 2 s for up to 90 s"
last="__unset__"; t=0; accepted=0
while [ $t -le 90 ]; do
  cur=$(status)
  if [ "$cur" != "$last" ]; then echo "STATUS t=${t}s $cur"; last=$cur; fi
  if [ $accepted -eq 0 ] && hc read "$NAME" 2>&1 | grep -q "Quick safety check"; then
    echo "== folder-trust dialog shown; accepting"; hc keys "$NAME" down enter; accepted=1
  fi
  sleep 2; t=$((t + 2))
done

echo "== hc get --json (final)"; hc get --json "$NAME" 2>&1
echo "== hc read"; hc read "$NAME" 2>&1
echo "== cleanup runs now"
