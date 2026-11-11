#!/usr/bin/env bash
# Acceptance test for Issue #185: org-delegate fetches the base from origin before branching
# (--no-fetch skips it). Needs only bash, coreutils and git: hc is a stub on PATH.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-delegate/scripts/org-delegate.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
cmd=$1; shift
case "$cmd" in
  ls) echo '[]' ;;
  get) echo '{"error":{"kind":"not_found"}}'; exit 1 ;;
  file) shift; path=; for a in "$@"; do case "$a" in --*) ;; *) path=$a ;; esac; done
        mkdir -p "$(dirname "$path")" && cat > "$path"; echo '{"written":true}' ;;
  run) echo '{"first_message":{"sent":true,"started":true,"turn":0}}' ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"

g() { git -c user.name=t -c user.email=t@t.invalid "$@"; }
# origin with one commit; proj is a clone of it; then origin gets one more commit.
g init -q --bare -b main "$tmp/origin.git" 2>/dev/null || g init -q --bare "$tmp/origin.git"
g clone -q "$tmp/origin.git" "$tmp/proj" 2>/dev/null
g -C "$tmp/proj" checkout -q -b main 2>/dev/null
g -C "$tmp/proj" commit -q --allow-empty -m one
g -C "$tmp/proj" push -q origin main 2>/dev/null
g clone -q "$tmp/origin.git" "$tmp/other" 2>/dev/null
g -C "$tmp/other" commit -q --allow-empty -m two
g -C "$tmp/other" push -q origin main 2>/dev/null
ahead=$(g -C "$tmp/other" rev-parse HEAD)
behind=$(g -C "$tmp/proj" rev-parse HEAD)
[ "$ahead" != "$behind" ]; check "setup: origin is one commit ahead of the project's main" $?

run() { # run <task-id> [extra args]
  id=$1; shift
  env -u PADDOCK_ORG_ID -u HC_TERMINAL_SOCKET PADDOCK_CORE_SOCKET_DIR="$tmp/run/herdr-core" PATH="$stubdir:$PATH" \
    PADDOCK_WORKERS_DIR="$tmp/workers" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_NOW=2026-11-10T01:02:03Z \
    bash "$script" --project "$tmp/proj" --task-id "$id" --task t "$@" 2>&1
}

out=$(run f1); rc=$?
[ "$rc" -eq 0 ]; check "delegation exits 0 ($out)" $?
[ "$(g -C "$tmp/workers/f1" rev-parse HEAD)" = "$ahead" ]; check "new worktree HEAD is origin's commit" $?

out=$(run f2 --no-fetch); rc=$?
[ "$rc" -eq 0 ] && [ "$(g -C "$tmp/workers/f2" rev-parse HEAD)" = "$behind" ]; check "--no-fetch branches from the local base" $?

[ "$fail" -eq 0 ]
