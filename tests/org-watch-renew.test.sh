#!/usr/bin/env bash
# Acceptance test for the watcher-run secretary renewal: scripts/org renew_secretary leaves
# watcher/renew-secretary; org-watch runs the real secretary-handover.sh once the secretary is idle
# (or done) with no typed input, clears the marker on exit 0 or 9, keeps it on another exit and tells
# the person once, and never runs it for a busy secretary. Stubbed hc; no core.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-watch/scripts/org-watch.sh
org=$here/scripts/org
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# A PATH of its own, so the host's powershell.exe, notify-send and hc never answer.
tools=$tmp/tools; mkdir -p "$tools"
for t in awk sed grep date cut sort cksum tr mkdir rmdir dirname basename cat rm mv cp head tail env printenv wc od sleep touch tee uniq expr test timeout ls mktemp find; do
  p=$(command -v "$t" 2>/dev/null) && [ -x "$p" ] && ln -sf "$p" "$tools/$t"
done
ln -sf "$(command -v bash)" "$tools/bash"
# hc: get from $STUB/t-<name>, read from $STUB/screen-<name>; connect answers $STUB/handover for a
# secretary-handover request (null when missing), else $STUB/doc; run makes an idle terminal.
cat > "$tools/hc" <<'EOF'
#!/bin/sh
echo "$*" >> "$STUB/calls"
cmd=$1; shift
n=; for a in "$@"; do case "$a" in --*) ;; *) [ -n "$n" ] || n=$a ;; esac; done
case "$cmd" in
  ls) printf '[]\n' ;;
  get) [ -f "$STUB/t-$n" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }; cat "$STUB/t-$n" ;;
  read) cat "$STUB/screen-secretary" 2>/dev/null ;;
  connect) req=$(cat)
    case "$req" in *secretary-handover*) cat "$STUB/handover" 2>/dev/null \
      || echo '{"jsonrpc":"2.0","id":1,"result":{"value":null,"version":0}}' ;;
    *) echo '{"jsonrpc":"2.0","id":1,"result":{"value":{"work":[],"approvals":[]},"version":3}}' ;; esac ;;
  kill) [ -f "$STUB/t-$n" ] ;;
  rm) rm -f "$STUB/t-$n" ;;
  run) for a in "$@"; do [ "${nx:-}" = 1 ] && { nm=$a; nx=; }; [ "$a" = --name ] && nx=1; done
       echo "$nm" >> "$STUB/runs"
       printf '{"name":"%s","state":"live","status":{"app":"claude-code","state":"idle"},"status_ms":1,"turn":0}\n' "$nm" > "$STUB/t-$nm"
       echo '{"first_message":{"sent":true,"started":true,"turn":0}}' ;;
  send) echo "$*" >> "$STUB/sent" ;;
esac
exit 0
EOF
chmod +x "$tools/hc"

T0=1800000000
M=$tmp/state/watcher/renew-secretary
reset() { # reset <state>: a secretary terminal in <state>, the rules placed, a handover document
  rm -rf "$tmp/stub" "$tmp/state" "$tmp/bin"; mkdir -p "$tmp/stub" "$tmp/state/secretary" "$tmp/bin"
  : > "$tmp/stub/calls"
  : > "$tmp/state/secretary/AGENTS.md"; echo @AGENTS.md > "$tmp/state/secretary/CLAUDE.md"
  echo "$here" > "$tmp/bin/paddock-home"
  printf '{"name":"secretary","state":"live","status":{"app":"claude-code","state":"%s"},"status_ms":5,"turn":3}\n' "$1" > "$tmp/stub/t-secretary"
  printf 'output\n❯ \n' > "$tmp/stub/screen-secretary"
  echo '{"jsonrpc":"2.0","id":1,"result":{"value":{"written_at":"2026-11-10T01:00:00Z","last_exchange":"x"},"version":3}}' > "$tmp/stub/handover"
}
E=(PATH="$tools" HOME="$tmp" STUB="$tmp/stub" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_BIN_DIR="$tmp/bin" PADDOCK_HC_HOLD=0)
pass() { local now=$1; shift; out=$(env -i "${E[@]}" PADDOCK_WATCH_NOW="$now" "$@" bash "$script" --once 2>&1); rc=$?; }
o() { env -i "${E[@]}" "$@"; }
runs() { grep -c . "$tmp/stub/runs" 2>/dev/null || echo 0; }
woke() { cat "$tmp/state/watcher/woke" 2>/dev/null; }

# the marker command
reset idle
o bash "$org" --as w-x renew_secretary >/dev/null 2>&1; [ $? -eq 7 ] && [ ! -e "$M" ]; check "renew_secretary: only the secretary (exit 7, no marker)" $?
r=$(o bash "$org" --as secretary renew_secretary); [ -s "$M" ] && grep -q 'no watcher' <<<"$r"; check "renew_secretary leaves a request id; with no watcher seen it says to ask the person" $?
id1=$(cat "$M"); o bash "$org" --as secretary renew_secretary >/dev/null; [ "$(cat "$M")" != "$id1" ]; check "each request is a new id" $?

# no marker: nothing
reset idle; pass $T0
[ "$rc" -eq 0 ] && [ "$(runs)" -eq 0 ] && ! grep -q '^kill' "$tmp/stub/calls"; check "no marker: the script is not run" $?
r=$(o bash "$org" --as secretary renew_secretary); grep -q 'end your turn' <<<"$r"; check "after a watcher pass, renew_secretary says the watcher runs it" $?

# marker + idle: run once, marker cleared
reset idle; o bash "$org" --as secretary renew_secretary >/dev/null; pass $T0
[ "$rc" -eq 0 ] && [ "$(runs)" -eq 1 ] && [ ! -e "$M" ] && grep -q '^kill secretary' "$tmp/stub/calls"; check "marker and an idle secretary: the script runs once, the marker is cleared ($out)" $?
woke | grep -q '	renew	secretary	renew-secretary	idle	no	0$'; check "the run is logged in watcher/woke" $?
! grep -q '^send' "$tmp/stub/calls"; check "nothing is typed into the secretary" $?
pass $((T0 + 30)); [ "$(runs)" -eq 1 ]; check "one renewal per marker" $?

# marker + done (unchanged at the last get): run
reset done; o bash "$org" --as secretary renew_secretary >/dev/null; pass $T0
[ "$(runs)" -eq 1 ] && [ ! -e "$M" ]; check "a done secretary (same turn at the last get) is renewed" $?

# marker + working / blocked / typed input: not run
for st in working blocked; do
  reset "$st"; o bash "$org" --as secretary renew_secretary >/dev/null; pass $T0
  [ "$(runs)" -eq 0 ] && [ -f "$M" ] && ! grep -q '^kill' "$tmp/stub/calls"; check "marker and a $st secretary: not run, the marker waits" $?
done
reset idle; printf '❯ half typed\n' > "$tmp/stub/screen-secretary"; o bash "$org" --as secretary renew_secretary >/dev/null; pass $T0
[ "$(runs)" -eq 0 ] && [ -f "$M" ]; check "typed input on the prompt: not run" $?
printf '❯ \n' > "$tmp/stub/screen-secretary"; pass $((T0 + 30))
[ "$(runs)" -eq 1 ] && [ ! -e "$M" ]; check "once the prompt is clear: run" $?

# the script fails (rules not placed, exit 12): marker kept, the person told once, not run again
reset idle; rm "$tmp/state/secretary/AGENTS.md"; o bash "$org" --as secretary renew_secretary >/dev/null; pass $T0
[ -f "$M" ] && grep -q 'Secretary renewal failed (exit 12)' <<<"$out" && grep -q 'not placed' <<<"$out" && ! grep -q '^kill' "$tmp/stub/calls"
check "script fails: the marker is kept, the person is told with the exit code and the script's line" $?
: > "$tmp/stub/calls"; pass $((T0 + 30))
! grep -q 'renewal failed' <<<"$out" && ! grep -q '^read secretary' "$tmp/stub/calls" && woke | grep -c '	renew	' | grep -qx 1
check "the failed request is not run again, nor told again before N minutes" $?
pass $((T0 + 630)); grep -q 'Secretary renewal failed (exit 12)' <<<"$out"; check "told again after N minutes while the marker holds" $?
: > "$tmp/state/secretary/AGENTS.md"; o bash "$org" --as secretary renew_secretary >/dev/null; pass $((T0 + 660))
[ "$(runs)" -eq 1 ] && [ ! -e "$M" ]; check "a new request id after a failure is run" $?

# the script run from inside an agent refuses (exit 4): the check still holds for the watcher
reset idle; o bash "$org" --as secretary renew_secretary >/dev/null; pass $T0 CLAUDECODE=1
[ -f "$M" ] && grep -q 'exit 4' <<<"$out" && [ "$(runs)" -eq 0 ]; check "a watcher with agent variables: the script refuses (exit 4), marker kept, person told" $?

# no handover document (exit 9): cleared and reported
reset idle; rm "$tmp/stub/handover"; o bash "$org" --as secretary renew_secretary >/dev/null; pass $T0
[ ! -e "$M" ] && grep -q 'no handover document' <<<"$out" && [ "$(runs)" -eq 0 ] \
  && o bash "$org" --as secretary check_messages | grep -q 'no secretary-handover document'
check "no handover document: the marker is cleared, the person and the secretary are told" $?

# a busy secretary at the script's own read (exit 8): kept, run on a later pass
reset idle; o bash "$org" --as secretary renew_secretary >/dev/null
cat > "$tmp/hcwrap" <<EOF
#!/bin/sh
[ "\$1 \$2" = "get --json" ] && grep -q '^read secretary' "\$STUB/calls" && [ ! -e "\$STUB/race-done" ] \
  && { touch "\$STUB/race-done"; echo '{"name":"secretary","state":"live","status":{"app":"claude-code","state":"working"}}'; exit 0; }
exec "$tmp/tools/hc.real" "\$@"
EOF
mv "$tools/hc" "$tools/hc.real"; cp "$tmp/hcwrap" "$tools/hc"; chmod +x "$tools/hc"
pass $T0
[ -f "$M" ] && [ "$(runs)" -eq 0 ] && ! grep -q 'renewal failed' <<<"$out"; check "a turn that starts before the script's read: exit 8, kept, nobody told" $?
pass $((T0 + 30)); [ "$(runs)" -eq 1 ] && [ ! -e "$M" ]; check "then run on the next pass" $?
mv "$tools/hc.real" "$tools/hc"

# one run across watchers: a claim held by a live watcher holds the run off; a dead holder's is broken
reset idle; o bash "$org" --as secretary renew_secretary >/dev/null
mkdir -p "$tmp/state/watcher"; echo $$ > "$tmp/state/watcher/renew.claim"; pass $T0
[ "$(runs)" -eq 0 ] && [ -f "$M" ] && woke | grep -q '	skip	secretary	renew-secretary	idle	claimed	-$'; check "another watcher holds the claim: not run" $?
bash -c 'exit 0' & dead=$!; wait "$dead"; echo "$dead" > "$tmp/state/watcher/renew.claim"; pass $((T0 + 30))
[ "$(runs)" -eq 1 ] && [ ! -e "$M" ] && [ ! -e "$tmp/state/watcher/renew.claim" ]; check "a dead holder's claim is broken; run once, the claim released" $?

# a hand run that succeeds clears the marker too
reset idle; o bash "$org" --as secretary renew_secretary >/dev/null
o bash "$here/skills/secretary-handover/scripts/secretary-handover.sh" >/dev/null 2>&1; [ $? -eq 0 ] && [ ! -e "$M" ]; check "the person's own run clears the request" $?

exit "$fail"
