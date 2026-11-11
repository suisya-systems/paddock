#!/bin/bash
# Issue #145: parallel sends from one id must get distinct, gap-free seq numbers, also when
# the critical section is slow. Stubs on PATH slow it down or hold it at a barrier.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/scripts/org
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
real_cat=$(command -v cat) # next_seq reads the id's high-water and .jsonl files with cat (Issue #168)

org() { env -u PADDOCK_ORG_ID -u PADDOCK_NOW PADDOCK_STATE_DIR="$tmp/state" bash "$script" "$@"; }
seqs() { sed -n 's/^{"seq":\([0-9]*\),.*/\1/p' "$tmp"/state/events/*/"$1".jsonl 2>/dev/null | sort -n | tr '\n' ' '; }
# bounded <seconds> <pid>: wait for a background job; 124 if it is still running (then kill it).
bounded() {
  local end=$((SECONDS + $1))
  while kill -0 "$2" 2>/dev/null; do
    [ "$SECONDS" -lt "$end" ] || { kill "$2" 2>/dev/null; wait "$2" 2>/dev/null; return 124; }
    sleep 0.1
  done
  wait "$2"
}

# 1. Month rollover: a writer still on the old month must not reuse a number already taken.
for m in 2026-01-31T23:59:59Z 2026-02-01T00:00:00Z 2026-01-31T23:59:59Z 2026-02-01T00:00:01Z; do
  PADDOCK_NOW=$m env -u PADDOCK_ORG_ID PADDOCK_STATE_DIR="$tmp/state" bash "$script" --as wm send_message secretary x >/dev/null 2>&1
done
g=$(seqs wm); [ "$g" = "1 2 3 4 " ]; check "sends across a month change get seq 1..4 (got: $g)" $?

# 2. A live writer held inside the critical section for 12 s is never broken by a waiter.
mkdir -p "$tmp/hold"
"$real_cat" > "$tmp/hold/cat" <<EOF
#!/bin/sh
out=\$("$real_cat" "\$@")
case "\$*" in *.jsonl*|*.seq*) while [ ! -e "$tmp/go" ]; do sleep 0.1; done ;; esac
printf '%s\n' "\$out"
EOF
chmod +x "$tmp/hold/cat"
org --as wh send_message secretary first >/dev/null 2>&1
PATH="$tmp/hold:$PATH" org --as wh send_message secretary held >/dev/null 2>&1 & holder=$!
end=$((SECONDS + 10)); until [ -d "$tmp/state/locks/wh/lock" ] || [ "$SECONDS" -ge "$end" ]; do sleep 0.05; done
org --as wh send_message secretary waiter >/dev/null 2>&1 & waiter=$!
sleep 12
g=$(seqs wh); [ "$g" = "1 " ]; check "a waiter writes nothing while a live writer holds the lock (got: $g)" $?
touch "$tmp/go"
bounded 20 "$holder"; r1=$?; bounded 20 "$waiter"; r2=$?
g=$(seqs wh); [ "$r1" -eq 0 ] && [ "$r2" -eq 0 ] && [ "$g" = "1 2 3 " ]; check "after release both writes land with seq 1..3 (exit $r1 $r2, got: $g)" $?

# 3. Eight parallel sends with a slow critical section (each read of the seq history takes 1 s).
mkdir -p "$tmp/slow"
printf '#!/bin/sh\nout=$("%s" "$@"); case "$*" in *.jsonl*|*.seq*) sleep 1 ;; esac; printf "%%s\\n" "$out"\n' "$real_cat" > "$tmp/slow/cat"
chmod +x "$tmp/slow/cat"
org --as w8 send_message secretary p0 >/dev/null 2>&1
pids=
for i in 1 2 3 4 5 6 7; do PATH="$tmp/slow:$PATH" org --as w8 send_message secretary "p$i" >/dev/null 2>&1 & pids="$pids $!"; done
rc=0; for p in $pids; do bounded 60 "$p" || rc=1; done
g=$(seqs w8); [ "$rc" -eq 0 ] && [ "$g" = "1 2 3 4 5 6 7 8 " ]; check "8 sends with a slow critical section get seq 1..8 (got: $g)" $?
[ ! -e "$tmp/state/locks/w8/lock" ]; check "the per-id lock is released" $?

# 4. A lock left by a writer that died is taken over.
sh -c 'exit 0' & dead=$!; wait "$dead"
mkdir -p "$tmp/state/locks/wd/lock"; echo "$dead" > "$tmp/state/locks/wd/lock/pid"
org --as wd send_message secretary after-crash >/dev/null 2>&1 & p=$!
bounded 20 "$p"; r=$?
g=$(seqs wd); [ "$r" -eq 0 ] && [ "$g" = "1 " ] && [ ! -e "$tmp/state/locks/wd/lock" ]; check "a lock of a dead writer is broken (exit $r, got: $g)" $?

# 5. A lock with no owner recorded is not broken: the send gives up after PADDOCK_LOCK_WAIT s.
mkdir -p "$tmp/state/locks/wu/lock"
PADDOCK_LOCK_WAIT=3 org --as wu send_message secretary nope >/dev/null 2>"$tmp/wu.err" & p=$!
bounded 20 "$p"; r=$?
[ "$r" -eq 5 ] && [ -z "$(seqs wu)" ] && [ -d "$tmp/state/locks/wu/lock" ] && grep -q 'locks/wu/lock' "$tmp/wu.err"
check "a lock with no owner is left alone and the send exits 5 naming it (exit $r)" $?

# 6. Many rounds of 8 parallel sends at full speed.
bad=
for round in $(seq 1 20); do
  pids=
  for i in 1 2 3 4 5 6 7 8; do org --as "r$round" send_message secretary "p$i" >/dev/null 2>&1 & pids="$pids $!"; done
  for p in $pids; do bounded 60 "$p" || bad="$bad r$round(exit)"; done
  [ "$(seqs "r$round")" = "1 2 3 4 5 6 7 8 " ] || bad="$bad r$round($(seqs "r$round"))"
done
[ -z "$bad" ]; check "20 rounds of 8 parallel sends each get seq 1..8 (bad:${bad:- none})" $?

exit $fail
