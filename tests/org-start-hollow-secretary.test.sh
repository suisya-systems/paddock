#!/usr/bin/env bash
# A kept secretary whose claude ended is a live plain shell under the same name (template null, no status).
# org-start kills and removes it, then launches the secretary again; run from that very shell it refuses.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-start/scripts/org-start.sh
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
tmp=$(mktemp -d) || exit 1
[ -r /proc/$$/environ ] || { echo "skip: no /proc/<pid>/environ on this system"; exit 0; }
pids=
trap 'kill $pids 2>/dev/null; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/hcdir" "$tmp/bin" "$tmp/cfg" "$tmp/stub"
cat > "$tmp/hcdir/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/calls"
for last; do :; done
case "$1" in
  get) [ -f "$STUB/$last" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       if grep -q hollow "$STUB/$last"; then echo '{"address":"t1x","name":"secretary","state":"live","template":null,"status":null}'
       else echo '{"address":"t2","name":"x","state":"live","template":"secretary","status":{"app":"claude-code","state":"idle"}}'; fi ;;
  kill) echo finished > "$STUB/$last" ;;
  rm) grep -q finished "$STUB/$last" 2>/dev/null || { echo 'hc: terminal is live' >&2; exit 1; }; rm -f "$STUB/$last" ;;
  run) n=; p=; for a in "$@"; do [ "$p" = --name ] && n=$a; p=$a; done; : > "$STUB/$n"; echo '{}' ;;
esac
exit 0
EOF2
printf '#!/bin/sh\n' > "$tmp/bin/claude"
env -i PATH="$tmp/hcdir:/usr/bin:/bin" sleep 60 & pids=$!
printf '#!/bin/sh\necho %s\n' "$pids" > "$tmp/bin/pgrep"
chmod +x "$tmp/hcdir/hc" "$tmp/bin/claude" "$tmp/bin/pgrep"; sleep 0.5
printf 'notes = false\n' > "$tmp/cfg/config.toml"
run() { env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET \
  -u CLAUDE_CODE_MESSAGING_TOKEN -u APPDATA -u HC_TERMINAL_SOCKET "$@" STUB="$tmp/stub" PATH="$tmp/hcdir:$tmp/bin:$PATH" XDG_CONFIG_HOME="$tmp/xdg" \
  PADDOCK_CORE_CONFIG_DIR="$tmp/cfg" PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" PADDOCK_APP_MODS_DIR="$tmp/app/mods" \
  PADDOCK_APP_LAYOUTS_DIR="$tmp/app/layouts" PADDOCK_BIN_DIR="$tmp/bin-org" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_READY_TRIES=2 \
  bash "$script" 2>&1 </dev/null; }
echo hollow > "$tmp/stub/secretary"; : > "$tmp/stub/watcher"
out=$(run -u HC_TERMINAL_ID); rc=$?
c=$tmp/stub/calls
[ "$rc" -eq 0 ]; check "ends ready (exit $rc): $out" $?
ln() { grep -n "$1" "$c" | head -n1 | cut -d: -f1; }
k=$(ln '^kill secretary'); a=$(ln '^rm secretary'); r=$(ln '^run .*--name secretary')
[ -n "$k" ] && [ -n "$a" ] && [ -n "$r" ] && [ "$k" -lt "$a" ] && [ "$a" -lt "$r" ]; check "kill, rm, then the secretary is launched again" $?
grep -q 'plain shell left' <<<"$out"; check "says it removed the plain shell" $?
# from that very shell: refused, nothing ended
echo hollow > "$tmp/stub/secretary"; : > "$c"
out=$(run HC_TERMINAL_ID=t1x); rc=$?
[ "$rc" -eq 4 ] && ! grep -q '^kill' "$c"; check "run from the hollow shell itself: exit 4, no kill" $?
# a real secretary is left alone
: > "$tmp/stub/secretary"; : > "$c"
out=$(run -u HC_TERMINAL_ID); rc=$?
[ "$rc" -eq 0 ] && ! grep -q '^kill' "$c" && grep -q 'already exists' <<<"$out"; check "a real secretary is left alone" $?
exit $fail
