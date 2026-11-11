#!/usr/bin/env bash
# Acceptance test for `org-escalation.sh sweep` (Issue #181). Needs only bash and coreutils:
# hc is a stub on PATH (documents and `hc get --json`), so no core runs. scripts/org is the
# real one, writing under a throwaway state dir.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-escalation/scripts/org-escalation.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

# Stub hc. docval-<name> holds a document. term-<name> holds the terminal's state: a word
# (working, idle, done, blocked ...) = a status with that state, "none" = status null,
# "broken" = hc get fails for another reason than not found. No file = terminal not found.
stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/calls"
if [ "$1" = get ]; then
  for a in "$@"; do name=$a; done
  [ -f "$STUB/term-$name" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
  st=$(cat "$STUB/term-$name")
  [ "$st" != broken ] || { echo 'hc: connection refused' >&2; exit 1; }
  s="{\"app\":\"claude-code\",\"state\":\"$st\"}"; [ "$st" != none ] || s=null
  printf '{\n  "name": "%s",\n  "state": "live",\n  "labels": {},\n  "status": %s\n}\n' "$name" "$s"; exit 0
fi
[ "$1" = connect ] || exit 0
read -r req
method=$(printf '%s' "$req" | sed 's/.*"method":"\([^"]*\)".*/\1/')
name=$(printf '%s' "$req" | sed 's/.*"name":"\([^"]*\)".*/\1/')
ver() { cat "$STUB/docver-$name" 2>/dev/null || echo 0; }
val() { cat "$STUB/docval-$name" 2>/dev/null || echo null; }
case "$method" in
  doc.get) printf '{"jsonrpc":"2.0","id":1,"result":{"value":%s,"version":%s}}\n' "$(val)" "$(ver)" ;;
  doc.set)
    v=$(printf '%s' "$req" | sed 's/.*"version":\([0-9]*\)}}$/\1/')
    printf '%s' "$req" | sed 's/.*"value":\(.*\),"version":[0-9]*}}$/\1/' > "$STUB/docval-$name"
    echo $(( v + 1 )) > "$STUB/docver-$name"
    printf '{"jsonrpc":"2.0","id":1,"result":{"version":%s}}\n' "$(ver)" ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"

export STUB=$tmp/stub; state=$tmp/state
# setdoc <answer_in of t1> ...: one entry per "task:answer_in" pair (answer_in "-" = field absent)
setdoc() {
  rm -rf "$STUB"; mkdir -p "$STUB"; : > "$STUB/calls"
  local e="" t a
  for p in "$@"; do
    t=${p%%:*}; a=${p#*:}
    [ -z "$e" ] || e="$e,"
    if [ "$a" = - ]; then ai=; else ai=",\"answer_in\":\"$a\""; fi
    e="$e{\"id\":\"$t-1\",\"task_id\":\"$t\",\"question\":\"Q $t?\",\"asked_at\":\"x\"$ai}"
  done
  printf '{"work":[],"approvals":[%s]}\n' "$e" > "$STUB/docval-org-state"
}
doc() { cat "$STUB/docval-org-state"; }
term() { printf '%s' "$2" > "$STUB/term-w-$1"; }
sweep() {
  env -u PADDOCK_ORG_ID -u PADDOCK_SECRETARY_NAME PADDOCK_HC_HOLD=0 PADDOCK_STATE_DIR="$state" \
      PATH="$stubdir:$PATH" bash "$script" sweep 2>&1
}
has() { case $(doc) in *"\"id\":\"$1-1\""*) return 0 ;; *) return 1 ;; esac; }

# the states that remove the entry
for s in working idle done; do
  setdoc t1:worker; term t1 $s; out=$(sweep); rc=$?
  [ $rc -eq 0 ]; check "sweep exits 0 ($s)" $?
  has t1; [ $? -ne 0 ]; check "a worker approval is removed when the core shows $s" $?
  case $out in *t1-1*) r=0 ;; *) r=1 ;; esac; check "sweep names the removed id ($s)" $r
done

# the cases that keep it
setdoc t1:worker; term t1 none; sweep >/dev/null
has t1; check "no status (a dialog) keeps the entry" $?
setdoc t1:worker; sweep >/dev/null
has t1; check "a missing terminal keeps the entry" $?
setdoc t1:worker; term t1 broken; sweep >/dev/null; rc=$?
has t1; check "a failed lookup keeps the entry" $?
[ $rc -eq 0 ]; check "a failed lookup does not fail the sweep" $?
setdoc t1:worker; term t1 blocked; sweep >/dev/null
has t1; check "blocked keeps the entry" $?

# only worker entries are looked at
setdoc t1:secretary t2:- t3:worker; term t1 working; term t2 working; term t3 working; sweep >/dev/null
has t1; check "an answer_in secretary entry stays even when working" $?
has t2; check "an entry without answer_in stays" $?
has t3; [ $? -ne 0 ]; check "the worker entry beside them is removed" $?

# a mix: each entry is judged on its own terminal
setdoc t1:worker t2:worker t3:worker; term t1 working; term t2 none; term t3 done; sweep >/dev/null
has t1; [ $? -ne 0 ]; check "mix: working removed" $?
has t2; check "mix: no status kept" $?
has t3; [ $? -ne 0 ]; check "mix: done removed" $?

# nothing to do
setdoc; out=$(sweep); [ $? -eq 0 ]; check "an empty approvals array is fine" $?
printf 'null\n' > "$STUB/docval-org-state"; sweep >/dev/null; [ $? -eq 0 ]; check "a null document is fine" $?

[ "$fail" -eq 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
