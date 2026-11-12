#!/usr/bin/env bash
# Issue #264: org-start stops, with one line, when herdr-core's config lacks `notes = false`.
# Uses a temp config folder and a stub hc; no core runs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-start/scripts/org-start.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

mkdir -p "$tmp/bin"
cat > "$tmp/bin/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/calls"
case "$1" in
  get) [ -f "$STUB/secretary" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       echo '{"name":"secretary","state":"live","status":{"app":"claude-code","state":"idle"}}' ;;
  run) : > "$STUB/secretary"; echo '{"name":"secretary"}' ;;
  *) echo ok ;;
esac
exit 0
EOF2
chmod +x "$tmp/bin/hc"
printf '#!/bin/sh\n' > "$tmp/bin/claude"; chmod +x "$tmp/bin/claude" # Issue #268: org-start needs claude on PATH

run() { # run <core config dir>
  mkdir -p "$tmp/stub"
  env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u APPDATA \
      STUB="$tmp/stub" PATH="$tmp/bin:$PATH" XDG_CONFIG_HOME="$tmp/xdg" \
      PADDOCK_CORE_CONFIG_DIR="$1" PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" \
      PADDOCK_APP_MODS_DIR="$tmp/app/mods" PADDOCK_APP_LAYOUTS_DIR="$tmp/app/layouts" \
      PADDOCK_BIN_DIR="$tmp/bin-org" PADDOCK_READY_TRIES=2 bash "$script" 2>&1
}

# Missing: no config file at all, then a config with notes on.
: > "$tmp/stub-calls"
out=$(run "$tmp/none"); rc=$?
[ "$rc" -eq 8 ] && grep -q 'notes = false' <<<"$out" && grep -qi 'restart' <<<"$out"; check "no config: exit 8, names the line and the restart" $?
[ ! -e "$tmp/none" ] && [ ! -e "$tmp/core/templates" ] && [ ! -e "$tmp/stub/calls" ]; check "nothing written or run before the stop" $?
[ "$(grep -c . <<<"$out")" -eq 1 ]; check "the message is one line" $?

mkdir -p "$tmp/on"; printf 'notes = true\n' > "$tmp/on/config.toml"
out=$(run "$tmp/on"); rc=$?
[ "$rc" -eq 8 ]; check "notes = true: exit 8" $?
[ "$(cat "$tmp/on/config.toml")" = "notes = true" ]; check "config file is not written" $?

# Only the file the core reads counts (config.toml), and only its top level (before the first [table]).
mkdir -p "$tmp/bak"; printf 'notes = true\n' > "$tmp/bak/config.toml"; printf 'notes = false\n' > "$tmp/bak/config.toml.bak"
out=$(run "$tmp/bak"); rc=$?
[ "$rc" -eq 8 ]; check "notes = false only in config.toml.bak: exit 8" $?
mkdir -p "$tmp/bakonly"; printf 'notes = false\n' > "$tmp/bakonly/config.toml.bak"
out=$(run "$tmp/bakonly"); rc=$?
[ "$rc" -eq 8 ]; check "no config.toml, only a .bak with notes = false: exit 8" $?
mkdir -p "$tmp/nested"; printf 'notes = true\n[core]\nnotes = false\n' > "$tmp/nested/config.toml"
out=$(run "$tmp/nested"); rc=$?
[ "$rc" -eq 8 ]; check "top-level notes = true, [core] notes = false: exit 8" $?
mkdir -p "$tmp/tableonly"; printf '[core]\nnotes = false\n' > "$tmp/tableonly/config.toml"
out=$(run "$tmp/tableonly"); rc=$?
[ "$rc" -eq 8 ]; check "notes = false only inside a [table]: exit 8" $?

# Present at the top level: passes (a later [core] table with notes = true does not matter).
mkdir -p "$tmp/off"; printf 'shell = ["nu"]\nnotes = false\n[core]\nnotes = true\n' > "$tmp/off/config.toml"
out=$(run "$tmp/off"); rc=$?
[ "$rc" -eq 0 ] && grep -q "org-start: ready" <<<"$out"; check "notes = false: passes to ready" $?

exit $fail
