#!/usr/bin/env bash
# Acceptance test (Issue #270): the core is in WSL, the herdr window is on Windows. A herdr-app on PATH
# that is a Linux program looks for the window at ~/.config/herdr-app/herdr-app.sock in WSL and finds
# none. org-start must use the Windows program when the window's socket is on the Windows side, run
# layout.switch through it, and print every socket path it tried. hc, cmd.exe, wslpath and both
# herdr-app programs are stubs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-start/scripts/org-start.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

win=$tmp/c/Users/someone
winapp=$win/.config/herdr-app
exe=$win/AppData/Local/Programs/herdr-app/herdr-app.exe
home=$tmp/home
stubdir=$tmp/bin; mkdir -p "$stubdir" "$tmp/stub" "$(dirname "$exe")" "$winapp" "$home/.config/herdr-app"
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
# The Linux program: no window in WSL, so a command fails the way the Issue reports.
cat > "$stubdir/herdr-app" <<'EOF2'
#!/bin/sh
echo "linux $*" >> "$STUB/app-calls"
case "$1" in do) echo "no Herdr window at ~/.config/herdr-app/herdr-app.sock" >&2; exit 1 ;; esac
exit 0
EOF2
cat > "$exe" <<'EOF2'
#!/bin/sh
echo "windows $*" >> "$STUB/app-calls"
exit 0
EOF2
printf '#!/bin/sh\n' > "$stubdir/claude"
chmod +x "$stubdir/hc" "$stubdir/cmd.exe" "$stubdir/wslpath" "$stubdir/herdr-app" "$stubdir/claude" "$exe"

run() {
  env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
      -u APPDATA -u PADDOCK_APP_MODS_DIR -u PADDOCK_APP_LAYOUTS_DIR -u PADDOCK_APP_MACHINE \
      -u PADDOCK_SECRETARY_NAME -u HERDR_APP_HOME \
      WSL_DISTRO_NAME=Test STUB="$tmp/stub" WIN="$win" HOME="$home" PATH="$stubdir:/usr/bin:/bin" \
      XDG_CONFIG_HOME="$tmp/wslcfg" PADDOCK_CORE_CONFIG_DIR="$here/tests/fixtures/core-notes-off" PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" \
      PADDOCK_BIN_DIR="$tmp/bin-org" PADDOCK_READY_TRIES=2 "$@" bash "$script" 2>&1
}

# 1. The window is on Windows (its socket file is there), the Linux program on PATH has none.
: > "$winapp/herdr-app.sock"
out=$(run); rc=$?
[ "$rc" -eq 0 ]; check "exits 0 ($out)" $?
[ -f "$winapp/layouts/paddock.json" ] && [ ! -e "$tmp/wslcfg/herdr-app" ]; check "files placed in the Windows user's .config/herdr-app, not WSL's" $?
grep -qx "windows do layout.switch {\"name\":\"paddock\"}" "$tmp/stub/app-calls" 2>/dev/null; check "org-start ran layout.switch through the Windows program" $?
! grep -q '^linux do' "$tmp/stub/app-calls" 2>/dev/null; check "the Linux program was not asked to switch" $?
grep -qF "$home/.config/herdr-app/herdr-app.sock" <<<"$out" && grep -qF "$winapp/herdr-app.sock" <<<"$out"; check "both socket paths tried are printed" $?

# 2. The Linux window's socket exists (as well as the Windows one): the Linux program stays.
rm -f "$tmp/stub/app-calls" "$tmp/stub/secretary"
: > "$home/.config/herdr-app/herdr-app.sock"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && grep -qx "linux do layout.switch {\"name\":\"paddock\"}" "$tmp/stub/app-calls" && ! grep -q '^windows do' "$tmp/stub/app-calls"; check "Linux window socket present: the Linux program switches ($out)" $?
rm -f "$home/.config/herdr-app/herdr-app.sock"

# 3. No window anywhere: the start still succeeds, and the warning lists the paths tried.
rm -f "$tmp/stub/app-calls" "$tmp/stub/secretary" "$winapp/herdr-app.sock"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && grep -qF "$home/.config/herdr-app/herdr-app.sock" <<<"$out" && grep -qF "$winapp/herdr-app.sock" <<<"$out"; check "no window: exit 0 and both paths named ($out)" $?

exit "$fail"
