#!/usr/bin/env bash
# `org-start.sh --restart-core` (decision 0007, revised): the one command that fixes a core whose PATH
# has no hc (exit 10). It refuses inside an agent, lists the terminals it would end (hc ls) and asks
# y/N (--yes skips the question), checks hc is on this login shell's PATH, runs hc server stop then
# hc server start, and then the ordinary org-start to the end.
# The "core" is a real sleep started with a chosen environment; a stub pgrep names its pid (file $STUB/pid);
# the stub hc's `server start` points that file at a core that has hc on its PATH.
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
  ls) echo '[{"name":"secretary"},{"name":"w-demo-task"}]' ;;
  server)
    case "$2" in
      stop) [ -z "${STUB_STOP_FAIL:-}" ] || { echo 'hc: stop failed' >&2; exit 1; }
            rm -f "$STUB/secretary" ;;
      start) [ -z "${STUB_START_FAIL:-}" ] || { echo 'hc: start failed' >&2; exit 1; }
             cp "$STUB/goodpid" "$STUB/pid" ;;
    esac ;;
  get) [ -f "$STUB/secretary" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       echo '{"name":"secretary","state":"live","status":{"app":"claude-code","state":"idle"}}' ;;
  run) : > "$STUB/secretary"; echo '{"name":"secretary"}' ;;
  *) echo ok ;;
esac
exit 0
EOF2
printf '#!/bin/sh\ncat "$STUB/pid"\n' > "$tmp/bin/pgrep"
printf '#!/bin/sh\n' > "$tmp/bin/claude"
chmod +x "$tmp/hcdir/hc" "$tmp/bin/pgrep" "$tmp/bin/claude"
printf 'notes = false\n' > "$tmp/cfg/config.toml"

core() { # core <PATH of the core>: prints the pid of a process with only that PATH
  env -i PATH="$1" sleep 60 & p=$!; pids="$pids $p"
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(cat /proc/$p/comm 2>/dev/null)" = sleep ] && break; sleep 0.2; done
  echo "$p"
}
reset() { # reset <bad|good>: the running core lacks hc (bad) or has it (good); a restart gives a good one
  : > "$tmp/stub/calls"; rm -f "$tmp/stub/secretary"
  core "$tmp/hcdir:/usr/bin:/bin" > "$tmp/stub/goodpid"; pids="$pids $(cat "$tmp/stub/goodpid")"
  if [ "$1" = bad ]; then core /usr/bin:/bin > "$tmp/stub/pid"; else cp "$tmp/stub/goodpid" "$tmp/stub/pid"; fi
}
run() { # run <stdin text> <args...>; extra environment words come from $envx
  local in=$1; shift
  printf '%s' "$in" | env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u APPDATA ${envx:-} \
      STUB="$tmp/stub" PATH="${pathx:-$tmp/hcdir:$tmp/bin:$PATH}" XDG_CONFIG_HOME="$tmp/xdg" \
      PADDOCK_CORE_CONFIG_DIR="$tmp/cfg" PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" \
      PADDOCK_APP_MODS_DIR="$tmp/app/mods" PADDOCK_APP_LAYOUTS_DIR="$tmp/app/layouts" \
      PADDOCK_BIN_DIR="$tmp/bin-org" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_READY_TRIES=2 \
      bash "$script" "$@" 2>&1
}
calls() { cat "$tmp/stub/calls"; }
no_server() { ! grep -q '^server' "$tmp/stub/calls"; }

# 0. Without the option a core with no hc on its PATH still stops org-start with exit 10, and the line names the option.
reset bad
out=$(run "" ); rc=$?
[ "$rc" -eq 10 ] && grep -q -- '--restart-core' <<<"$out" && no_server; check "exit 10 names --restart-core and ends nothing" $?

# 1. Inside an agent: refused before any hc call, even with --yes.
reset bad
out=$(envx="CLAUDECODE=1" run "y
" --restart-core --yes); rc=$?
[ "$rc" -eq 4 ] && [ ! -s "$tmp/stub/calls" ]; check "inside an agent: exit 4, no hc call at all" $?

# 2. The answer is No (or nothing, or anything but yes): the terminals are listed, nothing is ended.
for ans in "n
" "" "
" "maybe
"; do
  reset bad
  out=$(run "$ans" --restart-core); rc=$?
  grep -q 'w-demo-task' <<<"$out" && grep -q '^ls' "$tmp/stub/calls"; check "answer '${ans%$'\n'}': the terminals to end are listed" $?
  [ "$rc" -eq 11 ] && no_server && ! grep -q '^run' "$tmp/stub/calls"; check "answer '${ans%$'\n'}': exit 11, nothing stopped, nothing started" $?
done

# 3. Yes (typed, or --yes): stop, then start, then the ordinary org-start to its end.
for how in typed flag; do
  reset bad
  if [ "$how" = typed ]; then out=$(run "y
" --restart-core); rc=$?; else out=$(run "" --restart-core --yes); rc=$?; fi
  [ "$rc" -eq 0 ] && grep -q 'org-start: ready' <<<"$out"; check "$how yes: ends ready (exit $rc)" $?
  s=$(grep -n '^server stop' "$tmp/stub/calls" | head -n1 | cut -d: -f1)
  t=$(grep -n '^server start' "$tmp/stub/calls" | head -n1 | cut -d: -f1)
  r=$(grep -n '^run ' "$tmp/stub/calls" | head -n1 | cut -d: -f1)
  [ -n "$s" ] && [ -n "$t" ] && [ -n "$r" ] && [ "$s" -lt "$t" ] && [ "$t" -lt "$r" ]; check "$how yes: hc server stop, then hc server start, then the secretary is started" $?
  [ "$(grep -c '^server stop' "$tmp/stub/calls")" -eq 1 ]; check "$how yes: one stop" $?
done

# 4. hc is not on this login shell's PATH: nothing is stopped.
reset bad
out=$(pathx="$tmp/bin:/usr/bin:/bin" run "y
" --restart-core --yes); rc=$?
[ "$rc" -eq 3 ] && [ ! -s "$tmp/stub/calls" ]; check "no hc on this shell's PATH: exit 3, no hc call, nothing stopped" $?

# 5. The core already has hc on its PATH: nothing to fix, nothing is ended, the ordinary start goes on.
reset good
out=$(run "" --restart-core --yes); rc=$?
[ "$rc" -eq 0 ] && no_server && grep -q 'org-start: ready' <<<"$out"; check "core already fine: no stop, ends ready" $?

# 6. A failed stop or start ends with exit 5 and a next: line; a failed stop never starts.
reset bad
out=$(envx="STUB_STOP_FAIL=1" run "" --restart-core --yes); rc=$?
[ "$rc" -eq 5 ] && grep -q '^next:' <<<"$out" && ! grep -q '^server start' "$tmp/stub/calls"; check "stop fails: exit 5, next: line, no start" $?
reset bad
out=$(envx="STUB_START_FAIL=1" run "" --restart-core --yes); rc=$?
[ "$rc" -eq 5 ] && grep -q '^next:.*hc server start' <<<"$out"; check "start fails: exit 5, next: line names hc server start" $?

# 7. The option does not go with --check or --place-only, and --yes only goes with it.
reset bad
out=$(run "" --restart-core --check); rc=$?; [ "$rc" -eq 2 ]; check "--restart-core with --check: exit 2" $?
out=$(run "" --restart-core --place-only); rc=$?; [ "$rc" -eq 2 ]; check "--restart-core with --place-only: exit 2" $?
out=$(run "" --yes); rc=$?; [ "$rc" -eq 2 ] && no_server; check "--yes alone: exit 2" $?

exit $fail
