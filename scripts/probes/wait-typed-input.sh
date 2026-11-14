#!/bin/sh
# Host check for Issue #285: does a line typed into a real Claude Code secretary end its
# `hc wait --children any` (reason "message") and `org wait --children` at once?
#
# Why Claude: hc's status comes from the program's own reports; a plain shell reports none
# (hc --skill, "Status, recovery, and cleanup"), and a typed line counts as a message only
# "while it worked" (hc wait --help). A shell stand-in measured FAIL on 2026-11-15 for that reason.
#
# Run from the repo root, on a host where herdr-core (hc) and claude run, in a plain login shell:
#   sh scripts/probes/wait-typed-input.sh
# Takes about 3 minutes. Needs hc, claude (logged in), sh, bash.
#
# What it touches: its OWN core (HC_SESSION=p285-<pid>, XDG_CONFIG_HOME under a private temp
# folder) and PADDOCK_STATE_DIR under it. Your real core, templates and secretary are not read
# or changed. A secretary (from templates/secretary.md) is told to start a child
# (sleep 240), then run in ONE Bash call (timeout 600000):
#   A) hc wait --children any --timeout 120     (hc alone)
#   B) scripts/org --as secretary wait --children --timeout 120   (the code under test)
# The probe runs each wait wrapped (start / end time, output in files). 15 s after each start
# it types one line into the secretary with `hc send secretary "typed line"`.
# The secretary is a real Claude Code in default permission mode and may ask before running
# hc: answer with  HC_SESSION=<printed> hc attach secretary  (detach again), or the probe gives
# up after TOTAL_WAIT seconds (default 600) and reports FAIL.
#
# Reading the output. Every verdict starts with "RESULT <name>:". PASS / FAIL / NO DATA.
#   a-message, b-message  the wait printed "reason":"message" (not timeout, not a child's end).
#   a-fast, b-fast        it returned within 30 s of the typed line (the bound is 120 s here).
# a FAIL with b PASS or the reverse points at hc (a) or at scripts/org (b). Paste the whole output.
set -u

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
  *) echo "wait-typed-input: unknown argument: $1" >&2; exit 2 ;;
esac

SEC=secretary
TOTAL_WAIT=${TOTAL_WAIT:-600}
FAILS=0
ROOT=$(pwd)
[ -f "$ROOT/templates/secretary.md" ] || { echo "RESULT precondition-failed: run from the repo root"; exit 1; }
command -v hc >/dev/null 2>&1 || { echo "RESULT precondition-failed: hc not on PATH"; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "RESULT precondition-failed: claude not on PATH"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/probe285.XXXXXX") || exit 1
CWD="$WORK/cwd"; XDG="$WORK/xdg"; OUT="$WORK/out"; mkdir -p "$CWD" "$XDG" "$OUT" "$WORK/state" || exit 1
HC_SESSION=p285-$$; export HC_SESSION
XDG_CONFIG_HOME=$XDG; export XDG_CONFIG_HOME
. "$(dirname "$0")/claude-link.sh"
claude_link_save
unset PADDOCK_ORG_ID PADDOCK_SECRETARY_NAME
cleanup() {
  claude_link_restore
  hc kill $SEC >/dev/null 2>&1; hc rm $SEC >/dev/null 2>&1
  hc kill p285-kid >/dev/null 2>&1; hc rm p285-kid >/dev/null 2>&1
  hc server stop >/dev/null 2>&1 # HC_SESSION is the temp core's: yours is untouched
  rm -rf "$WORK"
}
trap cleanup EXIT; trap 'exit 130' INT TERM

result() { echo "RESULT $1: $2${3:+ ($3)}"; [ "$2" = FAIL ] && FAILS=$((FAILS + 1)); return 0; }
trust_dialog() {
  case "$(hc read $SEC 2>/dev/null)" in *"Quick safety check"*|*"trust this folder"*) echo "-- answering the folder-trust dialog"; hc keys $SEC enter >/dev/null 2>&1 ;; esac
}
wrap() { # wrap <tag> <command...>
  t=$1; shift
  echo "date +%s > $OUT/$t.start; $* > $OUT/$t.out 2>&1; date +%s > $OUT/$t.end; cat $OUT/$t.out"
}
WRAP_A=$(wrap a hc wait --children any --timeout 120)
WRAP_B=$(wrap b env PADDOCK_STATE_DIR=$WORK/state bash $ROOT/scripts/org --as secretary wait --children --timeout 120)
TASK="This is probe 285 of the paddock organization; do exactly these steps in order, then stop. Each wait is ONE Bash tool call with the Bash tool timeout parameter set to 600000, running exactly the one command line given: do not poll, shorten, split or background it, and do not retry it. A line may be typed to you while a wait runs; it is part of the probe: when the wait returns, answer it with the single word ok. Steps: 0) Run: hc run --bg --name p285-kid -- sleep 240 . A) Run: $WRAP_A . B) Run: $WRAP_B . C) Say probe done and stop."

mkdir -p "$XDG/herdr-core/templates" && cp -f "$ROOT/templates/secretary.md" "$XDG/herdr-core/templates/secretary.md" \
  || { result setup FAIL "cannot place the template"; exit 1; }
echo "== versions"; hc --version 2>&1; claude --version 2>&1
echo "== temp core $HC_SESSION; to look inside: HC_SESSION=$HC_SESSION hc attach $SEC (detach again)"
( cd "$CWD" && hc run --bg --keep --name $SEC secretary "$TASK" > "$WORK/run.out" 2>&1; echo $? > "$WORK/run.rc" ) &
t=0; while [ ! -f "$WORK/run.rc" ] && [ $t -lt 120 ]; do trust_dialog; t=$((t + 2)); sleep 2; done
[ "$(cat "$WORK/run.rc" 2>/dev/null)" = 0 ] || { result secretary-start FAIL "hc run failed or hung: $(cat "$WORK/run.out" 2>/dev/null)"; exit 1; }

typed=
for p in a b; do # type one line 15 s after each wait starts
  t=0; while [ ! -f "$OUT/$p.start" ] && [ $t -lt "$TOTAL_WAIT" ]; do trust_dialog; t=$((t + 3)); sleep 3; done
  [ -f "$OUT/$p.start" ] || { result $p-message NO DATA "the wait never started: a prompt may have blocked the secretary"; continue; }
  sleep 15; ts=$(date +%s); hc send $SEC "typed line $p" >/dev/null 2>&1
  t=0; while [ ! -f "$OUT/$p.end" ] && [ $t -lt 150 ]; do sleep 2; t=$((t + 2)); done
  if [ -f "$OUT/$p.end" ]; then
    dt=$(( $(cat "$OUT/$p.end") - ts ))
    grep -Eq '"reason": *"message"' "$OUT/$p.out" && result $p-message PASS || result $p-message FAIL "see the output below"
    [ "$dt" -le 30 ] && result $p-fast PASS "returned ${dt}s after the typed line" || result $p-fast FAIL "returned ${dt}s after the typed line"
  else
    result $p-message FAIL "the wait did not return within 150 s of the typed line"
  fi
  echo "-- $p wait output:"; cat "$OUT/$p.out" 2>/dev/null; echo
done
echo "== screen tail of the secretary (by eye: did it read and answer both typed lines?)"
hc read $SEC 2>&1 | tail -n 25
echo "== done; paste everything above back"
[ $FAILS -eq 0 ]
