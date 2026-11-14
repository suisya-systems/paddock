#!/usr/bin/env bash
# Issue #328 (decision 0007): `org-start.sh --check` is the read-only first-run check. It prints
# `ok <step>: ...` or `TODO <step>: <exact fix>` for every step (not only the first failure), exits 0
# only when nothing is left for a person, places nothing, calls no hc. org-start itself gains the
# core PATH check (exit 10), read from /proc/<core pid>/environ.
# The "core" is a real sleep started with a chosen environment; a stub pgrep names its pid.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-start/scripts/org-start.sh
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
[ -r /proc/$$/environ ] || { echo "skip: no /proc/<pid>/environ on this system"; exit 0; }
tmp=$(mktemp -d) || exit 1
pids=
trap 'kill $pids 2>/dev/null; rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/hcdir" "$tmp/cfg" "$tmp/proj" "$tmp/cc" "$tmp/stub"
printf '#!/bin/sh\necho "$*" >> "$STUB/calls"\nexit 0\n' > "$tmp/hcdir/hc"
printf '#!/bin/sh\necho "$STUB_PID"\n' > "$tmp/bin/pgrep"
printf '#!/bin/sh\n' > "$tmp/bin/claude"
chmod +x "$tmp/hcdir/hc" "$tmp/bin/pgrep" "$tmp/bin/claude"
printf 'notes = false\n' > "$tmp/cfg/config.toml"
proj=$(cd "$tmp/proj" && pwd -P)
printf '{"projects": {"%s": {"hasTrustDialogAccepted": true}}}\n' "$proj" > "$tmp/cc/.claude.json"

core() { # core <PATH of the core>: sets $pid to a process with only that PATH
  env -i PATH="$1" sleep 60 & pid=$!; pids="$pids $pid"
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(cat /proc/$pid/comm 2>/dev/null)" = sleep ] && break; sleep 0.2; done
}
run() { # run <args...>; env knobs from $cfgdir, $ccdir, $procdir
  env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u APPDATA \
      STUB="$tmp/stub" STUB_PID="$pid" PATH="$tmp/hcdir:$tmp/bin:$PATH" XDG_CONFIG_HOME="$tmp/xdg" \
      CLAUDE_CONFIG_DIR="${ccdir:-$tmp/cc}" PADDOCK_CORE_CONFIG_DIR="${cfgdir:-$tmp/cfg}" \
      PADDOCK_PROC_DIR="${procdir:-/proc}" PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" \
      PADDOCK_APP_MODS_DIR="$tmp/app/mods" PADDOCK_APP_LAYOUTS_DIR="$tmp/app/layouts" \
      PADDOCK_BIN_DIR="$tmp/bin-org" PADDOCK_READY_TRIES=2 bash "$script" "$@" 2>&1
}
untouched() { [ ! -e "$tmp/core/templates" ] && [ ! -e "$tmp/bin-org" ] && [ ! -e "$tmp/stub/calls" ]; }

# 1. Everything fine: ok lines, exit 0, nothing placed, no hc call.
core "$tmp/hcdir:/usr/bin:/bin"
out=$(run --check --project "$tmp/proj"); rc=$?
[ "$rc" -eq 0 ]; check "all fine: --check exits 0" $?
for s in claude notes core-path trust; do grep -q "^ok $s:" <<<"$out"; check "all fine: an ok line for $s" $?; done
! grep -q '^TODO' <<<"$out"; check "all fine: no TODO line" $?
untouched; check "all fine: nothing placed and no hc call" $?

# 2. Three TODOs at once: every one is printed with its exact fix; exit 1.
core /usr/bin:/bin
rm -f "$tmp/cc/.claude.json"
printf 'shell = ["nu"]\n' > "$tmp/cfg2.toml"; mkdir -p "$tmp/cfg2"; cp "$tmp/cfg2.toml" "$tmp/cfg2/config.toml"
out=$(cfgdir=$tmp/cfg2 run --check --project "$tmp/proj"); rc=$?
[ "$rc" -eq 1 ]; check "three TODOs: exit 1" $?
grep -q "^TODO notes: .*notes = false.*$tmp/cfg2/config.toml" <<<"$out"; check "TODO notes names the line and the file" $?
grep -q "^TODO core-path: .*$tmp/hcdir.*login shell" <<<"$out"; check "TODO core-path names hc's folder and a login shell" $?
grep -q "^TODO trust: .*$proj.*claude" <<<"$out"; check "TODO trust names the clone and claude" $?
untouched; check "three TODOs: nothing placed, no hc call" $?
[ ! -e "$tmp/cfg2/config.toml.new" ] && [ "$(cat "$tmp/cfg2/config.toml")" = 'shell = ["nu"]' ]; check "the core config is not written" $?

# 3. /proc not readable: the core PATH is skipped and the line says why; exit 0 when the rest is fine.
printf '{"projects": {"%s": {"hasTrustDialogAccepted": true}}}\n' "$proj" > "$tmp/cc/.claude.json"
core /usr/bin:/bin
out=$(procdir=$tmp/no-proc run --check --project "$tmp/proj"); rc=$?
[ "$rc" -eq 0 ] && grep -q '^skip core-path: .*/proc' <<<"$out" && grep -qi 'linux' <<<"$out"; check "no /proc: skip line names /proc and Linux/WSL, exit 0" $?

# 4. No core running: nothing to read, skip.
pid=; out=$(run --check); rc=$?
[ "$rc" -eq 0 ] && grep -q '^skip core-path:' <<<"$out"; check "no core running: skip core-path" $?

# 5. --project without --check is refused.
out=$(run --project "$tmp/proj"); rc=$?
[ "$rc" -eq 2 ]; check "--project without --check: exit 2" $?

# 6. org-start itself: a core without hc on its PATH stops it (exit 10) before anything is placed.
core /usr/bin:/bin
out=$(run); rc=$?
[ "$rc" -eq 10 ] && grep -q "$tmp/hcdir" <<<"$out" && grep -qi 'login shell' <<<"$out"; check "org-start: bad core PATH exits 10 naming the folder" $?
untouched; check "org-start: nothing placed and no hc call before the stop" $?
core "$tmp/hcdir:/usr/bin:/bin"
out=$(run); rc=$?
[ "$rc" -ne 10 ]; check "org-start: hc on the core's PATH does not stop with 10" $?
exit "$fail"
