#!/usr/bin/env bash
# Edge cases of `org wait`'s worker check (Issue #175), stubbed hc as in org-wait-watch.test.sh:
# a "]" in a work title does not hide the tasks after it; a worker that already has a done
# record and is blocked again is still listed as waiting, and one that is not blocked is not.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
org=$here/scripts/org
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
case "$1" in
  get) n=$(for a in "$@"; do last=$a; done; echo "$last")
       [ -f "$STUB/term-$n" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       cat "$STUB/term-$n"; exit 0 ;;
  connect) ;;
  *) exit 0 ;;
esac
read -r req
printf '{"jsonrpc":"2.0","id":1,"result":{"value":%s,"version":1}}\n' "$(cat "$STUB/doc")"
EOF2
chmod +x "$stubdir/hc"
export STUB=$tmp/stub; mkdir -p "$STUB"
o() { local who=$1; shift
  env -u PADDOCK_ORG_ID PADDOCK_HC_HOLD=0 PADDOCK_NOW=${AT:-2026-11-11T01:02:03Z} PADDOCK_STATE_DIR="$tmp/state" \
      PADDOCK_WAIT_POLL=0.2 PATH="$stubdir:$PATH" bash "$org" --as "$who" "$@"; }

printf '%s\n' '{"work":[{"task_id":"t-a","title":"[bug] fix \"x]\" [y]","since":"s"},{"task_id":"t-b","title":"two","since":"s"}],"approvals":[]}' > "$STUB/doc"
out=$(o secretary wait --timeout 1 2>&1)
printf '%s' "$out" | grep -q '"gone":\["t-a","t-b"\]'; check "a ] in a title does not cut the list ($out)" $?

printf '%s\n' '{"work":[{"task_id":"t-a","title":"one","since":"s"},{"task_id":"t-b","title":"two","since":"s"}],"approvals":[]}' > "$STUB/doc"
o w-t-a report done --task t-a x >/dev/null; o w-t-b report done --task t-b x >/dev/null; o secretary check_messages >/dev/null
echo '{"name":"w-t-a","state":"running","status":{"state":"blocked"}}' > "$STUB/term-w-t-a"
echo '{"name":"w-t-b","state":"running","status":{"state":"working"}}' > "$STUB/term-w-t-b"
out=$(o secretary wait --timeout 1 2>&1)
printf '%s' "$out" | grep -q '"waiting":\["t-a"\]' && ! printf '%s' "$out" | grep -q 't-b'; check "blocked after a done record is listed, working is not ($out)" $?

# A status text holding braces before the state does not hide a blocked worker.
echo '{"name":"w-t-a","state":"running","status":{"text":"run {\"k\": 1}; ok?","state":"blocked"}}' > "$STUB/term-w-t-a"
out=$(o secretary wait --timeout 1 2>&1)
printf '%s' "$out" | grep -q '"waiting":\["t-a"\]'; check "braces in the status text do not hide a blocked worker ($out)" $?

# The same task id delegated again: the earlier done does not count after the newer start.
# (org-delegate's start record is written by secretary; PADDOCK_NOW orders the two.)
rm -rf "$tmp/state"
printf '%s\n' '{"work":[{"task_id":"t-r","title":"again","since":"s"}],"approvals":[]}' > "$STUB/doc"
oat() { local at=$1; shift; AT=$at o "$@"; }
oat 2026-11-11T01:00:00Z secretary report start --task t-r "first" >/dev/null
oat 2026-11-11T01:10:00Z w-t-r report done --task t-r "first done" >/dev/null
oat 2026-11-11T01:20:00Z secretary report start --task t-r "second" >/dev/null
o secretary check_messages >/dev/null
out=$(o secretary wait --timeout 1 2>&1)
printf '%s' "$out" | grep -q '"gone":\["t-r"\]'; check "an earlier delegation's done does not hide a gone worker ($out)" $?
exit $fail
