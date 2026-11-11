#!/bin/bash
# Issue #222: the next seq of an id comes from a small high-water file, not from reading every
# month's file of the id. An earlier month is made unreadable (its file is swapped for a folder,
# which fails for root too); a writer that still read it would restart at 1.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/scripts/org
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
org() { # org <now> <org args...>
  local n=$1; shift
  env -u PADDOCK_ORG_ID PADDOCK_NOW="$n" PADDOCK_STATE_DIR="$tmp/state" bash "$script" "$@"
}
ev=$tmp/state/events
last() { tail -n 1 "$ev/$1/$2.jsonl" 2>/dev/null | sed -n 's/^{"seq":\([0-9]*\),.*/\1/p'; }

# 1. A large earlier month (60000 lines) is there; one append sees it and goes on from 60001.
mkdir -p "$ev/2026-01"
awk 'BEGIN { for (i = 1; i <= 60000; i++) printf "{\"seq\":%d,\"ts\":\"2026-01-15T00:00:00Z\",\"from\":\"big\",\"kind\":\"message\",\"to\":\"x\",\"task_id\":\"\",\"text\":\"filler filler filler\"}\n", i }' > "$ev/2026-01/big.jsonl"
org 2026-01-31T23:59:59Z --as big send_message x a >/dev/null
g=$(last 2026-01 big); [ "$g" = 60001 ]; check "an append after a large month gets seq 60001 (got: $g)" $?

# 2. The earlier month can no longer be read. The next month's appends read only the small state.
mv "$ev/2026-01/big.jsonl" "$tmp/big.aside" && mkdir "$ev/2026-01/big.jsonl"
org 2026-02-01T00:00:00Z --as big send_message x b >/dev/null; rc=$?
g=$(last 2026-02 big); [ "$rc" -eq 0 ] && [ "$g" = 60002 ]; check "the first append of the next month does not read the old month: seq 60002 (rc $rc, got: $g)" $?
org 2026-02-01T00:00:01Z --as big send_message x c >/dev/null
g=$(last 2026-02 big); [ "$g" = 60003 ]; check "and the one after it gets seq 60003 (got: $g)" $?

# 3. A writer that took its month before the lock and writes into the old month still goes on up.
mv "$ev/2026-01/big.jsonl" "$tmp/gone" 2>/dev/null; : > "$ev/2026-01/big.jsonl" 2>/dev/null || true
org 2026-01-31T23:59:59Z --as big send_message x d >/dev/null
g=$(last 2026-01 big); [ "$g" = 60004 ]; check "a late write into the old month gets seq 60004, not a reused number (got: $g)" $?
exit $fail
