#!/usr/bin/env bash
# Acceptance test (Issue #269): when the secretary has no status after the wait, org-start reads the
# terminal's exit state and last output line and prints them; a missing claude is named. hc is a stub.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-start/scripts/org-start.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

stubdir=$tmp/bin; mkdir -p "$stubdir" "$tmp/stub"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
# The secretary exists after run; its terminal has finished with $STUB_EXIT and prints $STUB_LAST last.
case "$1" in
  get) [ -f "$STUB/secretary" ] || exit 1
       echo "{\"name\":\"secretary\",\"state\":\"finished\",\"exit_code\":$STUB_EXIT,\"reason\":\"exit\",\"status\":null}" ;;
  run) : > "$STUB/secretary" ;;
  read) printf 'starting\n%s\n\n' "$STUB_LAST" ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"
printf '#!/bin/sh\n' > "$stubdir/claude"; chmod +x "$stubdir/claude" # Issue #268: org-start needs claude on PATH

run() {
  env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
      STUB="$tmp/stub" PATH="$stubdir:$PATH" \
      PADDOCK_CORE_CONFIG_DIR="$here/tests/fixtures/core-notes-off" PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" \
      PADDOCK_APP_MODS_DIR="$tmp/app/mods" PADDOCK_APP_LAYOUTS_DIR="$tmp/app/layouts" PADDOCK_BIN_DIR="$tmp/bin-org" \
      PADDOCK_READY_TRIES=1 "$@" bash "$script" 2>&1
}

# Missing claude: exit 127, last line "claude: not found".
out=$(run STUB_EXIT=127 STUB_LAST='sh: 1: claude: not found'); rc=$?
[ "$rc" -ne 0 ]; check "missing claude: exits non-zero (rc $rc)" $?
grep -q 'exit code 127' <<<"$out"; check "missing claude: prints the exit code" $?
grep -q 'sh: 1: claude: not found' <<<"$out"; check "missing claude: prints the last output line" $?
grep -qi 'claude was not found' <<<"$out"; check "missing claude: names claude as the missing command" $?

# Another failure: the code and the line are shown, claude is not blamed.
rm -f "$tmp/stub/secretary"
out=$(run STUB_EXIT=1 STUB_LAST='boom'); rc=$?
[ "$rc" -ne 0 ] && grep -q 'exit code 1' <<<"$out" && grep -q 'boom' <<<"$out"; check "other exit: code and last line shown" $?
! grep -qi 'claude was not found' <<<"$out"; check "other exit: claude not blamed" $?

exit "$fail"
