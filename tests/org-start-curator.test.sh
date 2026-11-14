#!/usr/bin/env bash
# org-start places templates/curator.md in the core's templates folder (decision 0009), so
# `hc run --bg --name curator curator` finds it. hc is a stub on PATH. Needs only bash and coreutils.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-start/scripts/org-start.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
mkdir -p "$tmp/bin" "$tmp/stub"
cat > "$tmp/bin/hc" <<'EOF2'
#!/bin/sh
case "$1" in
  ls) echo ok ;;
  get) echo '{"error":{"kind":"not_found"}}'; exit 1 ;;
  run) echo '{"name":"x"}' ;;
esac
exit 0
EOF2
printf '#!/bin/sh\n' > "$tmp/bin/claude"; chmod +x "$tmp/bin/hc" "$tmp/bin/claude"
env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
  -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN PATH="$tmp/bin:$PATH" \
  PADDOCK_CORE_CONFIG_DIR="$here/tests/fixtures/core-notes-off" PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" \
  PADDOCK_APP_MODS_DIR="$tmp/app/mods" PADDOCK_APP_LAYOUTS_DIR="$tmp/app/layouts" PADDOCK_BIN_DIR="$tmp/bin-org" \
  PADDOCK_READY_TRIES=2 bash "$script" >/dev/null 2>&1
cmp -s "$here/templates/curator.md" "$tmp/core/templates/curator.md"; check "the curator template is placed in the core templates folder" $?
[ ! -e "$tmp/bin-org/curator.md" ]; check "it is not placed in the bin folder" $?
exit $fail
