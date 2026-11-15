#!/usr/bin/env bash
# Acceptance test (Issue #246): on WSL with herdr-app for Windows, org-start places the cockpit mod
# and the layout in the Windows user's .config/herdr-app (not WSL's ~/.config), writes the secretary
# prop as <machine>/<name> (the app sees this core as another machine), and calls herdr-app by its
# Windows path when it is not on PATH. hc, cmd.exe, wslpath and herdr-app.exe are stubs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-start/scripts/org-start.sh
tmp=$(mktemp -d)
export PADDOCK_STATE_DIR=$tmp/state # org-start places the secretary's rules in <state>/secretary (decision 0014)
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
cmdbin=$tmp/cmdbin; mkdir -p "$cmdbin"   # cmd.exe on PATH only in the WSL_DISTRO_NAME cases
cat > "$cmdbin/cmd.exe" <<'EOF2'
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
printf '#!/bin/sh\n' > "$stubdir/claude"; chmod +x "$stubdir/claude"
chmod +x "$stubdir/hc" "$cmdbin/cmd.exe" "$stubdir/wslpath" "$exe"

run() {
  env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
      -u APPDATA -u PADDOCK_APP_MODS_DIR -u PADDOCK_APP_LAYOUTS_DIR -u PADDOCK_APP_MACHINE \
      -u PADDOCK_SECRETARY_NAME \
      WSL_DISTRO_NAME=Test STUB="$tmp/stub" WIN="$win" PATH="$stubdir:$cmdbin:/usr/bin:/bin" \
      PADDOCK_PROC_DIR="$tmp/proc" PADDOCK_WIN_C_DIR="$tmp/c" \
      XDG_CONFIG_HOME="$tmp/wslcfg" PADDOCK_CORE_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/core-notes-off" PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" \
      PADDOCK_BIN_DIR="$tmp/bin-org" PADDOCK_READY_TRIES=2 "$@" bash "$script" ${sargs:-} 2>&1
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

# Issue #405: a terminal the core starts has no WSL_DISTRO_NAME and no cmd.exe on PATH. WSL is read from
# a fake /proc, and the Windows folder is found without cmd.exe on PATH.
mkdir -p "$tmp/fproc/sys/fs/binfmt_misc"
printf 'Linux version 6.6.0-microsoft-standard-WSL2 (gcc)\n' > "$tmp/fproc/version"
nowsl() { run env -u WSL_DISTRO_NAME PATH="$stubdir:/usr/bin:/bin" PADDOCK_PROC_DIR="$tmp/fproc" "$@"; } # sargs=--check for --check
rm -rf "$app/mods" "$app/layouts" "$tmp/wslcfg"

# a. /proc/version says microsoft; cmd.exe is found at C:\Windows\System32 under the C: mount.
mkdir -p "$tmp/c/Windows/System32"; cp "$cmdbin/cmd.exe" "$tmp/c/Windows/System32/cmd.exe"
out=$(nowsl); rc=$?
[ "$rc" -eq 0 ] && cmp -s "$here/mods/org-cockpit/main.js" "$app/mods/org-cockpit/main.js" && [ ! -e "$tmp/wslcfg/herdr-app" ]
check "#405 /proc/version microsoft, cmd.exe only under C:: Windows mods folder ($out)" $?
out=$(sargs=--check nowsl)
grep -qx "ok mods: $app/mods (its cockpit equals the checkout $here)" <<<"$out"; check "#405 --check names the Windows mods folder and an equal cockpit ($out)" $?
printf '// changed\n' >> "$app/mods/org-cockpit/main.js"
out=$(sargs=--check nowsl); rc=$?
[ "$rc" -eq 1 ] && grep -q "^TODO mods: $app/mods: its cockpit differs from the checkout.*--place-only" <<<"$out"; check "#405 --check: a differing cockpit is a TODO naming --place-only" $?

# b. no cmd.exe at all, only WSLInterop: the one Windows user with a herdr-app folder is taken.
rm -rf "$tmp/c/Windows" "$app/mods" "$app/layouts"
printf 'Linux version 6.6.0 (gcc)\n' > "$tmp/fproc/version"; : > "$tmp/fproc/sys/fs/binfmt_misc/WSLInterop"
mkdir -p "$app" "$tmp/c/Users/Public"
out=$(nowsl); rc=$?
[ "$rc" -eq 0 ] && cmp -s "$here/mods/org-cockpit/main.js" "$app/mods/org-cockpit/main.js" && [ ! -e "$tmp/wslcfg/herdr-app" ]
check "#405 WSLInterop, no cmd.exe: the one C:/Users/*/.config/herdr-app is used ($out)" $?

# c. two Windows users with a herdr-app folder: not guessed; a warning, and a TODO in --check.
mkdir -p "$tmp/c/Users/other/.config/herdr-app"
out=$(nowsl); rc=$?
grep -q "^org-start: warning: WSL, but several Windows users have a herdr-app folder.*PADDOCK_APP_MODS_DIR" <<<"$out"; check "#405 several Windows users: a warning naming PADDOCK_APP_MODS_DIR ($out)" $?
out=$(sargs=--check nowsl); rc=$?
[ "$rc" -eq 1 ] && grep -q "^TODO mods: WSL, but several Windows users" <<<"$out"; check "#405 several Windows users: --check exits 1 with a TODO mods" $?

# c2. a Linux herdr-app on PATH (no window running): its own folder is right, so no warning, no TODO.
mkdir -p "$tmp/linapp"; printf '#!/bin/sh\nexit 0\n' > "$tmp/linapp/herdr-app"
chmod +x "$tmp/linapp/herdr-app"
out=$(sargs=--check nowsl PATH="$stubdir:$tmp/linapp:/usr/bin:/bin"); rc=$?
grep -q "^ok mods: $tmp/wslcfg/herdr-app/mods " <<<"$out" && ! grep -q "^TODO mods" <<<"$out"; check "#405 Linux herdr-app on PATH: WSL's own mods folder, no TODO ($out)" $?

# d. none: a warning too. And PADDOCK_APP_MODS_DIR wins over the detection.
rm -rf "$tmp/c/Users"
out=$(nowsl); grep -q "^org-start: warning: WSL, but the Windows user folder was not found" <<<"$out"; check "#405 no Windows user folder: a warning" $?
out=$(sargs=--check nowsl PADDOCK_APP_MODS_DIR="$tmp/own/mods")
grep -q "^ok mods: $tmp/own/mods " <<<"$out"; check "#405 PADDOCK_APP_MODS_DIR wins: --check names it" $?

exit "$fail"
