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
# The request is sent by the runbook (Issue #247): watch sends the saved request once the secretary
# reports a status, records that it did (not as a touch), and does not send it twice.
R="$tmp/paddock-proto3/p3-s"; mkdir -p "$R" "$tmp/bin" "$tmp/home"
printf "PROJECT='%s'\nREPO='a/b'\nBASE='main'\nWT='%s'\nBR='work/p3-s'\nSTART='2000-01-01T00:00:00Z'\n" "$tmp/none" "$tmp/none-wt" > "$R/run.env"
printf 'REQUEST TEXT for p3-s\n' > "$R/request.txt"
cat > "$tmp/bin/hc" <<'EOF2'
#!/bin/sh
case "$1" in
  get) printf '{"name":"secretary","status":{"app":"claude-code","state":"idle"}}\n'; exit 0 ;;
  send) shift; echo "$*" >> "$STUBSENT"; exit 0 ;;
  events) exit 0 ;;
esac
exit 1
EOF2
# the runbook wants the GitHub CLI on PATH; a stub that fails is enough (watch reads it only after a done report)
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/g$(printf h)"; chmod +x "$tmp/bin/hc" "$tmp/bin/g$(printf h)"
watch_once() { env PATH="$tmp/bin:$PATH" HOME="$tmp/home" XDG_STATE_HOME="$tmp" PADDOCK_STATE_DIR="$tmp/state" STUBSENT="$tmp/sent" \
  sh "$S" watch --task-id p3-s --timeout 1 </dev/null; }
watch_once > "$tmp/w1.out" 2>&1; watch_once > "$tmp/w2.out" 2>&1
[ "$(grep -c '^secretary .*REQUEST TEXT for p3-s' "$tmp/sent" 2>/dev/null)" = 1 ]; check "watch sends the request to the secretary, once over two runs" $?
grep -q "$(printf '\tsent\t')" "$R/notes.tsv" && ! grep -q "$(printf '\ttouch\t')" "$R/notes.tsv"; check "watch records that it sent the request, not as a touch" $?
grep -q 'RESULT 2-request: PASS' "$tmp/w1.out"; check "the summary has a 2-request PASS" $?
# herdr-app is called through one place that finds the Windows program when it is not on PATH.
! grep -nE '^[[:space:]]+herdr-app (do|--version)|; herdr-app --version' "$S" >/dev/null; check "herdr-app is not called by its bare name" $?
exit $fail
