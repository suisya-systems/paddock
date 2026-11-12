#!/usr/bin/env bash
# Issue #268: the secretary and worker templates start claude by the absolute path org-start found,
# so a core whose holder has a minimal PATH (no ~/.local/bin) still starts them.
# Stub hc and a stub claude; no core runs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-start/scripts/org-start.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

mkdir -p "$tmp/bin" "$tmp/home/.local/bin" "$tmp/core" "$tmp/stub"
cat > "$tmp/bin/hc" <<'EOF2'
#!/bin/sh
case "$1" in
  get) [ -f "$STUB/secretary" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       echo '{"name":"secretary","state":"live","status":{"app":"claude-code","state":"idle"}}' ;;
  run) : > "$STUB/secretary"; echo '{"name":"secretary"}' ;;
  *) echo ok ;;
esac
exit 0
EOF2
chmod +x "$tmp/bin/hc"
# claude lives only in ~/.local/bin, like the real one.
printf '#!/bin/sh\necho "$0 $*" > "$STUB/claude-ran"\n' > "$tmp/home/.local/bin/claude"
chmod +x "$tmp/home/.local/bin/claude"
printf 'notes = false\n' > "$tmp/core/config.toml"
printf 'tok\n' > "$tmp/gh-token"

start() { # start <PATH for org-start>
  env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u APPDATA \
      STUB="$tmp/stub" PATH="$1" HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/xdg" \
      PADDOCK_CORE_CONFIG_DIR="$tmp/core" PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" \
      PADDOCK_APP_MODS_DIR="$tmp/app/mods" PADDOCK_APP_LAYOUTS_DIR="$tmp/app/layouts" \
      PADDOCK_BIN_DIR="$tmp/bin-org" PADDOCK_READY_TRIES=2 bash "$script" 2>&1
}

# org-start runs from a shell that has claude on PATH.
out=$(start "$tmp/home/.local/bin:$tmp/bin:/usr/bin:/bin"); rc=$?
[ "$rc" -eq 0 ]; check "org-start with claude on PATH: exit 0" $?

# A terminal gets the holder's minimal PATH: claude is not on it.
minpath=/usr/bin:/bin
for t in secretary worker; do
  rm -f "$tmp/stub/claude-ran"
  cmd=$(sed -n 's/^command: //p' "$tmp/core/templates/$t.md")
  env -i HOME="$tmp/home" TMPDIR="${TMPDIR:-/tmp}" PATH="$minpath" STUB="$tmp/stub" PADDOCK_BIN_DIR="$tmp/bin-org" \
      PADDOCK_WORKER_GH_TOKEN_FILE="$tmp/gh-token" PADDOCK_STATE_DIR="$tmp/state" \
      sh -c "$cmd" >/dev/null 2>&1
  grep -q "^$tmp/home/.local/bin/claude " "$tmp/stub/claude-ran" 2>/dev/null
  check "$t template starts claude by absolute path on a minimal PATH" $?
done

# No claude anywhere: org-start stops and says how to fix it.
if PATH=$tmp/bin:/usr/bin:/bin command -v claude >/dev/null 2>&1; then
  echo "skip claude exists on the system PATH; not-found case not run"
else
  rm -rf "$tmp/bin-org" "$tmp/core/templates"
  out=$(start "$tmp/bin:/usr/bin:/bin"); rc=$?
  [ "$rc" -ne 0 ] && grep -q 'claude' <<<"$out" && grep -qi 'PATH' <<<"$out"; check "claude not found: org-start stops and names claude and PATH" $?
fi
exit "$fail"
