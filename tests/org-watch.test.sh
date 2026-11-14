#!/usr/bin/env bash
# Acceptance test for skills/org-watch/scripts/org-watch.sh (decision 0008): a resident watcher
# that tells the person (a desktop toast with sound, else a bell) once per waiting approval card,
# on the secretary's incident (Q3: a worker blocked and the secretary unchanged for N minutes) and
# on a terminal that never reported a status. Stubbed hc, powershell.exe and notify-send; no core,
# no desktop. The clock is PADDOCK_WATCH_NOW (epoch seconds), N is PADDOCK_WATCH_N (minutes).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-watch/scripts/org-watch.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# A PATH of its own, so the host's real powershell.exe / notify-send never answer.
tools=$tmp/tools; mkdir -p "$tools"
for t in awk sed grep date cut sort cksum tr mkdir dirname basename cat rm mv cp head tail env printenv wc od sleep touch tee uniq expr test timeout; do
  p=$(command -v "$t" 2>/dev/null) && [ -x "$p" ] && ln -sf "$p" "$tools/$t"
done
cat > "$tools/hc" <<'EOF'
#!/bin/sh
echo "$*" >> "$STUB/calls"
cmd=$1; shift
case "$cmd" in
  ls) [ -z "${STUB_LS_FAIL:-}" ] || { echo 'hc: connection refused' >&2; exit 1; }
      first=1; printf '['
      for f in "$STUB"/t-*; do [ -e "$f" ] || continue
        [ -n "$first" ] || printf ','; first=; printf '{"name":"%s"}' "${f##*/t-}"; done
      printf ']\n' ;;
  get) n=; for a in "$@"; do case "$a" in --*) ;; *) n=$a ;; esac; done
       [ -f "$STUB/t-$n" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       cat "$STUB/t-$n" ;;
  read) n=; for a in "$@"; do n=$a; done; cat "$STUB/screen-$n" 2>/dev/null ;;
  connect) cat >/dev/null; cat "$STUB/doc" 2>/dev/null \
             || echo '{"jsonrpc":"2.0","id":1,"result":{"value":null,"version":0}}' ;;
esac
exit 0
EOF
cat > "$tmp/ps" <<'EOF'
#!/bin/sh
# stands in for powershell.exe: records the arguments, stdin and environment of every call
{ echo "== call"; echo "ARGS: $*"; cat; env; } >> "$STUB/ps.calls"
[ -z "${STUB_PS_FAIL:-}" ] || exit 1
exit 0
EOF
cat > "$tmp/ns" <<'EOF'
#!/bin/sh
{ echo "== call"; echo "ARGS: $*"; } >> "$STUB/ns.calls"
exit 0
EOF
chmod +x "$tools/hc" "$tmp/ps" "$tmp/ns"

T0=1800000000; N=10; NS=600
reset() { # fresh stub state; $1 = notifiers: ps ns both none
  rm -rf "$tmp/stub" "$tmp/state" "$tmp/np"; mkdir -p "$tmp/stub" "$tmp/state" "$tmp/np"
  : > "$tmp/stub/calls"
  case "${1:-ps}" in ps|both) cp "$tmp/ps" "$tmp/np/powershell.exe" ;; esac
  case "${1:-ps}" in ns|both) cp "$tmp/ns" "$tmp/np/notify-send" ;; esac
  doc '[]'
}
doc() { # doc <approvals-array-json>
  printf '{"jsonrpc":"2.0","id":1,"result":{"value":{"work":[],"approvals":%s},"version":3}}\n' "$1" > "$tmp/stub/doc"
}
card='{"id":"t1-20261114T010000Z","task_id":"t1","question":"May I delete the build folder?","asked_at":"2026-11-14T01:00:00Z"}'
term() { # term <name> <label|-> <state|none> <turn> <status_ms> <created_ms>
  local lab='{}' st
  [ "$2" = - ] || lab="{\"task_id\":\"$2\"}"
  st="{\"app\":\"claude-code\",\"state\":\"$3\"}"; [ "$3" != none ] || st=null
  printf '{\n  "name": "%s",\n  "state": "live",\n  "labels": %s,\n  "status": %s,\n  "status_ms": %s,\n  "turn": %s,\n  "created_ms": %s\n}\n' \
    "$1" "$lab" "$st" "$5" "$4" "$6" > "$tmp/stub/t-$1"
}
screen() { printf '%s\n' "$2" > "$tmp/stub/screen-$1"; } # screen <name> <text>
pass() { # pass <now> [extra env...]: one pass; stdout+stderr in $out, status in $rc
  local now=$1; shift
  out=$(env -i PATH="$tmp/np:$tools" HOME="$tmp" STUB="$tmp/stub" PADDOCK_STATE_DIR="$tmp/state" \
        PADDOCK_WATCH_NOW="$now" PADDOCK_WATCH_N=$N "$@" "$(command -v bash)" "$script" --once 2>&1); rc=$?
}
toasts() { grep -c '^== call' "$tmp/stub/ps.calls" 2>/dev/null || echo 0; }
ntoasts() { grep -c '^== call' "$tmp/stub/ns.calls" 2>/dev/null || echo 0; }
calls=$tmp/stub/calls

[ -f "$script" ]; check "script exists" $?
[ -f "$here/skills/org-watch/SKILL.md" ]; check "SKILL.md exists" $?
bash -n "$script" 2>/dev/null; check "script parses" $?
out=$(bash "$script" --help 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -qi usage <<<"$out" && grep -q -- '--once' <<<"$out"; check "--help exits 0 and names --once" $?
printf '%s' "$out" | LC_ALL=C grep -q '[^ -~[:space:]]' && rc=1 || rc=0
[ "$rc" -eq 0 ]; check "--help is ASCII only (cp932 consoles)" $?
bash "$script" --no-such-flag >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; check "unknown argument exits 2" $?
out=$(env -i PATH="$tmp/empty" HOME="$tmp" "$(command -v bash)" "$script" --once 2>&1); rc=$?
[ "$rc" -eq 3 ]; check "no hc on PATH exits 3" $?

# Quiet when nothing waits.
reset ps; term secretary - working 3 $((T0*1000)) $((T0*1000))
pass $T0
[ "$rc" -eq 0 ] && [ "$(toasts)" -eq 0 ] && ! grep -q "$(printf '\a')" <<<"$out"; check "nothing waiting: no toast, no bell" $?
pass $((T0 + 3600))
[ "$(toasts)" -eq 0 ]; check "a healthy secretary and no cards stay quiet an hour later" $?

# An approval card: once, with task and question, through the WSL toast.
reset ps; doc "[$card]"; term secretary - working 3 $((T0*1000)) $((T0*1000))
pass $T0
[ "$rc" -eq 0 ] && [ "$(toasts)" -eq 1 ]; check "a waiting card raises one powershell toast" $?
grep -q 't1' "$tmp/stub/ps.calls" && grep -q 'May I delete the build folder?' "$tmp/stub/ps.calls"; check "the toast carries the task and the question" $?
grep -qi 'audio\|sound' "$tmp/stub/ps.calls"; check "the toast asks for the system sound" $?
pass $((T0 + 30))
[ "$(toasts)" -eq 1 ]; check "the same card is not told again on the next pass" $?
pass $((T0 + NS - 1))
[ "$(toasts)" -eq 1 ]; check "still once just before N minutes" $?
pass $((T0 + NS))
[ "$(toasts)" -eq 2 ]; check "told again after N minutes if still waiting" $?
doc '[]'; pass $((T0 + NS + 30))
[ "$(toasts)" -eq 2 ]; check "an answered card (gone from org-state) is not told" $?
card2='{"id":"t2-20261114T020000Z","task_id":"t2","question":"Run the migration?","asked_at":"2026-11-14T02:00:00Z"}'
doc "[$card2]"; pass $((T0 + NS + 60))
[ "$(toasts)" -eq 3 ] && grep -q 'Run the migration?' "$tmp/stub/ps.calls"; check "a new card is told at once" $?
doc "[$card,$card2]"; reset ps; doc "[$card,$card2]"; pass $T0
[ "$(toasts)" -eq 2 ]; check "two cards are two toasts (once per card)" $?
q='{"id":"t3-1","task_id":"t3","question":"Is \"x\" a } or a ] ok? $(touch pwned) `id`","asked_at":"x"}'
reset ps; doc "[$q]"; pass $T0
[ "$(toasts)" -eq 1 ] && [ ! -e "$tmp/pwned" ] && [ ! -e pwned ]; check "quotes, braces and shell syntax in a question are data, never run" $?

# Channel choice and the bell floor.
reset ns; doc "[$card]"; pass $T0
[ "$(ntoasts)" -eq 1 ] && grep -q 'May I delete the build folder?' "$tmp/stub/ns.calls"; check "no powershell.exe: notify-send is used with the message" $?
reset both; doc "[$card]"; pass $T0
[ "$(toasts)" -eq 1 ] && [ "$(ntoasts)" -eq 0 ]; check "both present: the WSL toast wins, one channel per message" $?
reset both; doc "[$card]"; pass $T0 STUB_PS_FAIL=1
[ "$(ntoasts)" -eq 1 ]; check "powershell.exe failing falls back to notify-send" $?
reset none; doc "[$card]"; pass $T0
grep -q "$(printf '\a')" <<<"$out" && grep -q 'May I delete the build folder?' <<<"$out"; check "no notifier: a bell and the message on the terminal" $?
reset ps; doc "[$card]"; pass $T0 STUB_PS_FAIL=1
grep -q "$(printf '\a')" <<<"$out"; check "the only notifier failing falls back to the bell" $?
reset ps; doc "[$card]"; pass $T0
! grep -q "$(printf '\a')" <<<"$out"; check "a raised toast does not also ring the bell" $?

# Q3 incident: a worker blocked and the secretary unchanged for N minutes.
reset ps; term secretary - working 3 $((T0*1000)) $((T0*1000)); term w-t1 t1 blocked 1 $((T0*1000)) $((T0*1000)); screen secretary "idle screen"
pass $T0
[ "$(toasts)" -eq 0 ]; check "incident: not at first sight" $?
pass $((T0 + NS - 1))
[ "$(toasts)" -eq 0 ]; check "incident: not before N minutes" $?
pass $((T0 + NS))
[ "$(toasts)" -eq 1 ] && grep -qi 'secretary' "$tmp/stub/ps.calls"; check "incident: at N minutes, the person is told the secretary is not moving" $?
pass $((T0 + NS + 30))
[ "$(toasts)" -eq 1 ]; check "incident: told once, not on every pass" $?
pass $((T0 + 2 * NS))
[ "$(toasts)" -eq 2 ]; check "incident: told again after another N minutes" $?

reset ps; term secretary - working 3 $((T0*1000)) $((T0*1000)); term w-t1 t1 blocked 1 $((T0*1000)) $((T0*1000)); screen secretary "a"
pass $T0; term secretary - working 4 $((T0*1000+1000)) $((T0*1000)); pass $((T0 + NS - 60)); pass $((T0 + NS))
[ "$(toasts)" -eq 0 ]; check "incident: a turn change resets the clock" $?
reset ps; term secretary - working 3 $((T0*1000)) $((T0*1000)); term w-t1 t1 blocked 1 $((T0*1000)) $((T0*1000)); screen secretary "a"
pass $T0; screen secretary "b"; pass $((T0 + NS - 60)); pass $((T0 + NS))
[ "$(toasts)" -eq 0 ]; check "incident: a screen change resets the clock" $?
reset ps; term secretary - idle 3 $((T0*1000)) $((T0*1000)); term w-t1 t1 blocked 1 $((T0*1000)) $((T0*1000)); screen secretary "a"
pass $T0; term secretary - working 3 $((T0*1000+60000)) $((T0*1000)); pass $((T0 + NS - 60)); pass $((T0 + NS))
[ "$(toasts)" -eq 0 ]; check "incident: a fresh secretary status resets the clock" $?
reset ps; term secretary - working 3 $((T0*1000)) $((T0*1000)); term w-t1 t1 working 1 $((T0*1000)) $((T0*1000)); screen secretary "a"
pass $T0; pass $((T0 + 3 * NS))
[ "$(toasts)" -eq 0 ]; check "incident: a frozen secretary with no blocked worker is not an incident" $?
reset ps; term secretary - working 3 $((T0*1000)) $((T0*1000)); term w-t1 t1 blocked 1 $((T0*1000)) $((T0*1000)); screen secretary "a"
pass $T0 PADDOCK_WATCH_N=2; pass $((T0 + 120)) PADDOCK_WATCH_N=2
[ "$(toasts)" -eq 1 ]; check "PADDOCK_WATCH_N sets N" $?
reset ps; term w-t1 t1 blocked 1 $((T0*1000)) $((T0*1000))
pass $T0; pass $((T0 + 3 * NS))
[ "$rc" -eq 0 ] && [ "$(toasts)" -eq 0 ]; check "incident: no secretary terminal is not guessed at" $?
reset ps; term secretary - working 3 $((T0*1000)) $((T0*1000)); term w-t1 t1 blocked 1 $((T0*1000)) $((T0*1000)); screen secretary "a"
pass $T0; pass $((T0 + NS))
printf 'x\n' > "$tmp/state/unrelated"
pass $((T0 + NS + 30)) PADDOCK_STATE_DIR="$tmp/state"
[ "$(toasts)" -eq 1 ]; check "the ledger lives under the state folder and survives between runs" $?

# A terminal that never reported a status.
reset ps; term secretary - working 3 $((T0*1000)) $((T0*1000)); term w-t1 t1 none 0 0 $((T0*1000))
pass $((T0 + NS - 1))
[ "$(toasts)" -eq 0 ]; check "no status: not before N minutes after it was created" $?
pass $((T0 + NS))
[ "$(toasts)" -eq 1 ] && grep -q 'w-t1\|t1' "$tmp/stub/ps.calls"; check "no status for N minutes: the person is told which terminal" $?
pass $((T0 + NS + 30))
[ "$(toasts)" -eq 1 ]; check "no status: told once" $?
reset ps; term secretary - working 3 $((T0*1000)) $((T0*1000)); term w-t1 t1 working 0 $((T0*1000)) $((T0*1000 - 7200000))
pass $T0
[ "$(toasts)" -eq 0 ]; check "an old terminal that reports a status is not told" $?
reset ps; term secretary - none 0 0 $((T0*1000)); pass $((T0 + NS))
[ "$(toasts)" -eq 1 ]; check "the secretary with no status for N minutes is told too" $?
reset ps; term other - none 0 0 $((T0*1000 - 7200000)); term secretary - working 3 $((T0*1000)) $((T0*1000)); pass $T0
[ "$(toasts)" -eq 0 ]; check "an unlabelled terminal that is not the secretary is never watched" $?

# Core unreachable, and what the watcher may touch.
reset ps; doc "[$card]"; pass $T0 STUB_LS_FAIL=1
[ "$rc" -eq 5 ] && [ "$(toasts)" -eq 0 ]; check "--once with the core unreachable exits 5 and tells nobody" $?
reset ps; doc "[$card]"; term secretary - working 3 $((T0*1000)) $((T0*1000)); term w-t1 t1 blocked 1 $((T0*1000)) $((T0*1000)); pass $T0; pass $((T0 + NS))
! grep -Eq '^(send|keys|interrupt|kill|rm|run|server) ' "$calls"; check "read only: no send, keys, kill, rm, run or server call" $?

# The loop form (no --once) repeats and stops with its terminal.
reset ps; doc "[$card]"
out=$(env -i PATH="$tmp/np:$tools" HOME="$tmp" STUB="$tmp/stub" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_WATCH_NOW=$T0 \
      PADDOCK_WATCH_N=$N PADDOCK_WATCH_INTERVAL=1 timeout 3 "$(command -v bash)" "$script" 2>&1); rc=$?
[ "$rc" -eq 124 ] && [ "$(toasts)" -eq 1 ]; check "without --once it keeps running and tells the card once" $?

exit "$fail"
