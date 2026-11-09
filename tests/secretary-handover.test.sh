#!/usr/bin/env bash
# Acceptance test for skills/secretary-handover/scripts/secretary-handover.sh. Needs only
# bash and coreutils: hc is a stub on PATH, so no core runs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/secretary-handover/scripts/secretary-handover.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

[ -f "$script" ]; check "script exists" $?
[ -f "$here/skills/secretary-handover/SKILL.md" ]; check "SKILL.md exists" $?
bash -n "$script" 2>/dev/null; check "script parses" $?

# Stub hc. State lives in $STUB: "term-<name>" exists while a terminal of that name
# exists; "state" holds its status (default idle); "doc" holds the secretary-handover
# document's JSON-RPC answer. Every call is appended to $STUB/calls.
# STUB_FIRST_SENT=false makes `run` report first_message.sent false.
stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/calls"
cmd=$1; shift
name=
for a in "$@"; do case "$a" in --*) ;; *) name=$a ;; esac; done
case "$cmd" in
  connect) cat >/dev/null; cat "$STUB/doc" 2>/dev/null \
             || echo '{"jsonrpc":"2.0","id":1,"result":{"value":null,"version":0}}'; exit 0 ;;
  get) [ -z "${STUB_GET_FAIL:-}" ] || { echo 'hc: connection reset' >&2; exit 1; }
       [ -f "$STUB/term-$name" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       [ -z "${STUB_MULTILINE:-}" ] || { printf '{\n  "name": "%s",\n  "state": "live",\n  "status": {\n    "app": "claude-code",\n    "state": "%s"\n  }\n}\n' "$name" "$(cat "$STUB/state")"; exit 0; }
       echo "{\"name\":\"$name\",\"state\":\"live\",\"status\":{\"app\":\"claude-code\",\"state\":\"$(cat "$STUB/state" 2>/dev/null || echo idle)\"}}"; exit 0 ;;
  kill) [ -f "$STUB/term-$name" ] || exit 1; echo '{"killed":true}'; exit 0 ;;
  rm) rm -f "$STUB/term-$name"; echo '{"removed":true}'; exit 0 ;;
  run) for a in "$@"; do case "$a" in --name) next=1 ;; *) [ -n "${next:-}" ] && { : > "$STUB/term-$a"; next=; } ;; esac; done
       echo "{\"first_message\":{\"sent\":${STUB_FIRST_SENT:-true},\"started\":true,\"turn\":0}}"; exit 0 ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"

reset() { # reset [idle|working|blocked] [doc|nodoc] [oldterm|noterm]
  rm -rf "$tmp/stub"; mkdir -p "$tmp/stub"; : > "$tmp/stub/calls"
  echo "${1:-idle}" > "$tmp/stub/state"
  [ "${2:-doc}" = doc ] && echo '{"jsonrpc":"2.0","id":1,"result":{"value":{"written_at":"2026-11-10T01:00:00Z","last_exchange":"x"},"version":3}}' > "$tmp/stub/doc"
  [ "${3:-oldterm}" = oldterm ] && : > "$tmp/stub/term-${4:-secretary}"
  return 0
}
run() { # run <extra env...>
  env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
      -u PADDOCK_SECRETARY_NAME STUB="$tmp/stub" PATH="$stubdir:$PATH" "$@" bash "$script" 2>&1
}
calls=$tmp/stub/calls
line() { grep -n "$1" "$calls" | head -1 | cut -d: -f1; } # line <regex> of the call log

# Arguments and environment.
out=$(bash "$script" --help 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -qi 'usage' <<<"$out"; check "--help exits 0 with usage" $?
bash "$script" --no-such-flag >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; check "unknown argument exits 2" $?
out=$(env PATH="$tmp/empty" "$(command -v bash)" "$script" 2>&1); rc=$?
[ "$rc" -eq 3 ]; check "no hc on PATH exits 3" $?
reset; out=$(run CLAUDE_CODE_CHILD_SESSION=1); rc=$?
[ "$rc" -eq 4 ] && [ ! -s "$calls" ]; check "agent environment exits 4 without calling hc" $?

# Refusal: a turn is in progress. Nothing is killed or started.
for st in working blocked; do
  reset "$st"; out=$(run); rc=$?
  [ "$rc" -eq 8 ] && ! grep -Eq '^(kill|rm|run) ' "$calls" && [ -f "$tmp/stub/term-secretary" ]
  check "status $st exits 8, ends and starts nothing" $?
done

# Refusal: the status cannot be read, or is multiline. A failed read is never taken as idle.
reset idle; out=$(run STUB_GET_FAIL=1); rc=$?
[ "$rc" -eq 11 ] && ! grep -Eq '^(kill|rm|run) ' "$calls"; check "hc get failing exits 11, ends and starts nothing" $?
reset working; out=$(run STUB_MULTILINE=1); rc=$?
[ "$rc" -eq 8 ] && ! grep -Eq '^(kill|rm|run) ' "$calls"; check "multiline JSON with working status exits 8" $?
reset idle; out=$(run STUB_MULTILINE=1); rc=$?
[ "$rc" -eq 0 ] && grep -q '^kill ' "$calls"; check "multiline JSON with idle status relaunches" $?

# Refusal: no handover document (never written, or cleared to null). Nothing is ended.
reset idle nodoc; out=$(run); rc=$?
[ "$rc" -eq 9 ] && ! grep -Eq '^(kill|rm|run) ' "$calls" && [ -f "$tmp/stub/term-secretary" ]
check "no handover document exits 9, ends and starts nothing" $?

# Happy path: read the document, kill, rm, then run with the task in the launch.
reset; out=$(run); rc=$?
[ "$rc" -eq 0 ]; check "relaunch exits 0 ($out)" $?
k=$(line '^kill '); r=$(line '^rm '); n=$(line '^run '); d=$(line '^connect')
[ -n "$d" ] && [ -n "$k" ] && [ -n "$r" ] && [ -n "$n" ] && [ "$d" -lt "$k" ] && [ "$k" -lt "$r" ] && [ "$r" -lt "$n" ]
check "order: read document, kill, rm, run" $?
grep -q '^run --bg --keep --name secretary secretary ..*' "$calls" \
  && grep -qi 'handover' <<<"$(grep '^run ' "$calls")"; check "run is 'hc run --bg --keep --name secretary secretary <task about the handover>'" $?
[ "$(grep -c '^run ' "$calls")" -eq 1 ]; check "starts exactly one secretary" $?
! grep -Eq '^(send|keys|server) ' "$calls"; check "never types into an agent or touches the core" $?

# Launch whose first message was not sent.
reset; out=$(run STUB_FIRST_SENT=false); rc=$?
[ "$rc" -eq 10 ]; check "first_message.sent false exits 10" $?

# Name override.
reset idle doc oldterm boss; out=$(run PADDOCK_SECRETARY_NAME=boss); rc=$?
[ "$rc" -eq 0 ] && grep -q '^kill boss' "$calls" && grep -q '^rm boss' "$calls" \
  && grep -q '^run --bg --keep --name boss secretary ' "$calls"; check "PADDOCK_SECRETARY_NAME overrides the terminal name, not the template" $?

# Idempotence: no old terminal (an earlier run died after rm) still relaunches, no kill/rm.
reset idle doc noterm; out=$(run); rc=$?
[ "$rc" -eq 0 ] && ! grep -Eq '^(kill|rm) ' "$calls" && [ "$(grep -c '^run ' "$calls")" -eq 1 ]
check "rerun with no old terminal starts one secretary without kill or rm" $?
# Once the new secretary has cleared the document, a rerun refuses and ends nothing.
echo '{"jsonrpc":"2.0","id":1,"result":{"value":null,"version":4}}' > "$tmp/stub/doc"; : > "$calls"
out=$(run); rc=$?
[ "$rc" -eq 9 ] && ! grep -Eq '^(kill|rm|run) ' "$calls"; check "rerun after the document is cleared exits 9, ends nothing" $?

exit $fail
