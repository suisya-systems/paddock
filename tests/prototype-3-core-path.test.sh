#!/usr/bin/env bash
# Issue #305: a core started without hc's folder on its PATH gives every terminal that PATH, so the
# hooks fail with exit 127 and no approval card appears. `prepare` reads the running core's PATH from
# /proc/<pid>/environ (it never starts the core) and stops, naming the folder and how to restart.
# The "core" here is a real sleep started with a chosen environment; a stub pgrep names its pid.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here" || exit 1
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
[ -r /proc/$$/environ ] || { echo "skip: no /proc/<pid>/environ on this system"; exit 0; }
S=scripts/probes/prototype-3.sh
tmp=$(mktemp -d) || exit 1
pids=
trap 'kill $pids 2>/dev/null; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/hcdir"
printf '#!/bin/sh\necho "$*" >> "$STUB_CALLS"\nexit 1\n' > "$tmp/hcdir/hc"
printf '#!/bin/sh\necho "$STUB_PID"\n' > "$tmp/bin/pgrep"
chmod +x "$tmp/hcdir/hc" "$tmp/bin/pgrep"

core() { # core <PATH of the core>: sets $pid to a process with only that PATH
  env -i PATH="$1" sleep 60 & pid=$!; pids="$pids $pid"
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(cat /proc/$pid/comm 2>/dev/null)" = sleep ] && break; sleep 0.2; done
}
prep() { # prep <out file>
  env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET \
    -u CLAUDE_CODE_MESSAGING_TOKEN -u XDG_DATA_HOME PATH="$tmp/hcdir:$tmp/bin:$PATH" STUB_PID="$pid" \
    STUB_CALLS="$tmp/calls" XDG_STATE_HOME="$tmp" sh "$S" prepare --project . --repo a/b </dev/null > "$1" 2>&1
}

# 1. The core's PATH lacks hc's folder: exit 6, the folder and a login-shell restart are named, no hc call.
core /usr/bin:/bin; : > "$tmp/calls"
prep "$tmp/o1"; rc=$?
[ "$rc" -eq 6 ]; check "core without hc on its PATH: prepare exits 6" $?
grep -qF "$tmp/hcdir" "$tmp/o1" && grep -qi 'login shell' "$tmp/o1"; check "the refusal names the missing folder and a login shell" $?
[ ! -s "$tmp/calls" ]; check "no hc call was made" $?

# 2. hc's folder is on the core's PATH: the guard does not refuse.
core "$tmp/hcdir:/usr/bin:/bin"
prep "$tmp/o2"
! grep -qi "PATH" "$tmp/o2"; check "core with hc on its PATH: no PATH refusal" $?
exit "$fail"
