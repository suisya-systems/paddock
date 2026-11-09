#!/bin/sh
# Probe for Issue #53 (MON-5): does `hc get` show `blocked`, and with which
# `kind`, when the agent asks the person a question with its question tool
# (AskUserQuestion)? Known: permission prompts report blocked/kind permission.
#
# Run from the repo root, on a host where herdr core (hc) and claude run:
#   sh scripts/probes/blocked-question.sh
# Takes about 2-3 minutes: up to 90 s to reach the prompt, 90 s of polling,
# then a manual step that is yours. Needs: hc and claude on PATH, a logged-in
# claude, POSIX sh. Starts one terminal named p53 and one temporary template
# (p53-probe); the cleanup trap removes both.
#
# Reading the output:
#   "STATUS t=<s>: <object>"  the `status` object of `hc get --json p53`,
#                             printed whenever it changes (polled every 2 s,
#                             at most 90 s). Look for state "blocked" and its
#                             "kind" and "msg".
#   "RESULT question-seen: yes|no"  whether the screen showed the question.
#   If no STATUS line has state "blocked" while the question was on screen,
#   the finding is: a question does not report blocked (record what it
#   reported instead).
# Manual step: after the polling, the question is still open. Look at the
# screen (`hc attach p53`, or herdr-app) and confirm it is a question with
# options, not a permission prompt. Answer it (pick an option), wait a few
# seconds, then press Enter here: the script polls once more to show the
# status after the answer. Do not answer before the polling ends.

NAME=p53
TPL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-core/templates"
TPL="$TPL_DIR/p53-probe.md"

has() { hc ls 2>&1 | grep -Eq "(^|[^A-Za-z0-9_-])$1([^A-Za-z0-9_-]|\$)"; }

if [ -e "$TPL" ]; then echo "RESULT precondition-failed: $TPL exists; remove it first"; exit 1; fi
if has $NAME; then echo "RESULT precondition-failed: terminal $NAME already exists"; exit 1; fi

WORK=$(mktemp -d) || exit 1
mkdir -p "$WORK/cwd" || exit 1
cleanup() {
  hc kill $NAME >/dev/null 2>&1; hc rm $NAME >/dev/null 2>&1
  rm -f "$TPL"
  rmdir "$WORK/cwd" "$WORK" 2>/dev/null
}
trap cleanup EXIT INT TERM
mkdir -p "$TPL_DIR" || exit 1

# Same launch shape as templates/secretary.md (command: claude).
cat > "$TPL" <<T
---
description: probe 53 blocked on a question (temporary)
command: claude --permission-mode default
---
Probe 53. Ignore.
T

# status_of: the "status" object of `hc get --json`, one line.
status_of() {
  out=$(hc get --json $NAME 2>&1)
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$out" | jq -c '.status' 2>/dev/null || printf '%s' "$out"
  else
    printf '%s' "$out" | tr -d '\n' | sed -n 's/.*"status" *: *\({[^}]*}\).*/\1/p'
  fi
}

echo "== start"
hc run --bg --name $NAME --cwd "$WORK/cwd" p53-probe || { echo "RESULT precondition-failed: hc run failed"; exit 1; }

echo "== wait for the prompt (up to 90 s); answer the folder-trust dialog if shown"
i=0
while [ $i -lt 90 ]; do
  screen=$(hc read $NAME 2>&1)
  case "$screen" in
    *"Quick safety check"*) echo "-- trust dialog: accepting"; hc keys $NAME down enter; sleep 3 ;;
    *"for shortcuts"*|*"? for"*) break ;;
  esac
  i=$((i + 1)); sleep 1
done

echo "== send the task"
hc send $NAME "Use your AskUserQuestion tool to ask me which colour I prefer, with the options red and blue. Do not use any other tool and do nothing else until I answer." || echo "hc send exit: $?"

echo "== poll hc get --json $NAME every 2 s for up to 90 s (STATUS printed on change)"
last="__none__"; t=0
while [ $t -le 90 ]; do
  cur=$(status_of)
  if [ "$cur" != "$last" ]; then echo "STATUS t=$t: $cur"; last=$cur; fi
  t=$((t + 2)); sleep 2
done

screen=$(hc read $NAME 2>&1)
case "$screen" in
  *"Enter to select"*) echo "RESULT question-seen: yes" ;;
  *) echo "RESULT question-seen: no (check the screen below)" ;;
esac
echo "== screen at the end of polling"; echo "$screen"

cat <<M

== MANUAL STEP =====================================================
The question should still be open in terminal $NAME. Look at it
(hc attach $NAME, or herdr-app) and note: is it a question with options,
and does the screen say anything like a permission prompt? Then ANSWER it
(pick an option), wait a few seconds, and press Enter here.
=====================================================================
M
read dummy
echo "STATUS after answer: $(status_of)"
sleep 10
echo "STATUS 10 s later: $(status_of)"
echo "== hc read $NAME (final)"; hc read $NAME 2>&1
echo "== cleanup runs now (hc kill $NAME, hc rm $NAME, template removed)"
