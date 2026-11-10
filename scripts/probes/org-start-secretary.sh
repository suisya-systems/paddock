#!/bin/sh
# Probe for Issue #52 (SK-2): does the rewritten org-start, run from a login
# shell, give a secretary that reports a status in `hc get` and whose
# environment has no inherited Claude Code session variables?
#
# Run from the repo root, on a host where herdr-core (hc) and claude run, in a
# plain login shell with NO agent above it (that is the (a) half of the test):
#   sh scripts/probes/org-start-secretary.sh
# Takes about 30-90 seconds (up to 90 s waiting for the status). Needs hc,
# claude (logged in), bash, POSIX sh, grep, cut, sort, tr, sleep. Linux/WSL for
# the environment check (it reads /proc); elsewhere that line says NO DATA.
#
# What it touches, and how it stays away from yours: it starts its OWN core
# (HC_SESSION=p52-<pid>, XDG_CONFIG_HOME under a private temp folder), so your
# real core, your real templates folder and your real secretary are not read or
# changed. org-start is pointed at throw-away folders with
# PADDOCK_CORE_TEMPLATES_DIR (the temp core's templates folder) and
# PADDOCK_APP_MODS_DIR (a temp folder), and the secretary terminal is named
# p52-secretary through PADDOCK_SECRETARY_NAME. The cleanup trap kills and
# removes that terminal, stops ONLY that temp core, and deletes the temp folder.
# The script answers Claude Code's folder-trust dialog in the probe terminal
# itself (Enter). If a different dialog blocks it, "RESULT hc-get-status" says
# so and the screen tail is printed.
#
# Reading the output. Every verdict line starts with "RESULT <name>:".
#   runner-env       clean  -> the shell holds none of the agent variables: the
#                              (a) half can be measured.
#                    agent  -> org-start refuses (exit 4); the (a) half could
#                              NOT be measured. Rerun from a login shell.
#   org-start-exit   PASS = exit code 0. Anything else FAIL (code printed; see
#                    scripts/org-start.sh for the code table).
#   ready-line       PASS = output has a line "org-start: ready." FAIL otherwise.
#   hc-get-status    PASS = `hc get --json p52-secretary` has a "status": {...}
#                    object (printed). FAIL = it has none. The object's keys
#                    and the top-level keys are printed too: compare them with
#                    what org-start assumes (a "status": { ... } object).
#   template-folder  PASS = hc run found the template that org-start placed in
#                    the folder it was given, i.e. the core reads the folder the
#                    PADDOCK_CORE_TEMPLATES_DIR override names. FAIL = it did not.
#   env-<VAR>        absent = PASS. PRESENT = FAIL (inherited). NO DATA = the
#                    Claude process was not found (see the line above it).
#                    Variables: CLAUDE_CODE_CHILD_SESSION, CLAUDE_CODE_SESSION_ID,
#                    CLAUDE_CODE_MESSAGING_SOCKET, CLAUDE_CODE_MESSAGING_TOKEN.
#                    Names only, never values.
#   transcript-notice absent = PASS. PRESENT = FAIL ("Transcript saving is off"
#                    is on the secretary's screen). NO DATA = screen unreadable
#                    or still a dialog.
# A FAIL on env-* while runner-env is agent means nothing about org-start. The
# whole probe passes when every RESULT above is PASS or absent.
set -u

NAME=p52-secretary
VARS4="CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN"
ROOT=$(pwd)
[ -f "$ROOT/skills/org-start/scripts/org-start.sh" ] || { echo "RESULT precondition-failed: run from the repo root"; exit 1; }
command -v hc >/dev/null 2>&1 || { echo "RESULT precondition-failed: hc not on PATH"; exit 1; }
command -v bash >/dev/null 2>&1 || { echo "RESULT precondition-failed: bash not on PATH"; exit 1; }

# The runner's own environment, names only (before any export below).
RUNNER=
for v in CLAUDECODE $VARS4; do [ -n "$(printenv "$v" 2>/dev/null)" ] && RUNNER="$RUNNER $v"; done
if [ -z "$RUNNER" ]; then echo "RESULT runner-env: clean"; else echo "RESULT runner-env: agent (set:$RUNNER) - the (a) half cannot be measured"; fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/probe52.XXXXXX") || exit 1 # private (0700)
CWD="$WORK/cwd"; XDG="$WORK/xdg"; MODS="$WORK/mods"; TPLS="$XDG/herdr-core/templates"
mkdir -p "$CWD" "$XDG" "$MODS" || exit 1
HC_SESSION=p52-$$; export HC_SESSION
XDG_CONFIG_HOME=$XDG; export XDG_CONFIG_HOME
cleanup() {
  [ -n "${OSPID:-}" ] && kill "$OSPID" >/dev/null 2>&1
  hc kill "$NAME" >/dev/null 2>&1; hc rm "$NAME" >/dev/null 2>&1
  hc server stop >/dev/null 2>&1 # HC_SESSION is the temp core's: yours is untouched
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

echo "== versions"; hc --version 2>&1; claude --version 2>&1
echo "== temp core session $HC_SESSION; terminal $NAME; folders under a private temp dir"

# Run org-start in the background so this script can answer the trust dialog while it waits.
( cd "$CWD" && PADDOCK_CORE_TEMPLATES_DIR="$TPLS" PADDOCK_APP_MODS_DIR="$MODS" PADDOCK_BIN_DIR="$WORK/bin" \
  PADDOCK_SECRETARY_NAME=$NAME PADDOCK_READY_TRIES=90 \
  bash "$ROOT/skills/org-start/scripts/org-start.sh" > "$WORK/os.out" 2>&1; echo $? > "$WORK/os.rc" ) &
OSPID=$!
t=0
while [ ! -f "$WORK/os.rc" ] && [ $t -lt 120 ]; do
  screen=$(hc read "$NAME" 2>/dev/null)
  case "$screen" in *"Quick safety check"*|*"trust this folder"*) echo "-- answering the folder-trust dialog"; hc keys "$NAME" enter >/dev/null 2>&1 ;; esac
  t=$((t + 2)); sleep 2
done
OSRC=$(cat "$WORK/os.rc" 2>/dev/null || echo "none")
echo "== org-start output"; cat "$WORK/os.out"

echo "== results"
if [ "$OSRC" = 0 ]; then echo "RESULT org-start-exit: PASS (0)"; else echo "RESULT org-start-exit: FAIL ($OSRC)"; fi
if grep -q '^org-start: ready\.' "$WORK/os.out"; then echo "RESULT ready-line: PASS"; else echo "RESULT ready-line: FAIL"; fi
if hc get "$NAME" >/dev/null 2>&1; then echo "RESULT template-folder: PASS (hc run started the terminal from the template placed in the overridden folder)"; else echo "RESULT template-folder: FAIL (no terminal $NAME; see the org-start output)"; fi

JSON=$(hc get --json "$NAME" 2>&1)
if printf '%s' "$JSON" | grep -Eq '"status": *\{'; then
  echo "RESULT hc-get-status: PASS"
  echo "   status object: $(printf '%s' "$JSON" | grep -Eo '"status": *\{[^}]*\}' | head -n 1)"
else
  echo "RESULT hc-get-status: FAIL (no status object)"
fi
echo "   top-level keys in hc get --json: $(printf '%s' "$JSON" | grep -Eo '"[A-Za-z_]+": *' | tr -d ' :"' | sort -u | tr '\n' ' ')"

# Environment of the Claude process: the process whose cwd is the probe's throw-away folder.
FOUND=0
for p in /proc/[0-9]*; do
  [ "$(readlink "$p/cwd" 2>/dev/null)" = "$CWD" ] || continue
  case "$(cat "$p/comm" 2>/dev/null)" in claude|node|bun) ;; *) continue ;; esac
  [ -r "$p/environ" ] || continue
  FOUND=1; tr '\0' '\n' < "$p/environ" | cut -d= -f1 | sort > "$WORK/names"
  echo "   env checked on a process named $(cat "$p/comm") (names only)"
  break
done
for v in $VARS4; do
  if [ $FOUND -eq 0 ]; then echo "RESULT env-$v: NO DATA (no claude process found with the probe folder as cwd; /proc missing?)"
  elif grep -qx "$v" "$WORK/names"; then echo "RESULT env-$v: PRESENT"
  else echo "RESULT env-$v: absent"; fi
done
[ $FOUND -eq 1 ] && echo "   other CLAUDE-prefixed names in that environment: $(grep '^CLAUDE' "$WORK/names" | grep -vxE "$(echo $VARS4 | tr ' ' '|')" | tr '\n' ' ')"

sleep 2
SCREEN=$(hc read "$NAME" 2>&1)
case "$SCREEN" in
  *"Transcript saving is off"*) echo "RESULT transcript-notice: PRESENT" ;;
  "") echo "RESULT transcript-notice: NO DATA (empty screen)" ;;
  *"Quick safety check"*|*"trust this folder"*) echo "RESULT transcript-notice: NO DATA (a dialog is still open)" ;;
  *) echo "RESULT transcript-notice: absent" ;;
esac
echo "== screen tail (check it by eye for a dialog; no values are printed by this script)"
printf '%s\n' "$SCREEN" | tail -n 8
echo "== done; paste everything above back"
