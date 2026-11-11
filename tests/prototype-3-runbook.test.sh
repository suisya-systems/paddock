#!/usr/bin/env bash
# The Prototype 3 runbook's guards, without a core: syntax, help, arguments, and the refusals that
# keep a run off this repository, out of an agent and off a changed data folder. The run itself is a
# host run (Issue #243).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here" || exit 1
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
S=scripts/probes/prototype-3.sh
clean() { env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
  -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u XDG_DATA_HOME XDG_STATE_HOME="$tmp" sh "$S" "$@" </dev/null; }
tmp=$(mktemp -d) || exit 1; trap 'rm -rf "$tmp"' EXIT

sh -n "$S"; check "parses" $?
out=$(sh "$S" --help); [ $? -eq 0 ] && grep -q 'prepare --project' <<<"$out" && grep -q '6 a precondition failed' <<<"$out"; check "--help shows the whole header" $?
! LC_ALL=C grep -q '[^ -~]' <<<"$out"; check "--help is ASCII" $?
sh "$S" bogus >/dev/null 2>&1; [ $? -eq 2 ]; check "unknown phase exits 2" $?
sh "$S" >/dev/null 2>&1; [ $? -eq 2 ]; check "no phase exits 2" $?
clean prepare --repo a/b >/dev/null 2>&1; [ $? -eq 2 ]; check "prepare without --project exits 2" $?
clean prepare --project . --repo nobody >/dev/null 2>&1; [ $? -eq 2 ]; check "--repo without a slash exits 2" $?
clean prepare --project . --repo Suisya-Systems/Paddock >/dev/null 2>&1; [ $? -eq 6 ]; check "this repository is refused, any case" $?
CLAUDECODE=1 XDG_STATE_HOME="$tmp" sh "$S" prepare --project . --repo a/b >/dev/null 2>&1; [ $? -eq 4 ]; check "prepare inside an agent exits 4" $?
env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET \
  -u CLAUDE_CODE_MESSAGING_TOKEN XDG_STATE_HOME="$tmp" XDG_DATA_HOME="$tmp/data" sh "$S" prepare --project . --repo a/b >/dev/null 2>&1
[ $? -eq 6 ]; check "prepare with XDG_DATA_HOME set exits 6 (host rule)" $?
clean prepare --project "it's" --repo a/b >/dev/null 2>&1; [ $? -eq 2 ]; check "a path with an apostrophe exits 2" $?
clean watch >/dev/null 2>&1; [ $? -eq 2 ]; check "watch without --task-id exits 2" $?
clean watch --task-id 'Bad Id' >/dev/null 2>&1; [ $? -eq 2 ]; check "bad task id exits 2" $?
clean collect --task-id p3-none >/dev/null 2>&1; [ $? -eq 6 ]; check "unknown run exits 6" $?
mkdir -p "$tmp/paddock-proto3/p3-x" && : > "$tmp/paddock-proto3/p3-x/run.env"
clean note --task-id p3-x --touch "typed into w-p3-x" >/dev/null 2>&1 && grep -q "$(printf '\ttouch\ttyped into')" "$tmp/paddock-proto3/p3-x/notes.tsv"
check "note --touch records a touch" $?
# The fixture job calls the checker as this repository's own acceptance job does.
l='bash "$RUNNER_TEMP/acceptance-check.sh" "$base"'
grep -qF "$l" scripts/probes/prototype-3-acceptance.yml && grep -qF "$l" .github/workflows/ci.yml
check "the fixture job calls the checker as ci.yml does" $?
exit $fail
