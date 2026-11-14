#!/usr/bin/env bash
# Issue #380: the secretary's Stop hook refuses to end a turn idle while org-state has a work or
# approvals entry (unless secretary-handover is written), and fails open when org-state cannot be read.
# The hook runs the installed org copy beside it; hc is a stub that answers doc.get per document.
# Needs bash and node (to read the settings).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
hook=$(node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.stdout.write(((s.hooks.Stop || [])[0] || {hooks: [{}]}).hooks[0].command || "");' "$here/templates/secretary-settings.json")
grep -q 'secretary-stop-guard\.sh' <<<"$hook"; check "secretary-settings.json runs secretary-stop-guard.sh on Stop" $?
grep -q 'scripts/hooks/secretary-stop-guard\.sh' "$here/skills/org-start/scripts/org-start.sh"; check "org-start installs the hook" $?
grep -q 'secretary-stop-guard\.sh' "$here/templates/secretary.md"; check "the secretary template names the hook" $?

# The bin folder as org-start lays it out: the hook beside org.
bin=$tmp/bin; mkdir -p "$bin" "$tmp/path" "$tmp/stub"
cp "$here/scripts/hooks/secretary-stop-guard.sh" "$here/scripts/org" "$bin/"
cat > "$tmp/path/hc" <<'EOF'
#!/bin/sh
[ "$1" = connect ] || exit 1
req=$(cat); [ -z "${STUB_FAIL:-}" ] || { echo 'hc: connection refused' >&2; exit 1; }
case "$req" in *secretary-handover*) v=$(cat "$STUB/handover") ;; *) v=$(cat "$STUB/state") ;; esac
printf '{"jsonrpc":"2.0","id":1,"result":{"value":%s,"version":3}}\n' "$v"
EOF
chmod +x "$tmp/path/hc"
err=
fire() { # fire <org-state> <handover> [stop_hook_active]
  printf '%s' "$1" > "$tmp/stub/state"; printf '%s' "$2" > "$tmp/stub/handover"
  err=$(printf '{"hook_event_name":"Stop","stop_hook_active":%s}' "${3:-false}" |
        STUB=$tmp/stub PATH="$tmp/path:$PATH" PADDOCK_HC_HOLD=0 PADDOCK_STATE_DIR=$tmp/state XDG_STATE_HOME=$tmp/xdg PADDOCK_BIN_DIR=$bin sh -c "$hook" 2>&1 >/dev/null)
}
w='{"approvals":[],"work":[{"task_id":"t1","title":"x ] y","since":"2026-11-15T00:00:00Z"}]}'
a='{"approvals":[{"id":"a1","task_id":"t1","question":"Merge?"}],"work":[]}'
e='{"approvals":[],"work":[]}'
fire "$w" null; rc=$?
[ $rc -eq 2 ] && grep -q 'wait --children' <<<"$err"; check "refused with work non-empty ($rc)" $?
fire "$a" null; rc=$?
[ $rc -eq 2 ] && grep -q 'wait --children' <<<"$err"; check "refused with approvals non-empty ($rc)" $?
fire "$a" null true; rc=$?
[ $rc -eq 2 ] && grep -q 'wait --children' <<<"$err"; check "refused again when stop_hook_active is true ($rc)" $?
fire "$e" null; rc=$?
[ $rc -eq 0 ] && [ -z "$err" ]; check "allowed when both are empty ($rc)" $?
fire '{ "approvals" : [ ], "work" : [ ] }' null; rc=$?
[ $rc -eq 0 ]; check "allowed when both are empty, spaced ($rc)" $?
fire '{"approvals":[],"work":[{"task_id":"t2","title":"the \"work\":[x] text"}]}' null; rc=$?
[ $rc -eq 2 ]; check "refused: a title quoting the key does not confuse it ($rc)" $?
fire '{"approvals":[],"work":[],"note":"\"work\":[x]"}' null; rc=$?
[ $rc -eq 0 ]; check "allowed: an escaped \"work\":[ in a string is not an entry ($rc)" $?
fire null null; rc=$?
[ $rc -eq 0 ]; check "allowed when org-state was never written ($rc)" $?
fire "$w" '{"written_at":"2026-11-15T00:00:00Z","open_threads":{}}'; rc=$?
[ $rc -eq 0 ] && [ -z "$err" ]; check "allowed when secretary-handover is written ($rc)" $?
STUB_FAIL=1 fire "$w" null; rc=$?
[ $rc -eq 0 ] && grep -q 'cannot read org-state, stop allowed' <<<"$err"; check "fails open when org-state is unreadable ($rc)" $?
exit $fail
