#!/usr/bin/env bash
# The Prototype 2 runbook's guards, without a core: syntax, help, arguments, and the refusals that
# keep a run off this repository and out of an agent. The run itself is a host run (Issue #59).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here" || exit 1
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
S=scripts/probes/prototype-2.sh
clean() { env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
  -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN XDG_STATE_HOME="$tmp" sh "$S" "$@"; }
tmp=$(mktemp -d) || exit 1; trap 'rm -rf "$tmp"' EXIT

sh -n "$S"; check "parses" $?
out=$(sh "$S" --help); [ $? -eq 0 ] && grep -q 'prepare --project' <<<"$out"; check "--help" $?
! LC_ALL=C grep -q '[^ -~]' <<<"$out"; check "--help is ASCII" $?
sh "$S" bogus >/dev/null 2>&1; [ $? -eq 2 ]; check "unknown phase exits 2" $?
sh "$S" >/dev/null 2>&1; [ $? -eq 2 ]; check "no phase exits 2" $?
clean prepare --repo a/b >/dev/null 2>&1; [ $? -eq 2 ]; check "prepare without --project exits 2" $?
clean prepare --project . --repo nobody >/dev/null 2>&1; [ $? -eq 2 ]; check "--repo without a slash exits 2" $?
clean prepare --project . --repo Suisya-Systems/Paddock >/dev/null 2>&1; [ $? -eq 6 ]; check "this repository is refused, any case" $?
CLAUDECODE=1 XDG_STATE_HOME="$tmp" sh "$S" prepare --project . --repo a/b >/dev/null 2>&1; [ $? -eq 4 ]; check "prepare inside an agent exits 4" $?
clean watch >/dev/null 2>&1; [ $? -eq 2 ]; check "watch without --task-id exits 2" $?
clean watch --task-id 'Bad Id' >/dev/null 2>&1; [ $? -eq 2 ]; check "bad task id exits 2" $?
clean collect --task-id p2-none >/dev/null 2>&1; [ $? -eq 6 ]; check "unknown run exits 6" $?
mkdir -p "$tmp/paddock-proto2/p2-x" && : > "$tmp/paddock-proto2/p2-x/run.env"
clean note --task-id p2-x --touch "typed into w-p2-x" >/dev/null 2>&1 && grep -q "	touch	typed into" "$tmp/paddock-proto2/p2-x/notes.tsv"
check "note --touch records a touch" $?
exit $fail
