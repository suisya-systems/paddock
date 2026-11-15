#!/usr/bin/env bash
# Issue #380, #385: the secretary's Stop hook refuses to end a turn while it has unread mail
# (unless secretary-handover is written), and fails open when the mailbox cannot be read.
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
st=$tmp/state
mail() { PADDOCK_STATE_DIR=$st bash "$here/scripts/org" --as "$1" "${@:2}" >/dev/null 2>&1; }
fire null null; rc=$?
[ $rc -eq 0 ] && [ -z "$err" ]; check "allowed with no mail ($rc)" $?
w='{"approvals":[],"work":[{"task_id":"t1","title":"x","since":"2026-11-15T00:00:00Z"}]}'
fire "$w" null; rc=$?
[ $rc -eq 0 ]; check "allowed with open work and no unread mail: no wait is held (#385) ($rc)" $?
mail w-t1 report done --task t1 "finished"
fire "$w" null; rc=$?
[ $rc -eq 2 ] && grep -q 'check_messages' <<<"$err" && ! grep -q 'wait' <<<"$err"; check "refused with unread mail, told to read it, not to wait ($rc)" $?
fire "$w" null true; rc=$?
[ $rc -eq 2 ]; check "refused again when stop_hook_active is true ($rc)" $?
fire "$w" '{"written_at":"2026-11-15T00:00:00Z","open_threads":{}}'; rc=$?
[ $rc -eq 0 ] && [ -z "$err" ]; check "allowed with unread mail when secretary-handover is written ($rc)" $?
STUB_FAIL=1 fire "$w" null; rc=$?
[ $rc -eq 0 ] && grep -q 'cannot read secretary-handover, stop allowed' <<<"$err"; check "fails open when the handover cannot be read ($rc)" $?
mail secretary check_messages
fire "$w" null; rc=$?
[ $rc -eq 0 ]; check "allowed once the mail is read ($rc)" $?
chmod 000 "$st/events"
fire "$w" null; rc=$?
chmod 755 "$st/events"
[ $rc -eq 0 ]; check "fails open (or finds nothing) when the mailbox cannot be read ($rc)" $?
exit $fail
