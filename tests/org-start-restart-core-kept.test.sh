#!/usr/bin/env bash
# --restart-core: after hc server stop and start the kept secretary and watcher come back as plain
# shells (they still exist under their names), so org-start removes them and launches them again.
# The stub keeps them across stop/start (live), unlike tests/org-start-restart-core.test.sh, and refuses
# hc rm of a live terminal, as hc does: they must be killed first.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-start/scripts/org-start.sh
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
[ -r /proc/$$/environ ] || { echo "skip: no /proc/<pid>/environ on this system"; exit 0; }
tmp=$(mktemp -d) || exit 1
pids=
trap 'kill $pids 2>/dev/null; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/hcdir" "$tmp/cfg" "$tmp/stub"
cat > "$tmp/hcdir/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/calls"
case "$1" in
  ls) echo '[{"name":"secretary"},{"name":"watcher"}]' ;;
  server) [ "$2" != start ] || cp "$STUB/goodpid" "$STUB/pid" ;;
  get) for last; do :; done # the name is the last argument (hc get --json NAME)
       [ -f "$STUB/$last" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       echo '{"name":"x","state":"live","status":{"app":"claude-code","state":"idle"}}' ;;
  kill) echo finished > "$STUB/$2" ;;
  rm) grep -q finished "$STUB/$2" 2>/dev/null || { echo 'hc: terminal is live' >&2; exit 1; }; rm -f "$STUB/$2" ;;
  run) n=; for a in "$@"; do [ "$p" = --name ] && n=$a; p=$a; done; : > "$STUB/$n"; echo '{}' ;;
esac
exit 0
EOF2
printf '#!/bin/sh\ncat "$STUB/pid"\n' > "$tmp/bin/pgrep"; printf '#!/bin/sh\n' > "$tmp/bin/claude"
chmod +x "$tmp/hcdir/hc" "$tmp/bin/pgrep" "$tmp/bin/claude"
printf 'notes = false\n' > "$tmp/cfg/config.toml"
env -i PATH="$tmp/hcdir:/usr/bin:/bin" sleep 60 & good=$!; pids="$good"
env -i PATH=/usr/bin:/bin sleep 60 & bad=$!; pids="$pids $bad"
sleep 0.5
echo "$good" > "$tmp/stub/goodpid"; echo "$bad" > "$tmp/stub/pid"; : > "$tmp/stub/secretary"; : > "$tmp/stub/watcher"
out=$(env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET \
  -u CLAUDE_CODE_MESSAGING_TOKEN -u APPDATA STUB="$tmp/stub" PATH="$tmp/hcdir:$tmp/bin:$PATH" XDG_CONFIG_HOME="$tmp/xdg" \
  PADDOCK_CORE_CONFIG_DIR="$tmp/cfg" PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" PADDOCK_APP_MODS_DIR="$tmp/app/mods" \
  PADDOCK_APP_LAYOUTS_DIR="$tmp/app/layouts" PADDOCK_BIN_DIR="$tmp/bin-org" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_READY_TRIES=2 \
  bash "$script" --restart-core --yes 2>&1 </dev/null); rc=$?
c=$tmp/stub/calls
[ "$rc" -eq 0 ]; check "ends ready (exit $rc)" $?
ln() { grep -n "$1" "$c" | head -n1 | cut -d: -f1; }
t=$(ln '^server start'); a=$(ln '^rm secretary'); b=$(ln '^rm watcher'); ka=$(ln '^kill secretary'); kb=$(ln '^kill watcher'); r=$(ln '^run .*--name secretary'); w=$(ln '^run .*--name watcher')
[ -n "$t" ] && [ -n "$ka" ] && [ "$t" -lt "$ka" ] && [ "$ka" -lt "$a" ] && [ "$a" -lt "$r" ]; check "start, then kill and rm secretary, then the secretary is launched again" $?
[ -n "$kb" ] && [ "$t" -lt "$kb" ] && [ "$kb" -lt "$b" ] && [ "$b" -lt "$w" ]; check "start, then kill and rm watcher, then the watcher is launched again" $?
exit $fail
