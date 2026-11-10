#!/usr/bin/env bash
# Acceptance test for skills/org-escalation/scripts/org-escalation.sh (Issue #66). Needs only
# bash and coreutils: hc is a stub on PATH (documents only), so no core runs. scripts/org is
# the real one, writing under a throwaway state dir.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-escalation/scripts/org-escalation.sh
org=$here/scripts/org
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

[ -f "$script" ]; check "script exists" $?
[ -f "$here/skills/org-escalation/SKILL.md" ]; check "SKILL.md exists" $?
bash -n "$script" 2>/dev/null; check "script parses" $?

# Stub hc: only `hc connect` is used. docval-<name> / docver-<name> in $STUB hold the stored
# document. STUB_SET_ERROR=1 makes every doc.set fail.
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
    v=$(printf '%s' "$req" | sed 's/.*"version":\([0-9]*\)}}$/\1/')
    printf '%s' "$req" | sed 's/.*"value":\(.*\),"version":[0-9]*}}$/\1/' > "$STUB/docval-$name"
    echo $(( v + 1 )) > "$STUB/docver-$name"
    printf '{"jsonrpc":"2.0","id":1,"result":{"version":%s}}\n' "$(ver)" ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"

export STUB=$tmp/stub; state=$tmp/state
now=2026-11-10T01:02:03Z
setdoc() { mkdir -p "$STUB"; : > "$STUB/calls"; rm -f "$STUB"/docver-*; printf '%s\n' "$1" > "$STUB/docval-org-state"; }
doc() { cat "$STUB/docval-org-state"; }
esc() { # run the skill script as the secretary; extra env via ENVX (space separated)
  env -u PADDOCK_ORG_ID -u PADDOCK_SECRETARY_NAME PADDOCK_HC_HOLD=0 PADDOCK_NOW=$now \
      PADDOCK_STATE_DIR="$state" PATH="$stubdir:$PATH" ${ENVX:-} bash "$script" "$@" 2>&1
}
rc() { "$@" >/dev/null 2>&1; echo $?; }
mail() { env -u PADDOCK_ORG_ID PADDOCK_STATE_DIR="$state" PADDOCK_NOW=$now bash "$org" --as "$1" check_messages 2>&1; }
id1=t1-20261110T010203Z

# ask: into a document that has no approvals yet, keeping the other keys
setdoc '{"updated_at":"2026-11-10T00:00:00Z","work":[{"task_id":"t1","title":"A","since":"2026-11-10T00:00:00Z"}]}'
out=$(esc ask --task t1 --question "Let t1 run npm publish?")
[ "$(rc esc ask --task t9 --question x)" -eq 0 ]; check "ask succeeds" $?
case $out in *"APPROVAL_ID=$id1"*) r=0 ;; *) r=1 ;; esac; check "ask prints APPROVAL_ID=<task>-<utc>" $r
case $(doc) in *'"work":[{"task_id":"t1","title":"A"'*) r=0 ;; *) r=1 ;; esac; check "ask keeps the work array as it was" $r
case $(doc) in *'"approvals":['*"\"id\":\"$id1\""*'"task_id":"t1"'*'"question":"Let t1 run npm publish?"'*'"asked_at":"2026-11-10T01:02:03Z"'*) r=0 ;; *) r=1 ;; esac
check "ask writes id, task_id, question and asked_at" $r

# second ask appends, first stays
esc ask --task t2 --question "Second?" >/dev/null
n=$(doc | grep -o '"asked_at"' | wc -l)
[ "$n" -ge 2 ]; check "a second ask appends" $?
case $(doc) in *"$id1"*) r=0 ;; *) r=1 ;; esac; check "the first entry is still there" $r

# same id twice: refused, nothing changed
setdoc 'null'
esc ask --task t1 --question "Q?" >/dev/null
before=$(doc)
[ "$(rc esc ask --task t1 --question "Q again?")" -eq 7 ]; check "ask with an existing id exits 7" $?
[ "$(doc)" = "$before" ]; check "a refused ask changes nothing" $?

# null document and empty approvals array
setdoc 'null'; esc ask --task t1 --question "Q?" >/dev/null
case $(doc) in *'"approvals":[{'*) r=0 ;; *) r=1 ;; esac; check "ask into a null document creates it" $r
setdoc '{"work":[],"approvals":[]}'; esc ask --task t1 --question "Q?" >/dev/null
case $(doc) in '{"work":[],"approvals":[{'*"}]}"*) r=0 ;; *) r=1 ;; esac; check "ask into an empty approvals array" $r

# quotes and the word approvals in a question do not break the document or the scanner
setdoc '{"work":[],"approvals":[]}'
esc ask --task t1 --question 'Run "x" with \ and "approvals": [ ] ?' >/dev/null
esc ask --task t2 --question "Plain?" >/dev/null
[ "$(esc list | wc -l)" -eq 2 ]; check "list shows two entries after a tricky question" $?
case $(doc) in *'\"x\"'*) r=0 ;; *) r=1 ;; esac; check "quotes in the question are escaped" $r

# bad arguments exit 2 and write nothing
setdoc 'null'
[ "$(rc esc ask --task 'T 1' --question q)" -eq 2 ]; check "ask rejects a task id with a space" $?
[ "$(rc esc ask --task t1)" -eq 2 ]; check "ask needs a question" $?
[ "$(rc esc ask --task t1 --question '')" -eq 2 ]; check "ask rejects an empty question" $?
[ "$(rc esc answer --id 'a b' --text yes)" -eq 2 ]; check "answer rejects a bad id" $?
[ "$(rc esc answer --id t1-x)" -eq 2 ]; check "answer needs text" $?
[ "$(rc esc frobnicate)" -eq 2 ]; check "unknown command exits 2" $?
[ "$(doc)" = "null" ]; check "bad arguments wrote nothing" $?

# answer: forwards to w-<task> through the mailbox and removes only that entry
setdoc '{"work":[],"approvals":[]}'
esc ask --task t1 --question "Q one?" >/dev/null
now=2026-11-10T01:02:04Z; esc ask --task t2 --question "Q two?" >/dev/null; now=2026-11-10T01:02:03Z
id2=t2-20261110T010204Z
out=$(esc answer --id "$id1" --text "yes, go ahead")
case $out in *"$id1"*) r=0 ;; *) r=1 ;; esac; check "answer reports the id" $r
m=$(mail w-t1)
case $m in *"Answer to your question ($id1): yes, go ahead"*) r=0 ;; *) r=1 ;; esac; check "the worker gets the answer through the mailbox" $r
case $(mail w-t2) in *"Answer"*) r=1 ;; *) r=0 ;; esac; check "another worker gets nothing" $r
case $(doc) in *"$id1"*) r=1 ;; *) r=0 ;; esac; check "the answered entry is removed" $r
case $(doc) in *"$id2"*) r=0 ;; *) r=1 ;; esac; check "the other entry stays" $r
grep -q 'send' "$STUB/calls"; [ $? -ne 0 ]; check "no hc send / hc keys is used (mailbox only)" $?

# answer: unknown id exits 6 and sends nothing
before=$(doc)
[ "$(rc esc answer --id nope-1 --text yes)" -eq 6 ]; check "answer with an unknown id exits 6" $?
[ "$(doc)" = "$before" ]; check "an unknown id changes nothing" $?

# answer: a mailbox failure keeps the entry (exit 8)
setdoc '{"approvals":[{"id":"t3-1","task_id":"t3","question":"Q?","asked_at":"2026-11-10T00:00:00Z"}]}'
bad=$tmp/state-file; : > "$bad"
[ "$(ENVX="PADDOCK_STATE_DIR=$bad" rc esc answer --id t3-1 --text yes)" -eq 8 ]; check "answer exits 8 when the mailbox cannot be written" $?
case $(doc) in *t3-1*) r=0 ;; *) r=1 ;; esac; check "the entry stays when the answer could not be sent" $r

# remove: drops the entry without a message; list prints id, task and question
setdoc '{"approvals":[{"id":"t3-1","task_id":"t3","question":"Q three?","asked_at":"x"},{"id":"t4-1","task_id":"t4","question":"Q four?","asked_at":"y"}]}'
case $(esc list) in *"t3-1"*"t3"*"Q three?"*) r=0 ;; *) r=1 ;; esac; check "list prints id, task and question" $r
[ "$(rc esc remove --id t3-1)" -eq 0 ]; check "remove succeeds" $?
case $(doc) in *t3-1*) r=1 ;; *) r=0 ;; esac; check "remove drops the entry" $r
case $(doc) in '{"approvals":[{"id":"t4-1"'*) r=0 ;; *) r=1 ;; esac; check "remove leaves the other entry intact" $r
esc remove --id t4-1 >/dev/null
case $(doc) in '{"approvals":[]}') r=0 ;; *) r=1 ;; esac; check "removing the last entry leaves an empty array" $r
[ "$(rc esc remove --id t4-1)" -eq 6 ]; check "remove of a missing id exits 6" $?

# a document that is not an object with the expected shape is refused, not rewritten
setdoc '[1,2]'
[ "$(rc esc ask --task t1 --question q)" -eq 5 ]; check "ask refuses a document that is not an object" $?
[ "$(doc)" = "[1,2]" ]; check "and leaves it as it was" $?

[ "$fail" -eq 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
