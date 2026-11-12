#!/usr/bin/env bash
# The Prototype 3 host steps run inside herdr (Issue #271): `prepare` no longer needs a login shell
# outside herdr with no agent above it. The rule it kept is the host rule behind that: a run never
# starts the core, so the core's environment is not an agent's. `prepare` refuses when the core is
# not running, and does not refuse because of the shell's own variables. No core runs here.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here" || exit 1
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
S=scripts/probes/prototype-3.sh
tmp=$(mktemp -d) || exit 1; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
# No hc call can tell whether the core runs without possibly starting it (even `hc server status`
# starts a stopped core on Unix, hc 0.1.20), so prepare looks for the process `herdr-core serve`.
# A stub pgrep answers for it by STUB_CORE (up|down), so the result never depends on the host's own
# core; a stub hc logs every call and fails, so a call made while the core is down shows.
cat > "$tmp/bin/pgrep" <<'EOF2'
#!/bin/sh
[ "${STUB_CORE:-down}" = up ]
EOF2
cat > "$tmp/bin/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB_CALLS"
exit 1
EOF2
chmod +x "$tmp/bin/hc" "$tmp/bin/pgrep"
prep() { # prep <core up|down> [VAR=value ...]: prepare against the stub, other variables of an agent unset
  core=$1; shift
  env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET \
    -u CLAUDE_CODE_MESSAGING_TOKEN -u XDG_DATA_HOME "$@" PATH="$tmp/bin:$PATH" STUB_CORE="$core" STUB_CALLS="$tmp/calls" \
    XDG_STATE_HOME="$tmp" sh "$S" prepare --project . --repo a/b </dev/null
}

# 1. Agent variables in the shell are no reason to refuse: a terminal in herdr takes the core's
#    environment, and the core is already running.
: > "$tmp/calls"
prep up CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=x > "$tmp/o1" 2>&1; rc=$?
[ "$rc" -ne 4 ] && ! grep -qi 'agent' "$tmp/o1" && ! grep -qi 'core is not running' "$tmp/o1"
check "prepare does not refuse for agent variables, and passes the core guard (core running)" $?

# 2. The core is not running: stop before anything that could start it, and say so.
: > "$tmp/calls"
prep down > "$tmp/o2" 2>&1; rc=$?
[ "$rc" -eq 6 ] && grep -qi 'core is not running' "$tmp/o2"; check "prepare exits 6 saying the core is not running" $?
[ ! -s "$tmp/calls" ]; check "prepare made no hc call while the core is down" $?
: > "$tmp/calls"
prep down CLAUDECODE=1 > "$tmp/o3" 2>&1; rc=$?
[ "$rc" -eq 6 ] && grep -qi 'core is not running' "$tmp/o3" && [ ! -s "$tmp/calls" ]
check "with agent variables set, a missing core is still the reason, and no hc is called" $?

# 3. The host rule on the data folder stays.
env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET \
  -u CLAUDE_CODE_MESSAGING_TOKEN XDG_DATA_HOME="$tmp/data" PATH="$tmp/bin:$PATH" STUB_CORE=up STUB_CALLS="$tmp/calls" XDG_STATE_HOME="$tmp" \
  sh "$S" prepare --project . --repo a/b </dev/null >/dev/null 2>&1
[ $? -eq 6 ]; check "prepare with XDG_DATA_HOME set still exits 6" $?

# 4. The text no longer asks for a shell outside herdr (the history of the earlier runs, from '## Result', is a record).
bad='login shell|no agent above|not inside an agent|outside herdr'
! sed -n '2,32p' "$S" | grep -n -i -E "$bad"; check "the runbook header asks for no shell outside herdr" $?
! sed -n '/^  tee "\$RUN\/steps.txt"/,/^EOF$/p' "$S" | grep -n -i -E "$bad"; check "the printed steps ask for no shell outside herdr" $?
! sed '/^## Result/,$d' docs/design/prototype-3.md | grep -n -i -E "$bad"; check "the design text asks for no shell outside herdr" $?
sed '/^## Result/,$d' docs/design/prototype-3.md | grep -qi 'inside herdr' && sed -n '2,32p' "$S" | grep -qi 'inside herdr'
check "the header and the design text say the steps run inside herdr" $?
exit $fail
