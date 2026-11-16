#!/usr/bin/env bash
# Acceptance test for decision 0013, stage 1 ("Beside"): org-watch writes worker events into the
# secretary's mailbox as watcher (once per item), wakes an idle or done secretary or worker with
# unread mail (one constant line, never into a working one, never over typed input, once per
# unread batch per PADDOCK_WATCH_WAKE s, every send and skip logged to watcher/woke), and runs one
# ci-watch.sh per open ci_requested record, which always writes ci_completed or ci_watch_failed and
# a mailbox line. It types /reload-plugins once into an idle secretary when watcher/reload-plugins
# exists, and clears it on a Reloaded: line. Stubbed hc and gh; no core, no GitHub.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-watch/scripts/org-watch.sh
ciw=$here/skills/org-watch/scripts/ci-watch.sh
org=$here/scripts/org
tmp=$(mktemp -d)
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# A PATH of its own, so the host's powershell.exe, notify-send, hc and gh never answer.
tools=$tmp/tools; mkdir -p "$tools"
for t in awk sed grep date cut sort cksum tr mkdir rmdir dirname basename cat rm mv cp head tail env printenv wc od sleep touch tee uniq expr test timeout ls mktemp; do
  p=$(command -v "$t" 2>/dev/null) && [ -x "$p" ] && ln -sf "$p" "$tools/$t"
done
ln -sf "$(command -v bash)" "$tools/bash"
# hc: ls/get from $STUB/t-<name> ($STUB/after-<name> once the screen was read), read from $STUB/screen-<name>, doc from $STUB/doc. send
# honours --if idle (exit 10 when the status is not idle); a delivered send goes to $STUB/sent.
cat > "$tools/hc" <<'EOF'
#!/bin/sh
echo "$*" >> "$STUB/calls"
cmd=$1; shift
case "$cmd" in
  ls) first=1; printf '['
      for f in "$STUB"/t-*; do [ -e "$f" ] || continue
        [ -n "$first" ] || printf ','; first=; printf '{"name":"%s"}' "${f##*/t-}"; done
      printf ']\n' ;;
  get) n=; for a in "$@"; do case "$a" in --*) ;; *) n=$a ;; esac; done
       [ -f "$STUB/t-$n" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       # after the wake's screen read (since calls was last cleared), $STUB/after-<name> answers: it moved
       if [ -f "$STUB/after-$n" ] && grep -qx "read $n" "$STUB/calls"; then cat "$STUB/after-$n"; else cat "$STUB/t-$n"; fi ;;
  read) [ -z "${STUB_READ_FAIL:-}" ] || exit 1; n=; for a in "$@"; do n=$a; done; cat "$STUB/screen-$n" 2>/dev/null ;;
  send) cond=; [ "$1" != --if ] || { cond=$2; shift 2; }
        [ -f "$STUB/t-$1" ] || exit 1
        if [ -n "$cond" ] && ! grep -q "\"state\":\"$cond\"" "$STUB/t-$1"; then exit 10; fi
        printf '%s\t%s\n' "$1" "$2" >> "$STUB/sent" ;;
  connect) cat >/dev/null; cat "$STUB/doc" 2>/dev/null \
             || echo '{"jsonrpc":"2.0","id":1,"result":{"value":null,"version":0}}' ;;
esac
exit 0
EOF
# gh: the runs of the head are lines "<id> <status> <event> <final conclusion>" in $STUB/runs
# (default: 777, in_progress, push, STUB_CONCL or success). run list prints them as ci-watch's --jq
# does, the conclusion empty until completed (STUB_RUN_NONE=1: nothing; STUB_LIST_FAIL=1: exit 1;
# STUB_RELIST_FAIL=1: exit 1 from the second list on). run watch <id> waits while $STUB/hold or
# $STUB/hold-<id> exists (at most 60 s), marks the run completed, then exits STUB_WATCH_CODE.
cat > "$tools/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >> "$STUB/calls"
[ -f "$STUB/runs" ] || echo "777 in_progress push ${STUB_CONCL:-success}" > "$STUB/runs"
case "$1 $2" in
  "run list") [ -z "${STUB_LIST_FAIL:-}" ] || { echo 'gh: HTTP 502' >&2; exit 1; }
    echo x >> "$STUB/lists"
    [ -z "${STUB_RELIST_FAIL:-}" ] || [ "$(wc -l < "$STUB/lists")" -lt 2 ] || { echo 'gh: HTTP 502' >&2; exit 1; }
    [ -n "${STUB_RUN_NONE:-}" ] || awk '{ print $1, $2, $3, ($2 == "completed" ? $4 : "") }' "$STUB/runs" ;;
  "run watch") i=0; while { [ -e "$STUB/hold" ] || [ -e "$STUB/hold-$3" ]; } && [ $i -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
    awk -v id="$3" '$1 == id { $2 = "completed" } { print }' "$STUB/runs" > "$STUB/runs.$$" && mv "$STUB/runs.$$" "$STUB/runs"
    exit "${STUB_WATCH_CODE:-0}" ;;
esac
exit 0
EOF
chmod +x "$tools/hc" "$tools/gh"
# Every pass runs holding a shared flock on $tmp/live as fd 9, which each ci-watch it starts (and
# their gh stubs) inherit: settle takes it exclusively, so it returns once every one has ended.
# No fixed sleep stands in for "the watch is done" or "the watch has started".
: > "$tmp/live"
trap 'rm -f "$tmp/stub/hold" "$tmp/stub"/hold-*; flock -x -w 60 "$tmp/live" true; rm -rf "$tmp"' EXIT

T0=1800000000
NOW=2027-01-15T01:00:00Z; MON=2027-01
reset() {
  rm -f "$tmp/stub/hold" "$tmp/stub"/hold-*; settle
  rm -rf "$tmp/stub" "$tmp/state"; mkdir -p "$tmp/stub" "$tmp/state"; : > "$tmp/stub/calls"
  doc '[]'
}
doc() { # doc <work-array-json>
  printf '{"jsonrpc":"2.0","id":1,"result":{"value":{"work":%s,"approvals":[]},"version":3}}\n' "$1" > "$tmp/stub/doc"
}
term() { # term <name> <label|-> <state|none>
  local lab='{}' st
  [ "$2" = - ] || lab="{\"task_id\":\"$2\"}"
  st="{\"app\":\"claude-code\",\"state\":\"$3\"}"; [ "$3" != none ] || st=null
  printf '{\n  "name": "%s",\n  "state": "live",\n  "labels": %s,\n  "status": %s,\n  "status_ms": %s,\n  "turn": 1,\n  "created_ms": %s\n}\n' \
    "$1" "$lab" "$st" $((T0*1000)) $((T0*1000)) > "$tmp/stub/t-$1"
  [ -e "$tmp/stub/screen-$1" ] || hostscreen "$1" ''
}
screen() { printf '%s\n' "$2" > "$tmp/stub/screen-$1"; }
# hostscreen <name> <typed>: the tail of a Claude Code screen as measured on the host (#396):
# rule, "❯" + NBSP + typed text, rule, then the status bar as the last line
NB=$(printf '\302\240'); RULE='────────────────────'
hostscreen() { screen "$1" "$(printf 'output\n%s\n❯%s%s\n%s\n  ⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt' "$RULE" "$NB" "$2" "$RULE")"; }
E=(PATH="$tools" HOME="$tmp" STUB="$tmp/stub" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_NOW="$NOW"
   PADDOCK_HC_HOLD=0 PADDOCK_NUDGE_RETRY=0 PADDOCK_RUN_TRIES=2 PADDOCK_RUN_SLEEP=0)
pass() { # pass <epoch> [env...]
  local now=$1; shift
  out=$({ flock -s 9; env -i "${E[@]}" PADDOCK_WATCH_NOW="$now" "$@" bash "$script" --once; } 9>>"$tmp/live" 2>&1); rc=$?
}
# o <id> <args>: the real org, with no hc on PATH (so the test's own writes nudge nobody)
o() { local who=$1; shift; env -i PATH="$tmp/nohc" HOME="$tmp" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_NOW="$NOW" "$BASH" "$org" --as "$who" "$@"; }
mkdir -p "$tmp/nohc"; for f in "$tools"/*; do case "${f##*/}" in hc|gh) ;; *) cp -P "$f" "$tmp/nohc/" ;; esac; done
sent() { grep -c "^$1	" "$tmp/stub/sent" 2>/dev/null || echo 0; }
woke() { cat "$tmp/state/watcher/woke" 2>/dev/null; }
wev() { cat "$tmp/state/events/$MON/watcher.jsonl" 2>/dev/null; }
unread() { o "$1" check_messages --peek; }
settle() { # wait until every ci-watch the passes started has ended; 60 s at most, then a failed check
  flock -x -w 60 "$tmp/live" true || check "settle: every ci-watch ended within 60 s" 1
}
# wait_for <command...>: until it succeeds, polled every 0.1 s; 60 s at most, then a failed check
wait_for() {
  local i=0; until "$@"; do [ $i -lt 600 ] || { check "wait_for $*: true within 60 s" 1; return 1; }; sleep 0.1; i=$((i + 1)); done
}
watching() { grep -q "^gh run watch $1 --repo ${2:-o/r} " "$tmp/stub/calls"; }   # ci-watch has its traps and is in gh run watch
SECLINE='You have mail: run bash "$PADDOCK_HOME/scripts/org" --as secretary check_messages and act on it.'

bash -n "$ciw"; check "ci-watch.sh parses" $?
bash "$ciw" --help 2>&1 | grep -q -- '--fail'; check "ci-watch.sh --help names --fail" $?

# --- the wake ---
reset; term secretary - idle; o person send_message secretary "hello" >/dev/null
pass $T0
[ "$rc" -eq 0 ] && [ "$(sent secretary)" -eq 1 ] && grep -qF "$SECLINE" "$tmp/stub/sent"; check "idle secretary with unread mail: one wake, the constant line ($out)" $?
grep -q '^send --if idle secretary ' "$tmp/stub/calls"; check "an idle target is sent with --if idle" $?
woke | grep -q "	wake	secretary	person#1	idle	no	0$"; check "the wake is logged in watcher/woke (target, batch, status, input, rc)" $?
pass $((T0 + 30))
[ "$(sent secretary)" -eq 1 ] && woke | grep -q "	skip	secretary	person#1	-	-	rate$"; check "same batch within PADDOCK_WATCH_WAKE: no second wake, the skip is logged" $?
pass $((T0 + 60))
[ "$(sent secretary)" -eq 2 ]; check "same batch still unread after PADDOCK_WATCH_WAKE s: woken again" $?
o person send_message secretary "more" >/dev/null; pass $((T0 + 70))
[ "$(sent secretary)" -eq 3 ] && woke | grep -q "	wake	secretary	person#2	"; check "new mail is a new batch: woken on the next pass" $?
o secretary check_messages >/dev/null; pass $((T0 + 200))
[ "$(sent secretary)" -eq 3 ]; check "no unread mail: no wake" $?
reset; term secretary - idle; o person send_message secretary "x" >/dev/null; pass $T0 PADDOCK_WATCH_WAKE=5; pass $((T0 + 5)) PADDOCK_WATCH_WAKE=5
[ "$(sent secretary)" -eq 2 ]; check "PADDOCK_WATCH_WAKE sets the rate limit" $?

reset; term secretary - done; o person send_message secretary "hello" >/dev/null; pass $T0
[ "$(sent secretary)" -eq 1 ] && grep -q '^send secretary ' "$tmp/stub/calls" && woke | grep -q '	wake	secretary	person#1	done	no	0$'; check "done secretary: woken with a plain send (hc has no --if done)" $?

# done, then moved before the send (the last get): no send, skip moved, retried next pass
reset; term secretary - done; o person send_message secretary "hello" >/dev/null
sed 's/"state":"done"/"state":"working"/' "$tmp/stub/t-secretary" > "$tmp/stub/after-secretary"; pass $T0
[ "$(sent secretary)" -eq 0 ] && woke | grep -q '	skip	secretary	person#1	working	moved	-$'; check "done, working at the last get: no send, skip moved" $?
: > "$tmp/stub/calls"; sed 's/"turn": 1/"turn": 2/' "$tmp/stub/t-secretary" > "$tmp/stub/after-secretary"; pass $((T0 + 30))
[ "$(sent secretary)" -eq 0 ] && woke | grep -q '	skip	secretary	person#1	done	moved	-$'; check "done, turn moved at the last get: no send, skip moved" $?
rm "$tmp/stub/after-secretary"; pass $((T0 + 45))
[ "$(sent secretary)" -eq 1 ] && [ "$(grep -c '^get --json secretary' "$tmp/stub/calls")" -ge 2 ]; check "done and unchanged at the last get: woken (no ledger entry from the skips)" $?

for st in working blocked none; do
  reset; term secretary - "$st"; o person send_message secretary "hello" >/dev/null; pass $T0
  [ "$(sent secretary)" -eq 0 ] && ! grep -q '^send' "$tmp/stub/calls"; check "$st secretary: no send at all" $?
done
woke | grep -q '	skip	secretary	person#1	none	-	-$'; check "a skip for the status is logged with the status read" $?
reset; term secretary - working; o person send_message secretary "hello" >/dev/null; pass $T0
woke | grep -q '	skip	secretary	person#1	working	-	-$'; check "working: the skip is logged as working" $?
term secretary - idle; pass $((T0 + 30))
[ "$(sent secretary)" -eq 1 ]; check "mail written during a working turn is woken on the first pass after it" $?

reset; term secretary - idle; screen secretary '❯ half a sentence'; o person send_message secretary "hello" >/dev/null; pass $T0
[ "$(sent secretary)" -eq 0 ] && woke | grep -q '	skip	secretary	person#1	idle	yes	-$'; check "typed input on the last screen line: no wake, skip logged" $?
grep -q '^read secretary' "$tmp/stub/calls"; check "the input check reads the whole screen" $?
screen secretary '│ > also typed  │'; pass $((T0 + 30))
[ "$(sent secretary)" -eq 0 ]; check "typed input inside a box with > is held off too" $?
screen secretary '❯ '; pass $((T0 + 45)) STUB_READ_FAIL=1
[ "$(sent secretary)" -eq 0 ] && woke | grep -q '	skip	secretary	person#1	idle	unreadable	-$'; check "a screen that cannot be read: no wake (fail closed), skip logged" $?
pass $((T0 + 60))
[ "$(sent secretary)" -eq 1 ]; check "once the line is cleared, the next pass wakes" $?
# the host's screen (#396): the prompt line is above a rule and the status bar, with NBSP
reset; term secretary - idle; hostscreen secretary 'half a sentence'; o person send_message secretary "hello" >/dev/null; pass $T0
[ "$(sent secretary)" -eq 0 ] && woke | grep -q '	skip	secretary	person#1	idle	yes	-$'; check "host screen, text after ❯ NBSP: no wake, typed yes" $?
pass $((T0 + 30)) LC_ALL=C
[ "$(sent secretary)" -eq 0 ]; check "host screen, typed text, C locale: no wake" $?
hostscreen secretary ''; pass $((T0 + 45)) LC_ALL=C
[ "$(sent secretary)" -eq 1 ] && woke | grep -q '	wake	secretary	person#1	idle	no	0$'; check "host screen, empty ❯ NBSP prompt (C locale): woken" $?
reset; term secretary - idle; screen secretary "$(printf 'output\n  ⏵⏵ auto mode on')"; o person send_message secretary "hello" >/dev/null; pass $T0
[ "$(sent secretary)" -eq 0 ] && woke | grep -q '	skip	secretary	person#1	idle	noprompt	-$'; check "a screen with no prompt line: no wake, skip noprompt" $?

reset; term secretary - working; term w-t1 t1 idle; o secretary send_message w-t1 "your answer" >/dev/null; pass $T0
[ "$(sent w-t1)" -eq 1 ] && grep -qF 'You have mail: run bash "$PADDOCK_ORG" --as w-t1 check_messages and act on it.' "$tmp/stub/sent"; check "idle worker with unread mail: woken with its own constant line" $?
term w-t1 t1 working; o secretary send_message w-t1 "more" >/dev/null; pass $((T0 + 30))
[ "$(sent w-t1)" -eq 1 ]; check "working worker: not woken" $?
reset; term secretary - idle; o secretary send_message w-gone "x" >/dev/null; pass $T0
! grep -q 'w-gone' "$tmp/stub/calls"; check "a worker with no live terminal is not woken" $?

# --- worker events, once per item ---
reset; term secretary - working; term w-t1 t1 blocked; pass $T0
unread secretary | grep -q '^w-t1 is blocked$' && unread secretary | grep -q '^\[watcher#'; check "blocked worker: a line in the secretary's mailbox from watcher" $?
pass $((T0 + 30)); pass $((T0 + 3600))
[ "$(unread secretary | grep -c 'is blocked')" -eq 1 ]; check "blocked: written once while it holds" $?
woke | grep -q '	mail	secretary	mail:blocked:w-t1	-	-	0$'; check "the mailbox line is logged in watcher/woke" $?
term w-t1 t1 working; pass $((T0 + 3630)); term w-t1 t1 blocked; pass $((T0 + 3660))
[ "$(unread secretary | grep -c 'is blocked')" -eq 2 ]; check "blocked again after it cleared: a new line" $?

reset; term secretary - working
doc '[{"task_id":"t2","title":"x"},{"task_id":"t3","title":"y"},{"task_id":"t4","title":"z"}]'
term w-t2 t2 done
o secretary report start --task t2 "go" >/dev/null 2>&1   # the secretary's start record (as org-delegate writes)
o w-t4 report done --task t4 "finished" >/dev/null   # t4 closed: no terminal, but its done record is in
pass $T0; pass $((T0 + 30))
! unread secretary | grep -q '^w-t2 is done'; check "done with no report for less than N minutes: no line (Issue #442)" $?
pass $((T0 + 600)); pass $((T0 + 630))
[ "$(unread secretary | grep -c '^w-t2 is done and sent no report$')" -eq 1 ]; check "done unchanged for N minutes: exactly one line" $?
[ "$(unread secretary | grep -c '^w-t3 has no terminal and sent no done report$')" -eq 1 ]; check "gone (no terminal, no done record): one line" $?
! unread secretary | grep -q '^w-t4 has no terminal'; check "a task with its done record is not reported gone" $?
# done, then working, then done again (a new turn, a new status_ms): the N minutes start again
reset; term secretary - working; doc '[{"task_id":"t6","title":"x"}]'; o secretary report start --task t6 "go" >/dev/null 2>&1
term w-t6 t6 done; pass $((T0 + 300))
term w-t6 t6 working; pass $((T0 + 360))
term w-t6 t6 done; sed -i "s/\"status_ms\": [0-9]*/\"status_ms\": $(((T0 + 420) * 1000))/; s/\"turn\": 1/\"turn\": 2/" "$tmp/stub/t-w-t6"
pass $((T0 + 600)); pass $((T0 + 1000))
! unread secretary | grep -q '^w-t6 is done'; check "done, working, done again: the N minutes restart (no line before them)" $?
pass $((T0 + 1020))
[ "$(unread secretary | grep -c '^w-t6 is done and sent no report$')" -eq 1 ]; check "done again and held N minutes: one line" $?
reset; term secretary - working; term w-t5 t5 none; pass $T0; pass $((T0 + 600)); pass $((T0 + 630))
[ "$(unread secretary | grep -c '^w-t5 has reported no status for 10 minutes$')" -eq 1 ]; check "no status for N minutes: one line" $?

# the watcher's own writes fire no per-write nudge: only its guarded wake types (typed input here)
reset; term secretary - idle; term w-t1 t1 blocked; screen secretary '❯ typing'; pass $T0
unread secretary | grep -q '^w-t1 is blocked$' && ! grep -q '^send' "$tmp/stub/calls"; check "a watcher mailbox line over typed input: no send at all (no nudge)" $?

# work_check is the same check as wait's (moved, not copied)
reset; doc '[{"task_id":"t3","title":"y"}]'
r=$(env -i PATH="$tools" HOME="$tmp" STUB="$tmp/stub" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_HC_HOLD=0 bash "$org" --as watcher work_check)
[ "$r" = '{"gone":["t3"]}' ]; check "org work_check as watcher prints wait's members ($r)" $?
r=$(env -i PATH="$tools" HOME="$tmp" STUB="$tmp/stub" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_HC_HOLD=0 bash "$org" --as w-t1 work_check)
[ "$r" = '{}' ]; check "a worker's work_check reads nothing (Issue #281)" $?

# --- CI ---
SHA=0123456789abcdef0123456789abcdef01234567; SHA7=0123456; SHB=fedcba9876543210fedcba9876543210fedcba98
req() { o secretary ci_requested --pr "${1:-42}" --sha "${2:-$SHA}" --repo o/r --task t1 >/dev/null; }
reset; term secretary - working; req
grep -q '"kind":"ci_requested","from":"secretary","task_id":"t1","pr":42,"sha":"'$SHA'","repo":"o/r"' "$tmp/state/events/$MON/secretary.jsonl"; check "org ci_requested writes the record of 0013" $?
pass $T0; settle
l=$(wev | grep ci_completed)
grep -q '"from":"watcher","task_id":"t1","pr":42,"sha":"'$SHA'","repo":"o/r","run_id":777,"exit_code":0,"conclusion":"success"' <<<"$l"; check "green run: ci_completed from watcher ($l)" $?
unread secretary | grep -qF "CI success on PR 42, head $SHA7, run 777."; check "green run: the mailbox line" $?
grep -q 'exit_code=0' "$tmp/state/watcher/ci/o_r-42-$SHA7.log"; check "the watch log keeps the exit code and output" $?
grep -q '^gh run watch 777 --repo o/r --exit-status --interval 30' "$tmp/stub/calls"; check "the run is watched with gh run watch --exit-status --interval 30" $?
term secretary - idle; pass $((T0 + 30)); settle
[ "$(wev | grep -c '"kind":"ci_')" -eq 1 ] && [ "$(sent secretary)" -eq 1 ]; check "a closed request is not watched again; the secretary is woken for the line" $?
reset; term secretary - working; req; pass $T0 STUB_CONCL=failure STUB_WATCH_CODE=1; settle
wev | grep -q '"kind":"ci_completed".*"exit_code":1,"conclusion":"failure"' && unread secretary | grep -q "CI failure on PR 42"; check "red run: ci_completed failure" $?
reset; term secretary - working
printf '{"seq":1,"ts":"%s","kind":"ci_completed","from":"secretary","pr":42,"sha":"%s","run_id":1,"exit_code":0,"conclusion":"success"}\n' "$NOW" "$SHA" > "$tmp/ci.line"
req; cat "$tmp/ci.line" >> "$tmp/state/events/$MON/secretary.jsonl"; pass $T0; settle
wev | grep -q '"kind":"ci_completed"'; check "stage 1: the skill's own ci_completed does not close the watcher's request" $?

reset; term secretary - working; mkdir -p "$tmp/state/events/2027-02" "$tmp/state/events/2026-12"
env -i PATH="$tmp/nohc" HOME="$tmp" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_NOW=2026-12-31T23:00:00Z "$BASH" "$org" --as secretary ci_requested --pr 7 --sha "$SHA" --repo o/r >/dev/null
: > "$tmp/state/events/2027-02/secretary.jsonl"; pass $T0; settle
wev | grep -q '"kind":"ci_completed".*"pr":7,'; check "a request from last month is watched although next month's folder exists" $?
failcase() { # failcase <reason> <env...>
  local r=$1; shift
  reset; term secretary - working; req; pass $T0 "$@"; settle
  l=$(wev | grep ci_watch_failed)
  grep -q "\"from\":\"watcher\",\"task_id\":\"t1\",\"pr\":42,\"sha\":\"$SHA\",\"repo\":\"o/r\".*\"reason\":\"$r\"" <<<"$l" && grep -q "\"log\":\"$tmp/state/watcher/ci/o_r-42-$SHA7.log\"" <<<"$l" \
    && [ "$(wev | grep -c '"kind":"ci_')" -eq 1 ]; check "$r: one ci_watch_failed record ($l)" $?
  unread secretary | grep -qF "CI watch failed on PR 42, head $SHA7: $r (log $tmp/state/watcher/ci/o_r-42-$SHA7.log)."; check "$r: the mailbox line" $?
}
failcase no_run STUB_RUN_NONE=1
failcase gh_error STUB_LIST_FAIL=1
grep -q '"exit_code":1' <<<"$l"; check "gh_error keeps gh's exit code" $?
failcase gh_error STUB_RELIST_FAIL=1
reset; term secretary - working; req; touch "$tmp/stub/hold"; pass $T0; wait_for watching 777
read -r pid _ < "$tmp/state/watcher/ci/o_r-42.pid"; kill -TERM "$pid"; rm -f "$tmp/stub/hold"; settle
l=$(wev | grep ci_watch_failed); grep -q '"reason":"signal","exit_code":143' <<<"$l"; check "signal (TERM): ci_watch_failed with reason signal ($l)" $?
unread secretary | grep -q "CI watch failed on PR 42, head $SHA7: signal"; check "signal: the mailbox line" $?
reset; term secretary - working; req; touch "$tmp/stub/hold"; pass $T0; wait_for watching 777
read -r pid _ < "$tmp/state/watcher/ci/o_r-42.pid"; kill -KILL "$pid"
gone() { ! tr '\0' ' ' 2>/dev/null < "/proc/$1/cmdline" | grep -q 'ci-watch\.sh'; }; wait_for gone "$pid"
pass $((T0 + 30))
l=$(wev | grep ci_watch_failed); grep -q '"reason":"vanished","exit_code":null' <<<"$l" && [ "$(wev | grep -c ci_watch_failed)" -eq 1 ]; check "a watch killed with no trap: vanished on the next pass ($l)" $?
unread secretary | grep -q "CI watch failed on PR 42, head $SHA7: vanished"; check "vanished: the mailbox line" $?
rm -f "$tmp/stub/hold"; pass $((T0 + 60)); settle
[ "$(wev | grep -c '"kind":"ci_')" -eq 1 ]; check "a vanished request is closed: not watched again" $?
# a recorded pid that is now another process (a restart) is not taken for the watch, nor signalled
reset; term secretary - working; req; sleep 30 >/dev/null 2>&1 & other=$!
mkdir -p "$tmp/state/watcher/ci"; printf '%s %s o/r 42\n' "$other" "$SHA" > "$tmp/state/watcher/ci/o_r-42.pid"
req 42 "$SHB"; pass $T0; settle
kill -0 "$other" 2>/dev/null && wev | grep -q "\"sha\":\"$SHA\".*\"reason\":\"vanished\""; check "a pid of another process: the old watch is vanished, that process is not signalled" $?
kill "$other" 2>/dev/null

reset; term secretary - working; req; touch "$tmp/stub/hold"; pass $T0; wait_for watching 777
req 42 "$SHB"; pass $((T0 + 30)); settle   # USR1 ends it; settle waits until its record and line are both written
wev | grep -q "\"sha\":\"$SHA\".*\"reason\":\"superseded\""; check "a newer head of the PR ends the older watch: superseded" $?
unread secretary | grep -q "CI watch failed on PR 42, head $SHA7: superseded"; check "superseded: the mailbox line" $?
rm -f "$tmp/stub/hold"; pass $((T0 + 60)); settle
wev | grep -q "\"kind\":\"ci_completed\".*\"sha\":\"$SHB\".*\"conclusion\":\"success\""; check "the newer head is then watched to its result" $?
[ "$(wev | grep -c '"kind":"ci_')" -eq 2 ]; check "each request has exactly one watcher line" $?
reset; term secretary - working; req; req 42 "$SHB"; pass $T0; settle
wev | grep -q "\"sha\":\"$SHA\".*\"reason\":\"superseded\"" && wev | grep -q "\"sha\":\"$SHB\".*\"conclusion\":\"success\""; check "an older request never watched is written superseded, the newest watched" $?

# the same PR number in two repositories is two PRs (repo + pr + sha)
reset; term secretary - working; touch "$tmp/stub/hold"
req 12 "$SHA"; o secretary ci_requested --pr 12 --sha "$SHB" --repo o/other >/dev/null
pass $T0; wait_for watching 777; wait_for watching 777 o/other
[ -f "$tmp/state/watcher/ci/o_r-12.pid" ] && [ -f "$tmp/state/watcher/ci/o_other-12.pid" ]; check "two repositories, same PR number: two watches, one pid file each" $?
pass $((T0 + 30))
rm -f "$tmp/stub/hold"; settle
! wev | grep -q superseded; check "a request of another repository does not supersede" $?
wev | grep -q "\"sha\":\"$SHA\",\"repo\":\"o/r\".*\"conclusion\":\"success\"" && wev | grep -q "\"sha\":\"$SHB\",\"repo\":\"o/other\".*\"conclusion\":\"success\"" \
  && [ "$(wev | grep -c '"kind":"ci_')" -eq 2 ]; check "each repository's PR gets its own result" $?

# every run of the head (push and pull_request): no result while one has not ended; all green is
# success, one red is failure; the line names the runs it read (Issue #415)
reset; term secretary - working; req
printf '777 completed push success\n778 in_progress pull_request success\n' > "$tmp/stub/runs"; touch "$tmp/stub/hold-778"
pass $T0; wait_for watching 778
! wev | grep -q '"kind":"ci_' && ! grep -q '^gh run watch 777 ' "$tmp/stub/calls"; check "two runs, one pending: nothing recorded while it runs" $?
rm -f "$tmp/stub/hold-778"; settle
wev | grep -q '"kind":"ci_completed".*"run_id":777,"exit_code":0,"conclusion":"success"' && [ "$(wev | grep -c '"kind":"ci_')" -eq 1 ]; check "two runs, both green once the second ends: success" $?
unread secretary | grep -qF "CI success on PR 42, head $SHA7, run 777. Runs read: 777 push success, 778 pull_request success."; check "the success line names both runs it read" $?
reset; term secretary - working; req
printf '777 completed push success\n778 in_progress pull_request failure\n' > "$tmp/stub/runs"; touch "$tmp/stub/hold-778"
pass $T0; wait_for watching 778
! wev | grep -q '"kind":"ci_'; check "a run that will fail, still pending: nothing recorded yet" $?
rm -f "$tmp/stub/hold-778"; settle
wev | grep -q '"kind":"ci_completed".*"run_id":778,"exit_code":1,"conclusion":"failure"'; check "one red run of two: failure, its run named" $?
unread secretary | grep -qF "CI failure on PR 42, head $SHA7, run 778. Runs read: 777 push success, 778 pull_request failure."; check "the failure line names both runs" $?
reset; term secretary - working; req
printf '777 in_progress push failure\n778 in_progress pull_request success\n' > "$tmp/stub/runs"; touch "$tmp/stub/hold-778"
pass $T0; wait_for watching 778
! wev | grep -q '"kind":"ci_'; check "the first run red, the second still pending: not reported until both end" $?
rm -f "$tmp/stub/hold-778"; settle
wev | grep -q '"kind":"ci_completed".*"run_id":777,"exit_code":1,"conclusion":"failure"'; check "then failure, the red run named" $?


# --- /reload-plugins after a landing that changed a SKILL.md (org-start leaves watcher/reload-plugins) ---
mark_reload() { mkdir -p "$tmp/state/watcher"; : > "$tmp/state/watcher/reload-plugins"; }
reloads() { grep -c "^secretary	/reload-plugins$" "$tmp/stub/sent" 2>/dev/null || echo 0; }
RLD=$tmp/state/watcher/reload-plugins
reset; term secretary - idle; pass $T0
[ "$(reloads)" -eq 0 ]; check "no marker: no /reload-plugins" $?
reset; term secretary - idle; mark_reload; o person send_message secretary "hello" >/dev/null; pass $T0
[ "$(reloads)" -eq 1 ] && [ "$(sent secretary)" -eq 1 ] && grep -q '^send --if idle secretary /reload-plugins$' "$tmp/stub/calls"
check "marker and an idle secretary: exactly one /reload-plugins (--if idle), no wake in the same pass" $?
[ "$(cat "$RLD-sent")" = "$T0 " ] && woke | grep -q "	reload	secretary	reload-plugins	idle	no	0$"; check "the marker holds the send time; the send is logged" $?
pass $((T0 + 30))
[ "$(reloads)" -eq 1 ] && [ -f "$RLD" ]; check "no Reloaded: line yet: not typed again, the marker stays" $?
screen secretary "$(printf '❯ /reload-plugins\n  ⎿  Reloaded: 3 plugins\n❯ ')"; pass $((T0 + 60))
[ ! -e "$RLD" ] && [ "$(reloads)" -eq 1 ] && woke | grep -q '	reloaded	secretary	reload-plugins	'; check "a Reloaded: line below /reload-plugins clears the marker" $?
pass $((T0 + 90))
[ "$(reloads)" -eq 1 ]; check "marker cleared: nothing more is typed" $?
[ -f "$tmp/state/watcher/reload-ready" ]; check "each pass touches watcher/reload-ready (org-start reads it)" $?

reset; term secretary - working; mark_reload; pass $T0
[ "$(reloads)" -eq 0 ] && [ -f "$RLD" ] && [ ! -e "$RLD-sent" ]; check "a busy secretary gets no /reload-plugins; the marker waits" $?
pass $((T0 + 30))
[ "$(reloads)" -eq 0 ]; check "still busy: still nothing" $?
term secretary - idle; pass $((T0 + 60))
[ "$(reloads)" -eq 1 ]; check "once idle: one /reload-plugins" $?
echo second > "$RLD"; pass $((T0 + 90))
[ "$(reloads)" -eq 2 ]; check "a new request id (another landing) after the send: typed once more" $?
screen secretary "$(printf '❯ /reload-plugins\n  ⎿  Reloaded: 3 plugins\n❯ ')"; echo third > "$RLD"; pass $((T0 + 120))
[ "$(cat "$RLD")" = third ] && [ "$(reloads)" -eq 3 ]; check "a Reloaded: line does not remove a newer request; it is typed" $?
pass $((T0 + 150))
[ ! -e "$RLD" ] && [ "$(reloads)" -eq 3 ]; check "then its Reloaded: line removes it" $?
reset; term secretary - idle; hostscreen secretary 'half a sentence'; mark_reload; pass $T0
[ "$(reloads)" -eq 0 ]; check "typed input on the prompt: no /reload-plugins over it" $?

# no confirmation: an old Reloaded: above the last /reload-plugins does not count; after N minutes the person is told
reset; term secretary - idle; screen secretary "$(printf '❯ /reload-plugins\n  ⎿  Reloaded: 2 plugins\n❯ ')"; mark_reload; pass $T0
screen secretary "$(printf '❯ /reload-plugins\n  ⎿  Reloaded: 2 plugins\n❯ /reload-plugins\n❯ ')"; pass $((T0 + 300))
[ -f "$RLD" ] && ! grep -q 'reload not confirmed' <<<"$out"; check "an older Reloaded: line does not confirm; before N minutes nobody is told" $?
pass $((T0 + 600))
grep -q 'Plugin reload not confirmed' <<<"$out" && [ "$(reloads)" -eq 1 ] && [ -f "$RLD" ]; check "N minutes without Reloaded:: the person is told, nothing typed again" $?
pass $((T0 + 630))
! grep -q 'Plugin reload not confirmed' <<<"$out"; check "told once per N minutes" $?

exit "$fail"
