#!/usr/bin/env bash
# Acceptance test: org-watch's wake does not stop the pass while hc send waits for a person's unfinished
# draft (hc 0.1.20 waits up to 60 s). A send that outlasts PADDOCK_WATCH_SEND_GRACE is left running in
# the background under PADDOCK_WATCH_SEND_TIMEOUT: the pass returns, the late result is logged to
# watcher/woke, and no second send goes to a terminal whose send is still pending. A send that finishes
# in time is logged as before. Stubbed hc; no core.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-watch/scripts/org-watch.sh
org=$here/scripts/org
tmp=$(mktemp -d)
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
trap 'sleep 0.3; rm -rf "$tmp"' EXIT

tools=$tmp/tools; mkdir -p "$tools"
for t in awk sed grep date cut sort cksum tr mkdir rmdir dirname basename cat rm mv cp head tail env printenv wc od sleep touch tee uniq expr test timeout ls mktemp kill; do
  p=$(command -v "$t" 2>/dev/null) && [ -x "$p" ] && ln -sf "$p" "$tools/$t"
done
ln -sf "$(command -v bash)" "$tools/bash"
# hc: ls/get from $STUB/t-<name>, read from $STUB/screen-<name>; send takes STUB_SEND_SLEEP s (the person's
# draft), then goes to $STUB/sent.
cat > "$tools/hc" <<'EOS'
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
       cat "$STUB/t-$n" ;;
  read) n=; for a in "$@"; do n=$a; done; cat "$STUB/screen-$n" 2>/dev/null ;;
  send) [ "$1" != --if ] || shift 2
        sleep "${STUB_SEND_SLEEP:-0}"
        printf '%s\t%s\n' "$1" "$2" >> "$STUB/sent" ;;
  connect) cat >/dev/null; echo '{"jsonrpc":"2.0","id":1,"result":{"value":null,"version":0}}' ;;
esac
exit 0
EOS
chmod +x "$tools/hc"

T0=1800000000
NOW=2027-01-15T01:00:00Z
NB=$(printf '\302\240'); RULE='────────────────────'
reset() {
  sleep 0.2; rm -rf "$tmp/stub" "$tmp/state"; mkdir -p "$tmp/stub" "$tmp/state"; : > "$tmp/stub/calls"
  printf '{\n  "name": "secretary",\n  "state": "live",\n  "labels": {},\n  "status": {"app":"claude-code","state":"idle"},\n  "status_ms": %s,\n  "turn": 1,\n  "created_ms": %s\n}\n' \
    $((T0*1000)) $((T0*1000)) > "$tmp/stub/t-secretary"
  printf 'output\n%s\n❯%s\n%s\n  ⏵⏵ auto mode on\n' "$RULE" "$NB" "$RULE" > "$tmp/stub/screen-secretary"
  o person send_message secretary "hello" >/dev/null
}
E=(PATH="$tools" HOME="$tmp" STUB="$tmp/stub" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_NOW="$NOW")
pass() { # pass <epoch> [env...]: sets elapsed (s)
  local now=$1 s; shift; s=$(date +%s)
  env -i "${E[@]}" PADDOCK_WATCH_NOW="$now" "$@" bash "$script" --once >/dev/null 2>&1; rc=$?
  elapsed=$(( $(date +%s) - s ))
}
o() { local who=$1; shift; env -i PATH="$tools" HOME="$tmp" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_NOW="$NOW" "$BASH" "$org" --as "$who" "$@"; }
sent() { grep -c '^secretary	' "$tmp/stub/sent" 2>/dev/null || echo 0; }
sends() { grep -c '^send ' "$tmp/stub/calls"; }
woke() { cat "$tmp/state/watcher/woke" 2>/dev/null; }
wait_for() { local i=0; until "$@"; do [ $i -lt 300 ] || return 1; sleep 0.1; i=$((i + 1)); done; }
has() { woke | grep -q "$1"; }

# a pass costs about a second of its own (the core read); the baseline is a pass with an instant send
reset; pass $T0; base=$elapsed
# a send that waits 8 s for the person's draft: the pass is held at most the grace (1 s) beyond the baseline
reset; pass $T0 STUB_SEND_SLEEP=8 PADDOCK_WATCH_SEND_GRACE=1
[ "$rc" -eq 0 ] && [ "$elapsed" -le $((base + 3)) ]; check "slow send: the pass returns with the grace, not the 8 s wait (${elapsed}s, baseline ${base}s)" $?
wait_for has '	wake	secretary	person#1	idle	no	0$'; check "slow send: the late result is logged as a wake with rc 0" $?
[ "$(sent)" -eq 1 ]; check "slow send: the line was delivered once" $?

# the send is still pending at the next pass: nothing more is sent to that terminal
reset; pass $T0 STUB_SEND_SLEEP=6 PADDOCK_WATCH_SEND_GRACE=0
pass $((T0 + 70)) STUB_SEND_SLEEP=6 PADDOCK_WATCH_SEND_GRACE=0
[ "$(sends)" -eq 1 ] && has '	skip	secretary	.*pending'; check "pending send: a later pass sends nothing and logs skip pending" $?
wait_for has '	wake	secretary	person#1	idle	no	0$'; check "pending send: the first send still lands" $?

# a send past PADDOCK_WATCH_SEND_TIMEOUT is ended and logged with timeout's rc
reset; pass $T0 STUB_SEND_SLEEP=6 PADDOCK_WATCH_SEND_GRACE=0 PADDOCK_WATCH_SEND_TIMEOUT=1
wait_for has '	wake	secretary	person#1	idle	no	124$'; check "timeout: a send past the limit is ended, logged rc 124" $?
[ "$(sent)" -eq 0 ]; check "timeout: nothing was delivered" $?

# a fast send is logged by the pass itself
reset; pass $T0
has '	wake	secretary	person#1	idle	no	0$' && [ "$(sent)" -eq 1 ]; check "fast send: logged and delivered by the end of the pass" $?

exit $fail
