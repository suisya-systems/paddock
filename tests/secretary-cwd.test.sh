#!/usr/bin/env bash
# Issue #130: a secretary started by org-start or the handover script finds its tools
# (scripts/org, skills/*/scripts) without relying on the caller's working folder.
# hc is a stub on PATH; both scripts are run from a folder that is NOT the repository.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

stubdir=$tmp/bin; mkdir -p "$stubdir" "$tmp/elsewhere"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/calls"
case "$1" in
  ls) echo ok ;;
  get) [ -f "$STUB/secretary" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       echo '{"name":"secretary","state":"live","status":{"app":"claude-code","state":"idle"}}' ;;
  connect) cat >/dev/null
       echo '{"jsonrpc":"2.0","id":1,"result":{"value":{"written_at":"x"},"version":1}}' ;;
  run) : > "$STUB/secretary"; echo '{"first_message":{"sent":true,"started":true,"turn":0}}' ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"
mkdir -p "$tmp/stub"; calls=$tmp/stub/calls

go() { # go <script> : run from another folder
  : > "$calls"; rm -f "$tmp/stub/secretary"
  ( cd "$tmp/elsewhere" && env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
      STUB="$tmp/stub" PATH="$stubdir:$PATH" \
      PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" PADDOCK_APP_MODS_DIR="$tmp/app/mods" \
      PADDOCK_BIN_DIR="$tmp/orgbin" PADDOCK_READY_TRIES=2 bash "$1" >/dev/null 2>&1 )
}

go "$here/skills/org-start/scripts/org-start.sh"
grep '^run ' "$calls" | grep -qF -- "--cwd $here "; check "org-start starts the secretary with --cwd <repository root>" $?
go "$here/skills/secretary-handover/scripts/secretary-handover.sh"
grep '^run ' "$calls" | grep -qF -- "--cwd $here "; check "secretary-handover relaunches with --cwd <repository root>" $?

body=$(sed '1,/^---$/{/^---$/!d}' "$here/templates/secretary.md")
grep -qi 'working folder' <<<"$body" && grep -qF -- '--cwd' <<<"$body"
check "the template body says where the tools are (working folder set by --cwd)" $?

exit $fail
