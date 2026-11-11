#!/usr/bin/env bash
# Acceptance test (Issue #246): on WSL with herdr-app for Windows, org-start places the cockpit mod
# and the layout in the Windows user's .config/herdr-app (not WSL's ~/.config), writes the secretary
# prop as <machine>/<name> (the app sees this core as another machine), and calls herdr-app by its
# Windows path when it is not on PATH. hc, cmd.exe, wslpath and herdr-app.exe are stubs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-start/scripts/org-start.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

win=$tmp/c/Users/someone                 # what C:\Users\someone is under WSL
app=$win/.config/herdr-app
exe=$win/AppData/Local/Programs/herdr-app/herdr-app.exe
stubdir=$tmp/bin; mkdir -p "$stubdir" "$tmp/stub" "$(dirname "$exe")"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
case "$1" in
  get) [ -f "$STUB/secretary" ] || exit 1
       echo '{"name":"secretary","state":"live","status":{"app":"claude-code","state":"idle"}}' ;;
  run) : > "$STUB/secretary" ;;
esac
exit 0
EOF2
cat > "$stubdir/cmd.exe" <<'EOF2'
#!/bin/sh
printf 'C:\\Users\\someone\r\n'
EOF2
cat > "$stubdir/wslpath" <<'EOF2'
#!/bin/sh
case "$1" in
  -w) printf 'W:%s\n' "$2" ;;
  'C:\Users\someone') printf '%s\n' "$WIN" ;;
  *) exit 1 ;;
esac
EOF2
cat > "$exe" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/app-calls"
exit 0
EOF2
chmod +x "$stubdir/hc" "$stubdir/cmd.exe" "$stubdir/wslpath" "$exe"

run() {
  env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
      -u APPDATA -u PADDOCK_APP_MODS_DIR -u PADDOCK_APP_LAYOUTS_DIR -u PADDOCK_APP_MACHINE \
      -u PADDOCK_SECRETARY_NAME \
      WSL_DISTRO_NAME=Test STUB="$tmp/stub" WIN="$win" PATH="$stubdir:/usr/bin:/bin" \
      XDG_CONFIG_HOME="$tmp/wslcfg" PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" \
      PADDOCK_BIN_DIR="$tmp/bin-org" PADDOCK_READY_TRIES=2 "$@" bash "$script" 2>&1
}
blocks=$(grep -c '"mod": "org-cockpit"' "$here/layouts/paddock.json")

out=$(run); rc=$?
[ "$rc" -eq 0 ]; check "WSL run exits 0 ($out)" $?
cmp -s "$here/mods/org-cockpit/main.js" "$app/mods/org-cockpit/main.js" \
  && cmp -s "$here/mods/org-cockpit/mod.json" "$app/mods/org-cockpit/mod.json"; check "cockpit mod placed in the Windows user's .config/herdr-app" $?
[ -f "$app/layouts/paddock.json" ]; check "layout placed in the Windows user's .config/herdr-app" $?
[ -f "$app/mods/org-agents/main.js" ]; check "org-agents mod placed in the Windows user's .config/herdr-app" $?
[ ! -e "$tmp/wslcfg/herdr-app" ]; check "nothing placed under WSL's own config folder" $?
[ "$(grep -c '"secretary": *"wsl/secretary"' "$app/layouts/paddock.json" 2>/dev/null)" = "$blocks" ]; check "secretary prop wsl/secretary in every org-cockpit block ($blocks)" $?
grep -qx "check W:$app/mods/org-cockpit" "$tmp/stub/app-calls" 2>/dev/null; check "herdr-app.exe (not on PATH) checks the cockpit mod by its Windows path" $?
grep -qF "$exe do layout.switch" <<<"$out"; check "the printed layout.switch command names herdr-app by its Windows path" $?

# A stale prop from an earlier demo (wsl/demo-secretary) becomes this secretary on that machine.
sed 's/"secretary": *"wsl\/secretary"/"secretary": "wsl\/demo-secretary"/' "$app/layouts/paddock.json" > "$tmp/stale.json"
cp "$tmp/stale.json" "$app/layouts/paddock.json"
run >/dev/null
[ "$(grep -c '"secretary": *"wsl/secretary"' "$app/layouts/paddock.json")" = "$blocks" ] \
  && ! grep -q demo-secretary "$app/layouts/paddock.json"; check "a stale wsl/demo-secretary prop is replaced by wsl/secretary" $?

# The machine name the app gives this core can be set; it wins over the installed prop.
run PADDOCK_APP_MACHINE=box >/dev/null
[ "$(grep -c '"secretary": *"box/secretary"' "$app/layouts/paddock.json")" = "$blocks" ]; check "PADDOCK_APP_MACHINE=box writes box/secretary" $?

# Outside WSL nothing changes: WSL's own config folder, no machine prop added.
rm -f "$tmp/stub/secretary"
out=$(run env -u WSL_DISTRO_NAME); rc=$?
[ "$rc" -eq 0 ] && [ -f "$tmp/wslcfg/herdr-app/layouts/paddock.json" ] \
  && cmp -s "$here/layouts/paddock.json" "$tmp/wslcfg/herdr-app/layouts/paddock.json"; check "not WSL: layout placed unchanged under the own config folder ($out)" $?

exit "$fail"
