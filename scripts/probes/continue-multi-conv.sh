#!/bin/sh
# Probe for Issue #57 (Q4): which conversation does `claude --continue` resume
# when one folder holds several?
#
# Run from the repo root, in a LOGIN SHELL (not from inside an agent: Q17 start
# rule), on a host where herdr core (hc) runs and claude is logged in:
#   sh scripts/probes/continue-multi-conv.sh
# Takes about 6 to 8 minutes (five Claude Code launches, each waits up to 90 s
# for the prompt and up to 90 s for a reply). Needs: hc and claude on PATH,
# POSIX sh, ls, grep, sed. Creates a folder under $HOME (not /tmp: trust
# dialog), temporary templates, and terminals named p57-*. The cleanup trap
# kills and removes the terminals and deletes the templates; the folder and its
# transcripts are left for inspection. Do not run it twice at once.
#
# Arrangement (Q17): the template command is
#   env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
#       -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN claude [args]
# If any screen shows "Transcript saving is off", the run is void.
#
# Steps (each Claude Code session is stopped with `hc kill`, a hard stop; the
# transcript is written per turn, so a finished turn is already on disk):
#   A  session A: told codeword ALPHA<n>, replies, killed.
#   B  session B (a new conversation, same folder, started after A ended):
#      told codeword BRAVO<n>, replies, killed.
#   C1 `claude --continue` from the template; asked for the codeword.
#      Simple order: A first, B last (created and active).
#   C1 is killed. Then:
#   R  session A is resumed by id (`claude --resume <A's transcript id>`), told
#      one more line, killed. Now A was the last ACTIVE and B was created later.
#      (Whether the transcript file's time moves is printed in the listings.)
#   C2 `claude --continue` again; asked for the codeword.
#
# Reading the output (lines starting with "RESULT"):
#   RESULT C1-simple-order: ALPHA | BRAVO | none | both | void(...)
#     ALPHA = the first-created conversation was resumed; BRAVO = the most
#     recent (last created and last active); none = answered neither;
#     both = both words appear in the reply line (read the screen block).
#   RESULT C2-last-active-A: same values. BRAVO again = creation order wins
#     (or file time does not move on resume); ALPHA = last activity wins.
#   RESULT precondition-failed / void: the setup did not work; no conclusion.
# The "LISTING" blocks show the folder's transcript files (name, size, mtime)
# after A, after B, after R, after C1 and after C2. Session ids in the output
# are fine for the secretary and must NOT be copied into docs. The probe
# prints no environment variables.
# Also printed: hc and claude versions. Paste everything back.

TPL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-core/templates"
TPL="$TPL_DIR/p57-cont.md"
TPLR="$TPL_DIR/p57-resume.md"
RAND=$(date +%H%M%S)
CA=ALPHA$RAND
CB=BRAVO$RAND
BASE="$HOME/p57-continue-$(date +%Y%m%d-%H%M%S)"
CWD="$BASE/wt"
NAME=p57-s
ENVU="env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN"

has() { hc ls 2>&1 | grep -Eq "(^|[^A-Za-z0-9_-])$1([^A-Za-z0-9_-]|\$)"; }

if [ -e "$TPL" ] || [ -e "$TPLR" ]; then echo "RESULT precondition-failed: $TPL or $TPLR exists; remove it first"; exit 1; fi
if has $NAME; then echo "RESULT precondition-failed: terminal $NAME already exists"; exit 1; fi

cleanup() {
  hc kill $NAME >/dev/null 2>&1; hc rm $NAME >/dev/null 2>&1
  rm -f "$TPL" "$TPLR"
}
trap cleanup EXIT INT TERM
mkdir -p "$TPL_DIR" "$CWD" || exit 1
# Resolve the folder as Claude Code names it (symlinks, e.g. a mounted $HOME).
CWD=$(cd "$CWD" && pwd -P) || exit 1

cat > "$TPL" <<T
---
description: probe 57 continue with several conversations (temporary)
command: $ENVU claude
---
Probe 57. Ignore.
T

echo "== hc version";     hc --version 2>&1
echo "== claude version"; claude --version 2>&1

# Claude Code keeps transcripts in ~/.claude/projects/<folder with every
# non-alphanumeric character replaced by "-">/<session id>.jsonl
PROJ="$HOME/.claude/projects/$(printf '%s' "$CWD" | sed 's/[^A-Za-z0-9]/-/g')"
listing() { # $1 = label
  echo "LISTING $1 (name, size, mtime):"
  ls -l --time-style=full-iso "$PROJ" 2>&1 | grep '\.jsonl' | sed 's/^[^ ]* *[^ ]* *[^ ]* *[^ ]* *//'
}
ids() { ls "$PROJ" 2>/dev/null | sed -n 's/\.jsonl$//p' | sort; }

status_of() { hc get --json $NAME 2>&1 | tr -d '\n' | sed -n 's/.*"status" *: *\({[^}]*}\).*/\1/p'; }

# start_session: launch $1 (template name), get to the prompt.
start_session() {
  hc run --bg --name $NAME --cwd "$CWD" "$@" || { echo "RESULT precondition-failed: hc run failed"; exit 1; }
  i=0
  while [ $i -lt 90 ]; do
    screen=$(hc read $NAME 2>&1)
    case "$screen" in
      *"Quick safety check"*) echo "-- trust dialog: accepting"; hc keys $NAME down enter; sleep 3 ;;
      *"for shortcuts"*|*"? for"*) break ;;
    esac
    i=$((i + 1)); sleep 1
  done
  case "$screen" in *"Transcript saving is off"*) echo "RESULT void(transcripts off): is the core started from a login shell?"; exit 1 ;; esac
}

# ask: send $1 and wait until the status reaches done/idle (up to 90 s).
ask() {
  hc send $NAME "$1" || echo "hc send exit: $?"
  sleep 5
  t=0
  while [ $t -lt 90 ]; do
    case "$(status_of)" in *'"done"'*|*'"idle"'*) break ;; esac
    t=$((t + 2)); sleep 2
  done
  sleep 2
}

stop_session() { hc kill $NAME; echo "hc kill exit: $?"; sleep 2; hc rm $NAME >/dev/null 2>&1; sleep 1; }

# recall: ask for the codeword, print the screen, set REPLY_LINE.
recall() {
  ask "What is the codeword I gave you earlier in this conversation? Begin your reply with the text RECALL= immediately followed by the codeword, and nothing else."
  screen=$(hc read $NAME 2>&1)
  echo "== screen"; echo "$screen"
  RECALL=$(printf '%s\n' "$screen" | grep 'RECALL=[A-Z]')
}

verdict() { # $1 = label
  a=no; b=no
  case "$RECALL" in *"$CA"*) a=yes ;; esac
  case "$RECALL" in *"$CB"*) b=yes ;; esac
  case "$a$b" in
    yesno) r=ALPHA ;; noyes) r=BRAVO ;; yesyes) r=both ;; *) r=none ;;
  esac
  echo "RESULT $1: $r"
}

echo "== A: first conversation, codeword $CA"
start_session p57-cont
ask "The codeword for this conversation is $CA. Reply with only the word ok."
A_ID=$(ids)
listing "after A"
stop_session
[ -n "$A_ID" ] || { echo "RESULT void(no transcript written for A in $PROJ)"; exit 1; }
sleep 5 # let the mtimes of A and B differ visibly

echo "== B: second conversation, same folder, codeword $CB"
start_session p57-cont
ask "The codeword for this conversation is $CB. Reply with only the word ok."
B_ID=$(ids | grep -vxF "$A_ID")
listing "after B"
stop_session
[ -n "$B_ID" ] || { echo "RESULT void(B did not create a separate transcript; --continue in a bare launch? see LISTING)"; exit 1; }

echo "== C1: claude --continue from the template (A ended first, B last)"
cat > "$TPLR" <<T
---
description: probe 57 continue/resume (temporary)
command: $ENVU claude --continue
---
Probe 57. Ignore.
T
start_session p57-resume
recall
verdict C1-simple-order
listing "after C1"
stop_session

echo "== R: resume A by id so that A is the last active one"
cat > "$TPLR" <<T
---
description: probe 57 resume A by id (temporary)
command: $ENVU claude --resume $A_ID
---
Probe 57. Ignore.
T
start_session p57-resume
ask "Reply with only the word ok."
listing "after R (A resumed, B created before)"
stop_session
sleep 3

echo "== C2: claude --continue again (A last active, B created later)"
cat > "$TPLR" <<T
---
description: probe 57 continue (temporary)
command: $ENVU claude --continue
---
Probe 57. Ignore.
T
start_session p57-resume
recall
verdict C2-last-active-A
listing "after C2"
stop_session
echo "== done; paste everything above back. Folder left in place: $CWD"
