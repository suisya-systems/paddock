#!/usr/bin/env bash
# A kept watcher comes back after a core or Windows restart as a live plain shell (label kept, no org-watch.sh).
# org-start kills and removes it and starts the watcher again; a watcher that runs org-watch.sh, a terminal named
# watcher without the paddock_role=watcher label, and the plain shell running org-start itself are left alone.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-start/scripts/org-start.sh
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
[ -r /proc/$$/cmdline ] || { echo "skip: no /proc on this system"; exit 0; }
tmp=$(mktemp -d) || exit 1
pids=
trap 'kill $pids 2>/dev/null; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/hcdir" "$tmp/bin" "$tmp/cfg" "$tmp/stub"
# stub/watcher holds "<pid> <label>": the terminal's process and its paddock_role label
cat > "$tmp/hcdir/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/calls"
for last; do :; done
case "$1" in
  get) [ -f "$STUB/$last" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       if [ "$last" = watcher ]; then read -r p l < "$STUB/watcher"
         [ "$p" = finished ] && { echo '{"address":"t3","state":"finished","labels":{"paddock_role":"watcher"}}'; exit 0; }
         echo "{\"address\":\"t3w\",\"name\":\"watcher\",\"pid\":$p,\"state\":\"live\",\"template\":null,\"status\":null,\"labels\":{\"paddock_role\":\"$l\"}}"
       else echo '{"address":"t2","name":"x","state":"live","template":"secretary","status":{"app":"claude-code","state":"idle"}}'; fi ;;
  kill) echo finished > "$STUB/$last" ;;
  rm) grep -q finished "$STUB/$last" 2>/dev/null || { echo 'hc: terminal is live' >&2; exit 1; }; rm -f "$STUB/$last" ;;
  run) n=; p=; for a in "$@"; do [ "$p" = --name ] && n=$a; p=$a; done; : > "$STUB/$n"; echo '{}' ;;
esac
exit 0
EOF2
printf '#!/bin/sh\n' > "$tmp/bin/claude"
env -i PATH="$tmp/hcdir:/usr/bin:/bin" sleep 60 & core=$!
printf 'sleep 60\n' > "$tmp/org-watch.sh"
sleep 60 & shell=$!
sh "$tmp/org-watch.sh" & watch=$!
pids="$core $shell $watch"
printf '#!/bin/sh\necho %s\n' "$core" > "$tmp/bin/pgrep"
chmod +x "$tmp/hcdir/hc" "$tmp/bin/claude" "$tmp/bin/pgrep"; sleep 0.5
printf 'notes = false\n' > "$tmp/cfg/config.toml"
run() { env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET \
  -u CLAUDE_CODE_MESSAGING_TOKEN -u APPDATA -u HC_TERMINAL_SOCKET "$@" STUB="$tmp/stub" PATH="$tmp/hcdir:$tmp/bin:$PATH" XDG_CONFIG_HOME="$tmp/xdg" \
  PADDOCK_CORE_CONFIG_DIR="$tmp/cfg" PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" PADDOCK_APP_MODS_DIR="$tmp/app/mods" \
  PADDOCK_APP_LAYOUTS_DIR="$tmp/app/layouts" PADDOCK_BIN_DIR="$tmp/bin-org" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_READY_TRIES=2 \
  bash "$script" 2>&1 </dev/null; }
c=$tmp/stub/calls
ln() { grep -n "$1" "$c" | head -n1 | cut -d: -f1; }
: > "$tmp/stub/secretary"
# a plain shell: killed, removed, the watcher started again
echo "$shell watcher" > "$tmp/stub/watcher"; : > "$c"
out=$(run -u HC_TERMINAL_ID); rc=$?
k=$(ln '^kill watcher'); a=$(ln '^rm watcher'); r=$(ln '^run .*--name watcher')
[ "$rc" -eq 0 ] && [ -n "$k" ] && [ -n "$a" ] && [ -n "$r" ] && [ "$k" -lt "$a" ] && [ "$a" -lt "$r" ]; check "plain shell: kill, rm, then the watcher is started (exit $rc)" $?
grep -q 'plain shell with no org-watch.sh running' <<<"$out"; check "says it removed the plain shell" $?
# a watcher that runs org-watch.sh is left alone
echo "$watch watcher" > "$tmp/stub/watcher"; : > "$c"
out=$(run -u HC_TERMINAL_ID); rc=$?
[ "$rc" -eq 0 ] && ! grep -q '^kill watcher' "$c" && grep -q 'watcher already exists' <<<"$out"; check "a running watcher is left alone" $?
# a terminal named watcher without the label is never touched
echo "$shell other" > "$tmp/stub/watcher"; : > "$c"
out=$(run -u HC_TERMINAL_ID); rc=$?
! grep -q '^kill watcher' "$c" && grep -q 'watcher already exists' <<<"$out"; check "an unlabelled watcher terminal is left alone" $?
# run from that very plain shell: warned, not ended
echo "$shell watcher" > "$tmp/stub/watcher"; : > "$c"
out=$(run HC_TERMINAL_ID=t3w); rc=$?
! grep -q '^kill watcher' "$c" && grep -q 'this shell is the watcher terminal' <<<"$out"; check "run from the plain shell itself: warned, no kill" $?
exit $fail
