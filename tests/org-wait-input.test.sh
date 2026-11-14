#!/usr/bin/env bash
# Acceptance test for Issue #285: the person's typed input ends `org wait --children` at once.
# hc wait --children any prints reason "message" for a line typed into the waiting terminal
# (hc wait --help); org wait used to drop every reason but children/exit, so the line was read
# only when the 60 s bound ran out. hc is a stub on PATH, so no core runs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

mkdir -p "$tmp/bin" "$tmp/state"
cat > "$tmp/bin/hc" <<'EOF2'
#!/bin/sh
case "$1" in
  wait) sleep 1; echo '{"reason":"message"}'; exit 0 ;;
  *) exit 0 ;;
esac
EOF2
chmod +x "$tmp/bin/hc"

start=$SECONDS
out=$(PADDOCK_STATE_DIR="$tmp/state" PADDOCK_WAIT_POLL=0.2 PATH="$tmp/bin:$PATH" \
  bash "$here/scripts/org" --as secretary wait --children --timeout 20 2>&1)
printf '%s' "$out" | grep -q '"reason":"message"'; check "typed input ends the wait with reason message" $?
[ $((SECONDS - start)) -lt 10 ]; check "it returns within seconds, not at the bound" $?
grep -q 'reason":"message' "$here/templates/secretary.md"; check "template tells the secretary what reason message means" $?
exit $fail
