#!/usr/bin/env bash
# Acceptance test for Issue #175: `org wait` checks every worker in org-state.work against the
# core on every return and every timeout, and says in its one JSON line which workers are
# gone without a done record ("gone"), stopped at an approval prompt ("waiting"), or finished
# in the core with no done record ("unreported"). Quiet when none is. It reads the work list
# from the core each time, so a secretary that started after a handover needs no memory.
# Needs only bash and coreutils: hc is a stub on PATH (get, connect), no core runs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
org=$here/scripts/org
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# Stub hc. `get [--json] <name>`: prints $STUB/term-<name> if it exists, else not_found (exit 1).
# `connect` serves the org-state document from $STUB/docval-org-state (as in org-wait.test.sh).
# STUB_CORE_DOWN=1: every call fails (core unreachable).
stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
[ -z "${STUB_CORE_DOWN:-}" ] || { echo 'hc: cannot reach the core' >&2; exit 1; }
case "$1" in
  get)
    n=$(for a in "$@"; do last=$a; done; echo "$last")
    [ -f "$STUB/term-$n" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
    cat "$STUB/term-$n"; exit 0 ;;
  connect) ;;
  *) exit 0 ;;
esac
read -r req
case "$(printf '%s' "$req" | sed 's/.*"method":"\([^"]*\)".*/\1/')" in
  doc.get) printf '{"jsonrpc":"2.0","id":1,"result":{"value":%s,"version":1}}\n' "$(cat "$STUB/docval-org-state" 2>/dev/null || echo null)" ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"

export STUB=$tmp/stub; mkdir -p "$STUB"
state=$tmp/state
o() { # o <id> <args...>: the real org as <id>, against the throwaway state and the stub hc
  local who=$1; shift
  env -u PADDOCK_ORG_ID -u PADDOCK_SECRETARY_NAME PADDOCK_HC_HOLD=0 PADDOCK_NOW=2026-11-11T01:02:03Z \
      PADDOCK_STATE_DIR="$state" PADDOCK_WAIT_POLL=0.2 PATH="$stubdir:$PATH" \
      bash "$org" --as "$who" "$@"
}
term() { printf '%s\n' "$2" > "$STUB/term-w-$1"; }   # term <task> <get json>
work() { # work <task>...: org-state with those tasks in progress
  local s= t
  for t in "$@"; do s="$s${s:+,}{\"task_id\":\"$t\",\"title\":\"x\",\"since\":\"2026-11-11T00:00:00Z\"}"; done
  printf '{"work":[%s],"approvals":[]}\n' "$s" > "$STUB/docval-org-state"
}

# Quiet case: a working worker, and one that is gone but closed with a done record.
work t-ok t-closed
term t-ok '{"name":"w-t-ok","state":"running","status":{"state":"working"}}'
o w-t-closed report done --task t-closed "finished" >/dev/null
o secretary check_messages >/dev/null
out=$(o secretary wait --timeout 1 2>&1)
printf '%s' "$out" | grep -q '"reason":"timeout"'; check "quiet: timeout line" $?
printf '%s' "$out" | grep -Eq 'gone|waiting|unreported|watch'; [ $? -ne 0 ]; check "quiet: nothing flagged ($out)" $?

# The three cases at once, on a timeout.
work t-ok t-gone t-wait t-fin t-dead t-closed
term t-wait '{"name":"w-t-wait","state":"running","status":{"state":"blocked","text":"approve?"}}'
term t-fin '{"name":"w-t-fin","state":"running","status":{"state":"done"}}'
term t-dead '{"name":"w-t-dead","state":"finished","reason":"killed","status":null}'
out=$(o secretary wait --timeout 1 2>&1)
printf '%s' "$out" | grep -q '"reason":"timeout"'; check "cases: timeout line" $?
printf '%s' "$out" | grep -Eq '"gone":\["t-gone","t-dead"\]'; check "gone without done: no terminal, or ended ($out)" $?
printf '%s' "$out" | grep -Eq '"waiting":\["t-wait"\]'; check "waiting for approval: blocked ($out)" $?
printf '%s' "$out" | grep -Eq '"unreported":\["t-fin"\]'; check "finished with no done record ($out)" $?
printf '%s' "$out" | grep -Eq 't-ok|t-closed'; [ $? -ne 0 ]; check "a working worker and a closed one are not flagged" $?
[ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ]; check "still one line" $?

# On a return for mail, too; the mail is left unread.
o person send_message secretary "hello" >/dev/null
out=$(o secretary wait --timeout 5 2>&1)
printf '%s' "$out" | grep -q '"reason":"mail"' && printf '%s' "$out" | grep -q '"gone":\["t-gone","t-dead"\]' \
  && printf '%s' "$out" | grep -q '"waiting":\["t-wait"\]'; check "mail return also reports ($out)" $?
o secretary check_messages >/dev/null

# A done record clears the flag: the next wait no longer lists t-fin.
o w-t-fin report done --task t-fin "finished" >/dev/null
o secretary check_messages >/dev/null
out=$(o secretary wait --timeout 1 2>&1)
printf '%s' "$out" | grep -q 't-fin'; [ $? -ne 0 ]; check "after its done record t-fin is not listed" $?

# The core cannot be read: say so, do not look quiet.
out=$(STUB_CORE_DOWN=1 o secretary wait --timeout 1 2>&1)
printf '%s' "$out" | grep -q '"reason":"timeout"' && printf '%s' "$out" | grep -q '"watch_error"'; check "core unreachable: watch_error ($out)" $?

exit $fail
