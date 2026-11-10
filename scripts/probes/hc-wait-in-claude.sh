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
#   A) start `hc run --bg --name p117-w1 -- sh -c 'sleep SLEEP; exit 5'`, then in ONE Bash
#      tool call (timeout 600000) run `hc wait --children any`;
#   B) the same with p117-w2 and `hc wait p117-w2`.
# Each wait is wrapped so the PROBE (not the agent) records start time, end time, the
# wait's output and its exit status in files. The agent also writes what the Bash tool
# showed it into seen-a.txt / seen-b.txt, verbatim. The cleanup trap kills the terminals,
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
#   a-returned / b-returned  the Bash call came back at all (a missing end time means the
#                            harness cut it, or the agent gave up: read the seen-* file).
#   a-blocked / b-blocked    it held for about SLEEP seconds, not at once.
#   a-output / b-output      the wait's output names the child and shows exit code 5.
# The wait's own exit status and the seen-* text are printed for reading by eye (hc may
# use its own status for the wait; the JSON line is the evidence). Paste the whole output back.
set -u

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
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
judge() { # judge <a|b> <child>: verdicts from the files the wrapped wait left behind
  p=$1; child=$2
  if [ -f "$OUT/$p.rc" ] && [ -f "$OUT/$p.end" ]; then
    el=$(( $(cat "$OUT/$p.end") - $(cat "$OUT/$p.start") ))
    result $p-returned PASS "the Bash call came back after ${el}s; wait exit status $(cat "$OUT/$p.rc")"
    if [ $el -ge $((SLEEP - 15)) ]; then result $p-blocked PASS "held ${el}s of ${SLEEP}s"; else result $p-blocked FAIL "returned after ${el}s, long before ${SLEEP}s"; fi
    if grep -q "$child" "$OUT/$p.out" && grep -Eq '(^|[^0-9])5([^0-9]|$)' "$OUT/$p.out"; then result $p-output PASS "names $child and shows 5"
    else result $p-output FAIL "does not name $child with exit code 5"; fi
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

WRAP_A="date +%s > $OUT/a.start; hc wait --children any > $OUT/a.out 2>&1; echo \$? > $OUT/a.rc; date +%s > $OUT/a.end"
WRAP_B="date +%s > $OUT/b.start; hc wait p117-w2 > $OUT/b.out 2>&1; echo \$? > $OUT/b.rc; date +%s > $OUT/b.end"
TASK="This is probe 117 of the paddock organization; do exactly these steps in order, then stop and wait. Do not start any other terminal. A) Run: hc run --bg --name p117-w1 -- sh -c 'sleep $SLEEP; exit 5' . Then in ONE Bash tool call, with the Bash tool's timeout parameter set to 600000 (the maximum), run exactly this single command line: $WRAP_A . Do not poll, do not shorten it, do not background it. When the call returns (or errors, times out or is cut), write the tool result you were shown, verbatim and including any error text, to $OUT/seen-a.txt (or say there that nothing came back). B) Run: hc run --bg --name p117-w2 -- sh -c 'sleep $SLEEP; exit 5' . Then in ONE Bash tool call, again with timeout 600000, run exactly: $WRAP_B . Afterwards write what the tool showed you to $OUT/seen-b.txt the same way. C) Say 'probe done' and stop."
echo "== start the secretary"
( cd "$CWD" && hc run --bg --keep --name $SEC secretary "$TASK" > "$WORK/run.out" 2>&1; echo $? > "$WORK/run.rc" ) &
t=0; while [ ! -f "$WORK/run.rc" ] && [ $t -lt 120 ]; do trust_dialog; t=$((t + 2)); sleep 2; done
out=$(cat "$WORK/run.out" 2>/dev/null); [ "$(cat "$WORK/run.rc" 2>/dev/null)" = 0 ] || { result secretary-start FAIL "hc run failed or hung: $out"; exit 1; }
printf '%s' "$out" | tr -d '\n' | grep -Eq '"sent": *true' && result secretary-start PASS "first_message.sent true" \
  || result secretary-start FAIL "first_message.sent is not true: $out"

echo "== waiting up to ${TOTAL_WAIT}s (two waits of ${SLEEP}s); answer its prompts: HC_SESSION=$HC_SESSION hc attach $SEC"
t=0; said=0
while [ $t -lt "$TOTAL_WAIT" ]; do
  trust_dialog
  [ -f "$OUT/seen-b.txt" ] && break
  if [ "$(state_of $SEC)" = blocked ] && [ $said -eq 0 ]; then said=1; echo "-- the secretary is blocked on a prompt: answer it with HC_SESSION=$HC_SESSION hc attach $SEC"; fi
  t=$((t + 5)); sleep 5
done
sleep 3
echo "== finished after ~${t}s; secretary state: $(state_of $SEC)"
judge a p117-w1
judge b p117-w2
echo "== screen tail of the secretary (by eye: did it report the exit codes it saw?)"
hc read $SEC 2>&1 | tail -n 25
echo "== hc ls"; hc ls 2>&1
echo "== done; paste everything above back"
[ $FAILS -eq 0 ]
