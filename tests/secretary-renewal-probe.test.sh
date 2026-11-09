#!/usr/bin/env bash
# The renewal probe's dry run (stubbed hc, no core, no Claude Code): every RESULT is PASS.
# Not the measurement itself; that is scripts/probes/secretary-renewal.sh on a host (Issue #116).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here" || exit 1
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

out=$(env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
  -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
  sh scripts/probes/secretary-renewal.sh --dry-run 2>&1); rc=$?
[ "$rc" -eq 0 ]; check "dry run exits 0" $?
[ "$(grep -c '^RESULT ' <<<"$out")" -ge 11 ] && ! grep '^RESULT ' <<<"$out" | grep -qv ': PASS'
check "every RESULT line is PASS" $?
grep -q '^== done' <<<"$out"; check "reaches the end" $?
sh scripts/probes/secretary-renewal.sh --no-such >/dev/null 2>&1; [ $? -eq 2 ]; check "unknown argument exits 2" $?
exit $fail
