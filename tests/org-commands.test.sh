#!/usr/bin/env bash
# Acceptance test for scripts/org (Issue #60): send_message, check_messages, set_summary,
# report, list_runs, and the versioned-document helper (doc get / set / update).
# Needs only bash, coreutils, sed and awk. hc is a stub on PATH, so no core runs; the
# mailbox commands must never call it (a worker has no hc).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/scripts/org
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

[ -f "$script" ]; check "scripts/org exists" $?
bash -n "$script" 2>/dev/null; check "script parses" $?

# Stub hc: only `hc connect` is used (documents). State lives in $STUB:
# docval-<name> / docver-<name> hold the stored value and version; calls is the call log.
# STUB_CONFLICT_ONCE=1: the first doc.set answers conflict after a concurrent writer
#   changed the stored value to {"work":[],"x":1} (and bumped the version).
# STUB_CONFLICT_ALWAYS=1: every doc.set answers conflict. STUB_SET_ERROR=1: other error.
stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/calls"
[ "$1" = connect ] || exit 0
read -r req
method=$(printf '%s' "$req" | sed 's/.*"method":"\([^"]*\)".*/\1/')
name=$(printf '%s' "$req" | sed 's/.*"name":"\([^"]*\)".*/\1/')
ver() { cat "$STUB/docver-$name" 2>/dev/null || echo 0; }
val() { cat "$STUB/docval-$name" 2>/dev/null || echo null; }
case "$method" in
  doc.get) printf '{"jsonrpc":"2.0","id":1,"result":{"value":%s,"version":%s}}\n' "$(val)" "$(ver)" ;;
  doc.set)
    [ -z "${STUB_SET_ERROR:-}" ] || { echo '{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"boom"}}'; exit 0; }
    [ -z "${STUB_CONFLICT_ALWAYS:-}" ] || { echo '{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"conflict: version","data":{"kind":"conflict"}}}'; exit 0; }
    if [ -n "${STUB_CONFLICT_ONCE:-}" ] && [ ! -f "$STUB/conflicted" ]; then
      : > "$STUB/conflicted"; echo '{"work":[],"x":1}' > "$STUB/docval-$name"; echo $(( $(ver) + 1 )) > "$STUB/docver-$name"
      echo '{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"conflict: version","data":{"kind":"conflict"}}}'; exit 0
    fi
    v=$(printf '%s' "$req" | sed 's/.*"version":\([0-9]*\)}}$/\1/')
    if [ "$v" != "$(ver)" ]; then echo '{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"conflict: version","data":{"kind":"conflict"}}}'; exit 0; fi
    printf '%s' "$req" | sed 's/.*"value":\(.*\),"version":[0-9]*}}$/\1/' > "$STUB/docval-$name"
    echo $(( v + 1 )) > "$STUB/docver-$name"
    printf '{"jsonrpc":"2.0","id":1,"result":{"version":%s}}\n' "$(ver)" ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"

state=$tmp/state; export STUB=$tmp/stub; mkdir -p "$STUB"; : > "$STUB/calls"
org() { # org <args...>; extra env via ORGENV (space separated)
  env -u PADDOCK_ORG_ID -u PADDOCK_NOW -u PADDOCK_SECRETARY_NAME PADDOCK_HC_HOLD=0 \
      PADDOCK_STATE_DIR="$state" PATH="$stubdir:$PATH" ${ORGENV:-} bash "$script" "$@" 2>&1
}
rc() { "$@" >/dev/null 2>&1; echo $?; } # exit status only
month=$(date -u +%Y-%m)

# Arguments and identity.
out=$(org --help); r=$?
[ "$r" -eq 0 ] && grep -qi usage <<<"$out"; check "--help exits 0 with usage" $?
[ "$(rc org --as w1 no_such_command)" -eq 2 ]; check "unknown command exits 2" $?
[ "$(rc org send_message secretary hi)" -eq 2 ]; check "no id (no --as, no PADDOCK_ORG_ID) exits 2" $?
[ "$(rc org --as 'Bad Id' send_message secretary hi)" -eq 2 ]; check "invalid id exits 2" $?
[ "$(rc org --as w1 send_message 'bad/to' hi)" -eq 2 ]; check "invalid recipient exits 2" $?
[ "$(rc org --as w1 send_message secretary '')" -eq 2 ]; check "empty text exits 2" $?
[ "$(ORGENV=PADDOCK_ORG_ID=w1 rc org send_message secretary env-id)" -eq 0 ]; check "PADDOCK_ORG_ID names the sender" $?

# send_message writes one JSON line to the sender's own file; seq counts up.
org --as w2 send_message secretary 'first' >/dev/null; r1=$?
org --as w2 send_message secretary 'second' >/dev/null; r2=$?
f=$state/events/$month/w2.jsonl
[ "$r1" -eq 0 ] && [ "$r2" -eq 0 ] && [ -f "$f" ] && [ "$(wc -l < "$f")" -eq 2 ]; check "send_message appends to events/<month>/<sender>.jsonl" $?
grep -q '^{"seq":1,"ts":"[0-9TZ:-]*","from":"w2","kind":"message","to":"secretary"' "$f" \
  && grep -q '^{"seq":2,' "$f"; check "lines carry seq, UTC ts, from, kind, to" $?
[ ! -e "$state/events/$month/secretary.jsonl" ]; check "nothing is written under the recipient's name" $?

# check_messages: unread only, once, text intact, other recipients left alone.
org --as w2 send_message other 'not for the secretary' >/dev/null
out=$(org --as secretary check_messages)
grep -q 'first' <<<"$out" && grep -q 'second' <<<"$out" && grep -q 'w2#2' <<<"$out" \
  && ! grep -q 'not for the secretary' <<<"$out"; check "check_messages prints the secretary's unread messages with sender and seq" $?
out=$(org --as secretary check_messages)
! grep -q 'first' <<<"$out" && grep -qi 'no new' <<<"$out"; check "a second check_messages shows nothing new" $?
org --as w2 send_message secretary 'third' >/dev/null
out=$(org --as secretary check_messages)
grep -q 'third' <<<"$out" && ! grep -q 'second' <<<"$out"; check "only messages after the last check are shown" $?
org --as w2 send_message secretary 'peeked' >/dev/null
out=$(org --as secretary check_messages --peek); out2=$(org --as secretary check_messages)
grep -q 'peeked' <<<"$out" && grep -q 'peeked' <<<"$out2"; check "--peek does not mark messages read" $?
[ "$(wc -l < "$f")" -eq 5 ]; check "a reader never writes the sender's file" $?
[ -f "$state/events/$month/secretary.jsonl" ] && grep -q '"kind":"ack"' "$state/events/$month/secretary.jsonl"; check "the read position is an ack line in the reader's own file" $?

# Text survives: quotes, backslash, newline, tab, braces, non-ASCII, a fake field.
msg=$(printf 'he said "hi" \\ back\nline2\ttab {"to":"secretary"} 日本語')
org --as w3 send_message secretary "$msg" >/dev/null
out=$(org --as secretary check_messages)
grep -qF 'he said "hi" \ back' <<<"$out" && grep -qF 'line2' <<<"$out" && grep -qF '{"to":"secretary"}' <<<"$out" && grep -qF '日本語' <<<"$out"; check "quotes, backslash, newline, braces and non-ASCII round-trip" $?
[ "$(wc -l < "$state/events/$month/w3.jsonl")" -eq 1 ]; check "a multi-line message is one line in the file" $?
org --as w3 send_message w4 'private' >/dev/null
out=$(org --as secretary check_messages); ! grep -q 'private' <<<"$out"; check "a message to w4 is not delivered to the secretary" $?
out=$(org --as w4 check_messages); grep -q 'private' <<<"$out"; check "a message to w4 is delivered to w4" $?

# report: start and completion records for a task, delivered to the secretary.
[ "$(rc org --as w5 report start)" -eq 2 ]; check "report without --task exits 2" $?
[ "$(rc org --as w5 report finished --task t5 x)" -eq 2 ]; check "report with an unknown status exits 2" $?
org --as w5 report start --task t5 'plan: write the thing' >/dev/null; a=$?
org --as w5 report done --task t5 'changed x, commit abc' >/dev/null; b=$?
[ "$a" -eq 0 ] && [ "$b" -eq 0 ]; check "report start and report done exit 0" $?
grep -q '"kind":"run_started","to":"secretary","task_id":"t5"' "$state/events/$month/w5.jsonl" \
  && grep -q '"kind":"run_completed","to":"secretary","task_id":"t5"' "$state/events/$month/w5.jsonl"; check "report writes run_started and run_completed records with the task id" $?
out=$(org --as secretary check_messages)
grep -q 'plan: write the thing' <<<"$out" && grep -q 'changed x, commit abc' <<<"$out" && grep -q 't5' <<<"$out"; check "the secretary receives both reports through check_messages" $?
org --as w6 report start --task t6 'go' >/dev/null; org --as w6 report blocked --task t6 'need an answer' >/dev/null
org --as w6 report start --task t6b --to w9 'go' >/dev/null
out=$(org --as w9 check_messages); grep -q 'go' <<<"$out"; check "report --to sends the record to another recipient" $?

# set_summary and list_runs.
org --as w6 set_summary 'waiting on a question' >/dev/null; org --as w6 set_summary 'unblocked, testing' >/dev/null
out=$(org --as secretary list_runs)
grep -E 't5' <<<"$out" | grep -q 'done' && grep -E 't6[^b]|t6$|t6	' <<<"$out" | grep -q 'blocked'; check "list_runs shows the latest state per task (done, blocked)" $?
grep -q 'w5' <<<"$out"; check "list_runs names the writer" $?
grep -q 'unblocked, testing' <<<"$out" && ! grep -q 'waiting on a question' <<<"$out"; check "list_runs shows only each agent's latest summary" $?
org --as w6 report start --task t6 'again' >/dev/null
out=$(org --as secretary list_runs); grep -E 't6	' <<<"$out" | grep -q 'started'; check "a later record replaces the state" $?

# Windows of time: this and the previous month are read; older ones are not. PADDOCK_NOW fixes the clock.
ORGENV=PADDOCK_NOW=2026-01-31T23:59:59Z org --as w7 send_message secretary 'january note' >/dev/null
[ -f "$state/events/2026-01/w7.jsonl" ]; check "the file is named for the UTC month of the line" $?
out=$(ORGENV=PADDOCK_NOW=2026-02-01T00:00:10Z org --as secretary check_messages --peek)
grep -q 'january note' <<<"$out"; check "a message from the previous month is still read" $?
out=$(ORGENV=PADDOCK_NOW=2026-04-01T00:00:10Z org --as secretary check_messages --peek)
! grep -q 'january note' <<<"$out"; check "a message three months old is not read" $?
ORGENV=PADDOCK_NOW=2026-01-31T23:59:59Z org --as w7 send_message secretary 'again' >/dev/null
ORGENV=PADDOCK_NOW=2026-02-01T00:00:05Z org --as w7 send_message secretary 'feb' >/dev/null
[ "$(sed -n 's/^{"seq":\([0-9]*\),.*"text":"feb"}$/\1/p' "$state/events/2026-02/w7.jsonl")" -eq 3 ]; check "seq continues across the month boundary" $?

# Nothing above touched hc, and everything survives a fresh process with no hc at all
# (the window, or the whole core, may be gone).
[ ! -s "$STUB/calls" ]; check "the mailbox commands never call hc" $?
out=$(env -u PADDOCK_ORG_ID PADDOCK_STATE_DIR="$state" PATH="/usr/bin:/bin" bash "$script" --as secretary list_runs 2>&1); r=$?
[ "$r" -eq 0 ] && grep -q 't5' <<<"$out"; check "with no hc on PATH the records are still readable" $?

# Documents: allowed names, one writer, cap, versioned retry.
reset_doc() { rm -rf "$STUB"; mkdir -p "$STUB"; : > "$STUB/calls"; }
reset_doc
[ "$(rc org --as secretary doc get nope)" -eq 6 ]; check "doc get of a name outside decision 0004 exits 6" $?
[ "$(rc org --as w1 doc set org-state <<<'{}')" -eq 7 ]; check "a worker cannot write org-state (exit 7)" $?
out=$(org --as w1 doc get org-state); [ "$out" = null ]; check "any agent can read a document; unwritten is null" $?
echo '{"work":[]}' | org --as secretary doc set org-state >/dev/null; r=$?
[ "$r" -eq 0 ] && [ "$(cat "$STUB/docval-org-state")" = '{"work":[]}' ] && [ "$(cat "$STUB/docver-org-state")" = 1 ]; check "doc set writes the value with the version it read" $?
out=$(org --as secretary doc get org-state); [ "$out" = '{"work":[]}' ]; check "doc get prints the stored value" $?
org --as secretary doc update org-state -- sed 's/\[\]/[{"task_id":"t1"}]/' >/dev/null; r=$?
[ "$r" -eq 0 ] && [ "$(cat "$STUB/docval-org-state")" = '{"work":[{"task_id":"t1"}]}' ]; check "doc update applies the command to the stored value" $?
reset_doc; echo '{"work":[]}' | org --as secretary doc set org-state >/dev/null
out=$(STUB_CONFLICT_ONCE=1 ORGENV=STUB_CONFLICT_ONCE=1 org --as secretary doc update org-state -- sed 's/\[\]/[{"task_id":"t1"}]/'); r=$?
[ "$r" -eq 0 ] && [ "$(cat "$STUB/docval-org-state")" = '{"work":[{"task_id":"t1"}],"x":1}' ]; check "on a conflict doc update re-reads, reapplies and sets (the other writer's change is kept)" $?
reset_doc; echo '{"work":[]}' | org --as secretary doc set org-state >/dev/null
[ "$(ORGENV=STUB_CONFLICT_ALWAYS=1 rc org --as secretary doc update org-state -- cat)" -eq 9 ]; check "a conflict that never clears exits 9" $?
[ "$(ORGENV=STUB_SET_ERROR=1 rc org --as secretary doc update org-state -- cat)" -eq 5 ]; check "another doc.set error exits 5, not retried as a conflict" $?
[ "$(rc org --as secretary doc update org-state -- false)" -ne 0 ]; check "a failing update command writes nothing and fails" $?
big=$(head -c 70000 /dev/zero | tr '\0' a)
[ "$(printf '"%s"' "$big" | rc org --as secretary doc set org-state)" -eq 8 ]; check "a value over org-state's 64 KiB cap exits 8" $?
[ "$(printf '"%s"' "$(head -c 40000 /dev/zero | tr '\0' a)" | rc org --as secretary doc set secretary-handover)" -eq 8 ]; check "a value over secretary-handover's 32 KiB cap exits 8" $?
echo 'null' | org --as secretary doc set secretary-handover >/dev/null; [ "$(cat "$STUB/docval-secretary-handover")" = null ]; check "secretary-handover can be set to null" $?
[ "$(ORGENV=PADDOCK_SECRETARY_NAME=boss rc org --as boss doc set org-state <<<'{}')" -eq 0 ]; check "PADDOCK_SECRETARY_NAME names the one writer" $?
r=$(env -u PADDOCK_ORG_ID PADDOCK_STATE_DIR="$state" PATH="/usr/bin:/bin" bash "$script" --as secretary doc get org-state >/dev/null 2>&1; echo $?)
[ "$r" -eq 3 ]; check "doc with no hc on PATH exits 3" $?

exit $fail
