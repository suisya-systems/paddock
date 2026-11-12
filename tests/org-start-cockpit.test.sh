#!/usr/bin/env bash
# Acceptance test (Issue #195): org-start also places the org-cockpit mod and the layout on the
# app's host, keeps a "secretary" prop already in the installed layout, and runs the app's check
# when herdr-app is on PATH. hc and herdr-app are stubs on PATH; no core and no display.
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
case "$1" in
  get) [ -f "$STUB/secretary" ] || exit 1
       echo '{"name":"secretary","state":"live","status":{"app":"claude-code","state":"idle"}}' ;;
  run) : > "$STUB/secretary" ;;
esac
exit 0
EOF2
cat > "$stubdir/herdr-app" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/app-calls"
exit 0
EOF2
chmod +x "$stubdir/hc" "$stubdir/herdr-app"
printf '#!/bin/sh\n' > "$stubdir/claude"; chmod +x "$stubdir/claude" # Issue #268: org-start needs claude on PATH

run() {
  env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
      STUB="$tmp/stub" PATH="$stubdir:$PATH" \
      PADDOCK_CORE_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/core-notes-off" PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" PADDOCK_APP_MODS_DIR="$tmp/app/mods" \
      PADDOCK_APP_LAYOUTS_DIR="$tmp/app/layouts" PADDOCK_BIN_DIR="$tmp/bin-org" \
      PADDOCK_READY_TRIES=2 "$@" bash "$script" 2>&1
}
blocks=$(grep -c '"mod": "org-cockpit"' "$here/layouts/paddock.json")

# First run: mod and layout placed, the app's check run on the cockpit mod.
out=$(run); rc=$?
[ "$rc" -eq 0 ]; check "first run exits 0 ($out)" $?
cmp -s "$here/mods/org-cockpit/main.js" "$tmp/app/mods/org-cockpit/main.js" \
  && cmp -s "$here/mods/org-cockpit/mod.json" "$tmp/app/mods/org-cockpit/mod.json"; check "org-cockpit mod placed" $?
cmp -s "$here/layouts/paddock.json" "$tmp/app/layouts/paddock.json"; check "layout placed unchanged when none was installed" $?
grep -qx "check $tmp/app/mods/org-cockpit" "$tmp/stub/app-calls"; check "herdr-app check runs on the placed cockpit mod" $?

# An installed layout with a secretary prop keeps it (the person's machine, e.g. wsl/secretary).
mkdir -p "$tmp/app/layouts"
sed -e 's/"gap": 12,/"gap": 99,/' -e 's/"props": { "role"/"props": { "secretary": "wsl\/secretary", "role"/' "$here/layouts/paddock.json" > "$tmp/app/layouts/paddock.json"
out=$(run); rc=$?
[ "$rc" -eq 0 ]; check "run over a layout with a secretary prop exits 0" $?
[ "$(grep -c '"secretary": *"wsl/secretary"' "$tmp/app/layouts/paddock.json")" -eq "$blocks" ]; check "secretary prop kept in every org-cockpit block ($blocks)" $?
! grep -q "\"gap\": 99" "$tmp/app/layouts/paddock.json" && grep -q "\"role\": \"approval\"" "$tmp/app/layouts/paddock.json"; check "the rest of the installed layout is replaced by the repository one" $?
cp "$tmp/app/layouts/paddock.json" "$tmp/once.json"; run >/dev/null
cmp -s "$tmp/once.json" "$tmp/app/layouts/paddock.json"; check "a rerun leaves the layout as it was (idempotent)" $?

# Without the app's check on PATH nothing fails; a failing check warns and does not stop the start.
rm "$stubdir/herdr-app"; rm -f "$tmp/stub/secretary"
out=$(run); rc=$?
[ "$rc" -eq 0 ]; check "no herdr-app on PATH: exit 0" $?
cat > "$stubdir/herdr-app" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/app-calls"; [ "$1" != check ] || exit 1
EOF2
chmod +x "$stubdir/herdr-app"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && grep -qi 'check' <<<"$out"; check "a failing herdr-app check warns, exit 0" $?

exit "$fail"
