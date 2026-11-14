#!/usr/bin/env bash
# Acceptance test for Issue #362 (decision 0011, item 4): the folder-trust dialog of a worker on a fresh clone made by
# org-clone is NOT answered by `org-escalation prompt`; it goes to the person as an approval card, and after a yes
# `answer` moves the cursor to "Yes, I trust this folder", presses enter once, clears the marker and (with
# --then-send) sends the first message. A clone with no marker keeps the old automatic answer. Stubbed hc; no core.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-escalation/scripts/org-escalation.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
g() { git -c user.name=t -c user.email=t@t.invalid "$@"; }
mkdir -p "$tmp/bin" "$tmp/s" "$tmp/workers"
cat > "$tmp/bin/hc" <<'S'
#!/bin/sh
echo "$*" >> "$STUB/calls"
case $1 in
  read) cat "$STUB/screen" ;;
  keys) case $3 in
          down) cp "$STUB/screen.down" "$STUB/screen" ;;
          enter) if grep -q '^ ❯ Yes' "$STUB/screen"; then echo idle > "$STUB/state"; fi ;;
        esac ;;
  send) : ;;
  get) if [ "$(cat "$STUB/state")" = none ]; then echo '{"name":"w-t1","status":null}'; else echo "{\"name\":\"w-t1\",\"status\":{\"state\":\"$(cat "$STUB/state")\"}}"; fi ;;
  connect)
    read -r req
    method=$(printf '%s' "$req" | sed 's/.*"method":"\([^"]*\)".*/\1/')
    name=$(printf '%s' "$req" | sed 's/.*"name":"\([^"]*\)".*/\1/')
    ver=$(cat "$STUB/docver-$name" 2>/dev/null || echo 0)
    case "$method" in
      doc.get) printf '{"jsonrpc":"2.0","id":1,"result":{"value":%s,"version":%s}}\n' "$(cat "$STUB/docval-$name" 2>/dev/null || echo null)" "$ver" ;;
      doc.set)
        v=$(printf '%s' "$req" | sed 's/.*"version":\([0-9]*\)}}$/\1/')
        printf '%s' "$req" | sed 's/.*"value":\(.*\),"version":[0-9]*}}$/\1/' > "$STUB/docval-$name"
        echo $(( v + 1 )) > "$STUB/docver-$name"
        printf '{"jsonrpc":"2.0","id":1,"result":{"version":%s}}\n' "$(( v + 1 ))" ;;
    esac ;;
esac
exit 0
S
chmod +x "$tmp/bin/hc"
export STUB=$tmp/s PADDOCK_WORKERS_DIR=$tmp/workers
printf '%s\n' '────────' ' Quick safety check: Is this a project you created or one you trust?' \
  ' ❯ No, exit' '   Yes, I trust this folder' ' Enter to confirm · Esc to cancel' > "$STUB/screen.start"
sed 's/^ ❯ No, exit$/   No, exit/; s/^   Yes, I trust/ ❯ Yes, I trust/' "$STUB/screen.start" > "$STUB/screen.down"
e() { env -u PADDOCK_ORG_ID -u PADDOCK_SECRETARY_NAME PADDOCK_HC_HOLD=0 PADDOCK_PROMPT_TRIES=3 PADDOCK_STATE_DIR="$tmp/state" PATH="$tmp/bin:$PATH" bash "$script" "$@" 2>"$STUB/err"; }
fresh() { # fresh: a clone with one worktree for task t1, the dialog on screen, no status
  command rm -rf "$tmp/clone" "$tmp/workers/t1"; git -C "$tmp" worktree prune 2>/dev/null
  g init -q "$tmp/clone"; g -C "$tmp/clone" commit -q --allow-empty -m i
  g -C "$tmp/clone" worktree add -q -b work/t1 "$tmp/workers/t1" HEAD
  cp "$STUB/screen.start" "$STUB/screen"; echo none > "$STUB/state"; : > "$STUB/calls"
  printf '{"work":[],"approvals":[]}\n' > "$STUB/docval-org-state"; command rm -f "$STUB"/docver-*
}
marker() { echo "$tmp/clone/.git/paddock-trust-pending"; }

# Control: no marker, the old automatic answer.
fresh; e prompt --task t1 >/dev/null; rc=$?
[ $rc -eq 0 ] && grep -q '^keys w-t1 enter' "$STUB/calls"; check "no marker: the dialog is answered automatically ($rc)" $?

# Marker: held.
fresh; : > "$(marker)"
out=$(e prompt --task t1); rc=$?
[ $rc -eq 3 ] && ! grep -q '^keys' "$STUB/calls"; check "marker: exit 3 and no key pressed ($rc)" $?
case $out in PROMPT=*) true ;; *) false ;; esac; check "marker: the dialog is printed as PROMPT= for the card" $?
grep -qi 'trust' "$STUB/err"; check "marker: stderr says why it was not answered" $?

# The card, then yes.
p=${out#PROMPT=}
id=$(e ask --task t1 --question "Trust the folder of o/r?" --prompt "$p" | sed -n 's/^APPROVAL_ID=//p')
[ -n "$id" ]; check "ask records the prompt entry" $?
: > "$STUB/calls"
e answer --id "$id" --text yes --then-send "first message" >/dev/null; rc=$?
[ $rc -eq 0 ]; check "answer yes exits 0 ($rc)" $?
grep -q '^keys w-t1 down' "$STUB/calls" && [ "$(grep -c '^keys w-t1 enter' "$STUB/calls")" = 1 ]; check "answer: down to Yes, enter once" $?
grep -q '^send w-t1 first message' "$STUB/calls"; check "answer --then-send sends the first message after the dialog" $?
[ ! -e "$(marker)" ]; check "yes clears the marker (later workers are not held)" $?
[ -z "$(e list)" ]; check "the entry is removed" $?

# A no presses esc and keeps the marker.
fresh; : > "$(marker)"; out=$(e prompt --task t1)
id=$(e ask --task t1 --question "Trust?" --prompt "${out#PROMPT=}" | sed -n 's/^APPROVAL_ID=//p'); : > "$STUB/calls"
e answer --id "$id" --text no >/dev/null; rc=$?
[ $rc -eq 0 ] && grep -q '^keys w-t1 esc' "$STUB/calls" && ! grep -q '^keys w-t1 enter' "$STUB/calls" && [ -e "$(marker)" ]; check "no: esc, no enter, marker kept ($rc)" $?

# A screen that changed since the card: nothing pressed.
fresh; : > "$(marker)"; out=$(e prompt --task t1)
id=$(e ask --task t1 --question "Trust?" --prompt "${out#PROMPT=}" | sed -n 's/^APPROVAL_ID=//p')
printf '%s\n' '────────' ' Something else entirely' > "$STUB/screen"; : > "$STUB/calls"
e answer --id "$id" --text yes >/dev/null; rc=$?
[ $rc -eq 10 ] && ! grep -q '^keys' "$STUB/calls" && [ -e "$(marker)" ]; check "changed screen: exit 10, no key, marker kept ($rc)" $?
exit $fail
