#!/bin/sh
# Probe for Issue #117 (Q18): can a template-launched Claude Code secretary hold
# `hc wait --children any` and `hc wait <name>` for minutes inside ONE Bash tool call?
# Does the call return, with what exit code and output, how long does the harness
# allow, and what does the agent see?
#
# Run from the repo root, on a host where herdr-core (hc) and claude run, in a plain
# login shell (not inside an agent):
#   sh scripts/probes/hc-wait-in-claude.sh
# Takes about 10 minutes (two waits of SLEEP seconds). Needs hc, claude (logged in), sh.
#
# What it touches: it starts its OWN core (HC_SESSION=p117-<pid>, XDG_CONFIG_HOME under a
# private temp folder), so your real core, templates and secretary are not read or changed.
# In it a real Claude Code secretary (from templates/secretary.md) is told to:
#   A)  start `hc run --bg --name p117-w1 -- sh -c 'sleep SLEEP; exit 5'`, then in ONE Bash
#       tool call (timeout 600000) run `hc wait --children any` with hc's DEFAULT timeout
#       (hc checks in after 180 s by default: reason "timeout", exit 0, child still running);
#   A2) at once, the same again with an explicit --timeout SLEEP+60: it should return when
#       the child exits, with exit code 5;
#   B)  the same with p117-w2 and `hc wait p117-w2 --timeout SLEEP+60`.
# Each wait is wrapped so the PROBE (not the agent) records start time, end time, the
# wait's output and its exit status in files, and ends with `cat` so the agent sees the
# output too. The agent also writes what the Bash tool showed it into seen-a.txt /
# seen-a2.txt / seen-b.txt, verbatim. The cleanup trap kills the terminals,
# stops ONLY that temp core and deletes the temp folder.
#
# The secretary is a real Claude Code in default permission mode and will ask before
# running hc: answer in that terminal with  HC_SESSION=<printed> hc attach secretary
# (detach again), or the probe gives up after TOTAL_WAIT seconds and reports FAIL.
#
# Environment: SLEEP (default 240) seconds each child runs; TOTAL_WAIT (default 1500)
# seconds for the whole test.
#
# Reading the output. Every verdict starts with "RESULT <name>:". PASS / FAIL / NO DATA.
#   a-returned, a2-, b-returned  the Bash call came back at all (a missing end time means the
#                            harness cut it, or the agent gave up: read the seen-* file).
#   a-checkin                hc checked in at its default timeout (informational).
#   a2-/b-blocked            it held for about SLEEP seconds, not at once.
#   a2-/b-output             the wait's output names the child and shows exit code 5.
# The wait's own exit status and the seen-* text are printed for reading by eye (hc may
# use its own status for the wait; the JSON line is the evidence). Paste the whole output back.
set -u

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,41p' "$0"; exit 0 ;;
  *) echo "hc-wait-in-claude: unknown argument: $1" >&2; exit 2 ;;
esac

SEC=secretary
SLEEP=${SLEEP:-240}
TOTAL_WAIT=${TOTAL_WAIT:-1500}
FAILS=0

ROOT=$(pwd)
[ -f "$ROOT/templates/secretary.md" ] || { echo "RESULT precondition-failed: run from the repo root"; exit 1; }
command -v hc >/dev/null 2>&1 || { echo "RESULT precondition-failed: hc not on PATH"; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "RESULT precondition-failed: claude not on PATH"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/probe117.XXXXXX") || exit 1 # private (0700)
CWD="$WORK/cwd"; XDG="$WORK/xdg"; OUT="$WORK/out"; mkdir -p "$CWD" "$XDG" "$OUT" || exit 1
HC_SESSION=p117-$$; export HC_SESSION
XDG_CONFIG_HOME=$XDG; export XDG_CONFIG_HOME

cleanup() {
  hc kill $SEC >/dev/null 2>&1; hc rm $SEC >/dev/null 2>&1
  for n in p117-w1 p117-w2; do hc kill $n >/dev/null 2>&1; hc rm $n >/dev/null 2>&1; done
  hc server stop >/dev/null 2>&1 # HC_SESSION is the temp core's: yours is untouched
  rm -rf "$WORK"
}
trap cleanup EXIT; trap 'exit 130' INT TERM

result() { # result <name> <PASS|FAIL|NO DATA> <detail>
  echo "RESULT $1: $2${3:+ ($3)}"
  [ "$2" = FAIL ] && FAILS=$((FAILS + 1))
  return 0
}
trust_dialog() { # answer Claude Code's folder-trust dialog (Enter), like probe 52
  case "$(hc read $SEC 2>/dev/null)" in *"Quick safety check"*|*"trust this folder"*) echo "-- answering the folder-trust dialog"; hc keys $SEC enter >/dev/null 2>&1 ;; esac
}
state_of() { hc get --json "$1" 2>/dev/null | tr -d '\n' | grep -Eo '"status": *\{[^{}]*"state": *"[a-z]*"' | grep -Eo '"[a-z]*"$' | tr -d '"'; }
judge() { # judge <a|a2|b> <child> <exit|checkin> [origin-file]: verdicts from the files the wrapped wait left behind
  p=$1; child=$2; want=$3; o=${4:-$1}
  if [ -f "$OUT/$p.rc" ] && [ -f "$OUT/$p.end" ]; then
    el=$(( $(cat "$OUT/$p.end") - $(cat "$OUT/$o.start") ))
    result $p-returned PASS "the Bash call came back ${el}s after the child started; wait exit status $(cat "$OUT/$p.rc")"
    if [ $want = checkin ]; then # hc's own default check-in, no --timeout given
      if grep -Eq '"reason": *"timeout"' "$OUT/$p.out"; then result $p-checkin PASS "hc checked in (reason timeout) after ${el}s with the default timeout; the child was not over"
      else result $p-checkin NO DATA "no reason timeout in the output: read it below"; fi
    else
      if [ $el -ge $((SLEEP - 15)) ]; then result $p-blocked PASS "held ${el}s of ${SLEEP}s"; else result $p-blocked FAIL "returned after ${el}s, long before ${SLEEP}s"; fi
      if grep -q "$child" "$OUT/$p.out" && grep -Eq '(^|[^0-9])5([^0-9]|$)' "$OUT/$p.out"; then result $p-output PASS "names $child and shows 5"
      else result $p-output FAIL "does not name $child with exit code 5"; fi
    fi
  elif [ -f "$OUT/$p.start" ]; then
    result $p-returned FAIL "started, but no end recorded: the call was cut or abandoned after $(( $(date +%s) - $(cat "$OUT/$p.start") ))s"
  else
    result $p-returned NO DATA "the wait was never started"
  fi
  echo "-- $p wait output:"; cat "$OUT/$p.out" 2>/dev/null
  echo "-- $p what the agent says the Bash tool showed (seen-$p.txt):"; cat "$OUT/seen-$p.txt" 2>/dev/null || echo "(not written)"
}

echo "== versions"; hc --version 2>&1; claude --version 2>&1
echo "== temp core session $HC_SESSION; children p117-w1 (A) and p117-w2 (B); child runs ${SLEEP}s then exits 5"
echo "== to look inside: HC_SESSION=$HC_SESSION hc attach $SEC   (detach again)"

mkdir -p "$XDG/herdr-core/templates" && cp -f "$ROOT/templates/secretary.md" "$XDG/herdr-core/templates/secretary.md" \
  || { result setup FAIL "cannot place the template"; exit 1; }

T=$((SLEEP + 60)) # explicit hc wait --timeout, longer than the child
wrap() { # wrap <tag> <hc wait args>: the probe records times, output and status; cat shows the output to the agent
  echo "date +%s > $OUT/$1.start; hc wait $2 > $OUT/$1.out 2>&1; echo \$? > $OUT/$1.rc; date +%s > $OUT/$1.end; cat $OUT/$1.out"
}
WRAP_A=$(wrap a "--children any"); WRAP_A2=$(wrap a2 "--children any --timeout $T"); WRAP_B=$(wrap b "p117-w2 --timeout $T")
TASK="This is probe 117 of the paddock organization; do exactly these steps in order, then stop and wait. Do not start any other terminal. Every wait is ONE Bash tool call with the Bash tool timeout parameter set to 600000 (the maximum), running exactly the one command line given: do not poll, shorten, split or background it, and do not retry it unless a step says so. After each call returns (or errors, times out or is cut), write the tool result you were shown, verbatim including any error text, to the seen file named in the step (or say there that nothing came back). A) Run: hc run --bg --name p117-w1 -- sh -c 'sleep $SLEEP; exit 5' . Then run: $WRAP_A . Seen file: $OUT/seen-a.txt . A2) Immediately after A returns, run: $WRAP_A2 . Seen file: $OUT/seen-a2.txt . B) Run: hc run --bg --name p117-w2 -- sh -c 'sleep $SLEEP; exit 5' . Then run: $WRAP_B . Seen file: $OUT/seen-b.txt . C) Say probe done and stop."
echo "== start the secretary"
( cd "$CWD" && hc run --bg --keep --name $SEC secretary "$TASK" > "$WORK/run.out" 2>&1; echo $? > "$WORK/run.rc" ) &
t=0; while [ ! -f "$WORK/run.rc" ] && [ $t -lt 120 ]; do trust_dialog; t=$((t + 2)); sleep 2; done
out=$(cat "$WORK/run.out" 2>/dev/null); [ "$(cat "$WORK/run.rc" 2>/dev/null)" = 0 ] || { result secretary-start FAIL "hc run failed or hung: $out"; exit 1; }
printf '%s' "$out" | tr -d '\n' | grep -Eq '"sent": *true' && result secretary-start PASS "first_message.sent true" \
  || result secretary-start FAIL "first_message.sent is not true: $out"

echo "== waiting up to ${TOTAL_WAIT}s (A+A2 and B: about two child runs of ${SLEEP}s); answer its prompts: HC_SESSION=$HC_SESSION hc attach $SEC"
t=0; said=0
while [ $t -lt "$TOTAL_WAIT" ]; do
  trust_dialog
  [ -f "$OUT/seen-b.txt" ] && break
  if [ "$(state_of $SEC)" = blocked ] && [ $said -eq 0 ]; then said=1; echo "-- the secretary is blocked on a prompt: answer it with HC_SESSION=$HC_SESSION hc attach $SEC"; fi
  t=$((t + 5)); sleep 5
done
sleep 3
echo "== finished after ~${t}s; secretary state: $(state_of $SEC)"
judge a p117-w1 checkin
judge a2 p117-w1 exit a
judge b p117-w2 exit
echo "== screen tail of the secretary (by eye: did it report the exit codes it saw?)"
hc read $SEC 2>&1 | tail -n 25
echo "== hc ls"; hc ls 2>&1
echo "== done; paste everything above back"
[ $FAILS -eq 0 ]
