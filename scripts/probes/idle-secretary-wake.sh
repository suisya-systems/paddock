#!/bin/sh
# Host check for Issue #140 (Q18 refinement): with the secretary waiting between turns, an
# answer from the card reaches the waiting worker with nobody typing into any terminal.
#
# Run from the repo root, on a host where herdr-core (hc) and claude run, in a plain login
# shell (not inside an agent):
#   sh scripts/probes/idle-secretary-wake.sh
# Takes about 5-10 minutes. Needs hc, claude (logged in), sh, ps and /proc (Linux or WSL).
#
# What it touches: its OWN core (HC_SESSION=p140-<pid>), XDG_CONFIG_HOME and PADDOCK_STATE_DIR
# under a private temp folder, set before the first hc command so the core and every terminal
# in it inherit them. Your real core, templates, mailbox and secretary are not read or changed.
#
# Steps:
#   1. org-state gets one task (p140) and one approval; a stand-in worker w-p140 (a shell loop,
#      not Claude) polls its own mailbox for the answer.
#   2. A real secretary starts from templates/secretary.md with --cwd at the repo root. Its task
#      says only that it is resuming with that task and approval and must follow its template;
#      it is NOT told to run `org wait`.
#   3. The probe watches the process list until the secretary's `org --as secretary wait` runs,
#      and until it has run twice (one check-in after PADDOCK_WAIT_TIMEOUT, set to WAIT_TIMEOUT).
#   4. From then on nobody types: the probe sends `ANSWER <id> yes` from `person` with
#      scripts/org, exactly as the card does, and waits for the worker to get the answer.
#   5. Only after the verdict, it types ONE line into the secretary with `hc send` to measure
#      how long a line a person types waits while the secretary waits (informational).
#
# The secretary is a real Claude Code and may ask before running commands: answer in its
# terminal with  HC_SESSION=<printed> hc attach secretary  (detach again) during steps 2-3.
# Answering a prompt is not typing a message; once step 4 starts, do not touch it.
#
# Environment: WAIT_TIMEOUT (default 60) the secretary's org wait timeout for this run;
# SETUP_WAIT (default 600) seconds for steps 2-3; ANSWER_BOUND (default 120) seconds for step 4.
#
# Reading the output. Every verdict starts with "RESULT <name>:". PASS / FAIL / NO DATA.
#   secretary-start   the secretary got its first message.
#   wait-entered      the secretary ran `org wait` by itself, from the template.
#   wait-kept         it ran it again after a check-in (the loop holds).
#   answer-reached    the stand-in worker got "Answer to your question (<id>): yes" within
#                     ANSWER_BOUND seconds of the card-style message, with nobody typing.
#   approval-removed  the approval is gone from org-state.
#   typed-line        (informational) seconds from `hc send` until the secretary acted on it.
# Paste the whole output back.
set -u

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,43p' "$0"; exit 0 ;;
  *) echo "idle-secretary-wake: unknown argument: $1" >&2; exit 2 ;;
esac

SEC=secretary; WK=w-p140; AID=p140-20261110T000000Z
WAIT_TIMEOUT=${WAIT_TIMEOUT:-60}
SETUP_WAIT=${SETUP_WAIT:-600}
ANSWER_BOUND=${ANSWER_BOUND:-120}
FAILS=0

ROOT=$(pwd)
[ -f "$ROOT/templates/secretary.md" ] && [ -f "$ROOT/scripts/org" ] || { echo "RESULT precondition-failed: run from the repo root"; exit 1; }
for c in hc claude ps; do command -v $c >/dev/null 2>&1 || { echo "RESULT precondition-failed: $c not on PATH"; exit 1; }; done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/probe140.XXXXXX") || exit 1 # private (0700)
XDG="$WORK/xdg"; OUT="$WORK/out"; mkdir -p "$XDG" "$OUT" "$WORK/state" || exit 1
HC_SESSION=p140-$$; export HC_SESSION
XDG_CONFIG_HOME=$XDG; export XDG_CONFIG_HOME
PADDOCK_STATE_DIR=$WORK/state; export PADDOCK_STATE_DIR
PADDOCK_WAIT_TIMEOUT=$WAIT_TIMEOUT; export PADDOCK_WAIT_TIMEOUT
unset PADDOCK_ORG_ID PADDOCK_SECRETARY_NAME

cleanup() {
  for n in $SEC $WK; do hc kill $n >/dev/null 2>&1; hc rm $n >/dev/null 2>&1; done
  hc server stop >/dev/null 2>&1 # HC_SESSION is the temp core's: yours is untouched
  rm -rf "$WORK"
}
trap cleanup EXIT; trap 'exit 130' INT TERM

result() { # result <name> <PASS|FAIL|NO DATA> <detail>
  echo "RESULT $1: $2${3:+ ($3)}"
  [ "$2" = FAIL ] && FAILS=$((FAILS + 1))
  return 0
}
org() { bash "$ROOT/scripts/org" "$@"; }
trust_dialog() { # answer Claude Code's folder-trust dialog (Enter), like probe 117; setup only
  case "$(hc read $SEC 2>/dev/null)" in *"Quick safety check"*|*"trust this folder"*) echo "-- answering the folder-trust dialog"; hc keys $SEC enter >/dev/null 2>&1 ;; esac
}
state_of() { hc get --json "$1" 2>/dev/null | tr -d '\n' | grep -Eo '"status": *\{[^{}]*"state": *"[a-z]*"' | grep -Eo '"[a-z]*"$' | tr -d '"'; }
# wait_pids: top-level `org --as secretary wait` processes of THIS probe's core only: a match
# whose parent is also a match is a subshell of the same call, and the process must carry this
# probe's PADDOCK_STATE_DIR (read from /proc, so Linux/WSL only), so a real secretary's wait
# on the same host is not counted.
wait_pids() {
  ps -eo pid=,ppid=,args= 2>/dev/null | awk '/org --as secretary wait/ && !/awk/ { m[$1] = $2 } END { for (p in m) if (!(m[p] in m)) print p }' \
    | while read -r p; do tr '\0' '\n' 2>/dev/null < "/proc/$p/environ" | grep -qx "PADDOCK_STATE_DIR=$PADDOCK_STATE_DIR" && echo "$p"; done
}

echo "== versions"; hc --version 2>&1; claude --version 2>&1
echo "== temp core session $HC_SESSION; state dir under $WORK; org wait timeout ${WAIT_TIMEOUT}s"
echo "== to look inside (setup only): HC_SESSION=$HC_SESSION hc attach $SEC   (detach again)"

mkdir -p "$XDG/herdr-core/templates" && cp -f "$ROOT/templates/secretary.md" "$XDG/herdr-core/templates/secretary.md" \
  || { result setup FAIL "cannot place the template"; exit 1; }

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"work":[{"task_id":"p140","title":"Probe 140 stand-in task","since":"%s"}],"approvals":[{"id":"%s","task_id":"p140","question":"Probe 140: may the stand-in worker go on?","asked_at":"%s"}]}' "$now" "$AID" "$now" \
  | org --as secretary doc set org-state || { result setup FAIL "cannot write org-state on the temp core"; exit 1; }

echo "== start the stand-in worker $WK"
hc run --bg --name $WK --label task_id=p140 -- sh -c "while :; do bash '$ROOT/scripts/org' --as $WK check_messages >> '$OUT/worker.mail' 2>&1; if grep -q 'Answer to your question ($AID): yes' '$OUT/worker.mail'; then date +%s > '$OUT/worker.got'; exec sleep 3600; fi; sleep 2; done" >/dev/null 2>&1 \
  || { result setup FAIL "cannot start $WK"; exit 1; }

TASK="This is probe 140 of the paddock organization. You are resuming: org-state holds one task in progress (task_id p140; its worker w-p140 is already running, it is not your child) and one approval waiting for the person ($AID). Do not start, kill or remove any terminal, do not delegate, and do not ask the person anything. Follow your template exactly from here."
echo "== start the secretary"
( hc run --bg --keep --name $SEC --cwd "$ROOT" secretary "$TASK" > "$WORK/run.out" 2>&1; echo $? > "$WORK/run.rc" ) &
t=0; while [ ! -f "$WORK/run.rc" ] && [ $t -lt 120 ]; do trust_dialog; t=$((t + 2)); sleep 2; done
out=$(cat "$WORK/run.out" 2>/dev/null); [ "$(cat "$WORK/run.rc" 2>/dev/null)" = 0 ] || { result secretary-start FAIL "hc run failed or hung: $out"; exit 1; }
printf '%s' "$out" | tr -d '\n' | grep -Eq '"sent": *true' && result secretary-start PASS "first_message.sent true" \
  || result secretary-start FAIL "first_message.sent is not true: $out"

echo "== steps 2-3: waiting up to ${SETUP_WAIT}s for the secretary's org wait, twice"
# A second invocation counts only once the first one has ended (a new pid after the first is gone).
t=0; said=0; t_first=; first=; n=0
while [ $t -lt "$SETUP_WAIT" ]; do
  trust_dialog
  cur=$(wait_pids)
  if [ -z "$first" ]; then
    for p in $cur; do first=$p; t_first=$t; n=1; break; done
  elif ! kill -0 "$first" 2>/dev/null; then
    for p in $cur; do [ "$p" != "$first" ] && { n=2; break; }; done
  fi
  [ $n -ge 2 ] && break
  if [ "$(state_of $SEC)" = blocked ] && [ $said -eq 0 ]; then said=1; echo "-- the secretary is blocked on a prompt: answer it with HC_SESSION=$HC_SESSION hc attach $SEC"; fi
  t=$((t + 2)); sleep 2
done
if [ "$n" -ge 1 ]; then result wait-entered PASS "org wait seen ${t_first}s after the start, from the template alone"
else result wait-entered FAIL "no 'org --as secretary wait' process within ${SETUP_WAIT}s"; fi
if [ "$n" -ge 2 ]; then result wait-kept PASS "a second org wait after a check-in, ${t}s after the start"
else result wait-kept FAIL "only $n org wait process(es) seen in ${SETUP_WAIT}s"; fi
echo "-- secretary state now: $(state_of $SEC)"

echo "== step 4: the card's message, nobody types from here"
t=0; while [ -z "$(wait_pids)" ] && [ $t -lt $((WAIT_TIMEOUT + 60)) ]; do t=$((t + 1)); sleep 1; done
echo "-- org wait running: $( [ -n "$(wait_pids)" ] && echo yes || echo no ); secretary state: $(state_of $SEC)"
t_send=$(date +%s)
org --as person send_message $SEC "ANSWER $AID yes" || result card-message FAIL "scripts/org send_message failed"
t=0; while [ ! -f "$OUT/worker.got" ] && [ $t -lt "$ANSWER_BOUND" ]; do t=$((t + 1)); sleep 1; done
if [ -f "$OUT/worker.got" ]; then result answer-reached PASS "the worker had the answer $(( $(cat "$OUT/worker.got") - t_send ))s after the card-style message; nothing was typed"
else result answer-reached FAIL "no answer in the worker's mailbox ${ANSWER_BOUND}s after the card-style message"; fi
sleep 3
doc=$(org --as secretary doc get org-state 2>&1)
case "$doc" in *"$AID"*) result approval-removed FAIL "org-state still holds $AID" ;;
  *'"approvals"'*|*'"work"'*|null) result approval-removed PASS "org-state no longer holds $AID" ;;
  *) result approval-removed NO DATA "cannot read org-state: $doc" ;; esac
echo "-- worker mailbox:"; cat "$OUT/worker.mail" 2>/dev/null | grep -v '^no new messages$'

echo "== step 5 (informational): one typed line while the secretary waits"
t=0; while [ -z "$(wait_pids)" ] && [ $t -lt $((WAIT_TIMEOUT + 60)) ]; do t=$((t + 1)); sleep 1; done
if [ -z "$(wait_pids)" ]; then result typed-line NO DATA "the secretary was not waiting (no org wait) when the line was due"
else
  sleep 3; t_typed=$(date +%s)
  hc send $SEC "Probe 140: run exactly this one command now: date +%s > $OUT/typed.seen  - then go on as your template says." > "$WORK/send.out" 2>&1; src=$?
  if [ $src -ne 0 ]; then result typed-line NO DATA "hc send exited $src: $(cat "$WORK/send.out")"
  else
    t=0; while [ ! -f "$OUT/typed.seen" ] && [ $t -lt $((WAIT_TIMEOUT + 90)) ]; do t=$((t + 1)); sleep 1; done
    if [ -f "$OUT/typed.seen" ]; then result typed-line PASS "acted on $(( $(cat "$OUT/typed.seen") - t_typed ))s after it was typed (org wait timeout ${WAIT_TIMEOUT}s)"
    else result typed-line NO DATA "not acted on within $((WAIT_TIMEOUT + 90))s"; fi
  fi
fi

echo "== screen tail of the secretary (by eye: what did it tell the person about waiting?)"
hc read $SEC 2>&1 | tail -n 30
echo "== hc ls"; hc ls 2>&1
echo "== done; paste everything above back"
[ $FAILS -eq 0 ]
