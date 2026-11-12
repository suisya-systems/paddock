#!/usr/bin/env bash
# Edge cases of org-escalation `prompt` (Issue #260, Codex review): the folder-trust policy entry
# matches only Claude Code's own dialog, never text that looks like it inside a tool prompt or output.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-escalation/scripts/org-escalation.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
mkdir -p "$tmp/bin" "$tmp/s"
cat > "$tmp/bin/hc" <<'S'
#!/bin/sh
echo "$*" >> "$STUB/calls"
case $1 in
  read) cat "$STUB/screen" ;;
  keys) ;;
  get) [ "$(cat "$STUB/state")" != broken ] || exit 1
       if [ "$(cat "$STUB/state")" = none ]; then echo '{"name":"w-t1","status":null}'; else echo "{\"name\":\"w-t1\",\"status\":{\"state\":\"$(cat "$STUB/state")\"}}"; fi ;;
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
export STUB=$tmp/s
run() { : > "$STUB/calls"; printf '%s\n' "$2" > "$STUB/screen"; echo "$1" > "$STUB/state"
  PATH="$tmp/bin:$PATH" bash "$script" prompt --task t1 >/dev/null 2>&1; }
dialog=' Quick safety check
 ❯ 1. No, exit
   2. Yes, I trust this folder'

run blocked "$dialog"; rc=$?
[ $rc -eq 3 ] && ! grep -q '^keys' "$STUB/calls"; check "a blocked terminal showing the dialog's lines is not the dialog: exit 3, no key ($rc)" $?
run none " Bash command
   echo '❯ 2. Yes, I trust this folder' and '1. No, exit'
 Do you want to proceed?
 ❯ 1. Yes"; rc=$?
[ $rc -eq 3 ] && ! grep -q '^keys' "$STUB/calls"; check "the dialog's words inside a command are not the dialog: exit 3, no key ($rc)" $?
run none "$dialog
 Do you want to proceed?"; rc=$?
[ $rc -eq 3 ] && ! grep -q '^keys' "$STUB/calls"; check "a screen that also asks 'Do you want' is not the dialog ($rc)" $?
run broken "$dialog"; rc=$?
[ $rc -eq 3 ] && ! grep -q '^keys' "$STUB/calls"; check "a failed status lookup is not 'no status': exit 3, no key ($rc)" $?

# answer: Enter only with the cursor alone on the one-time Yes, as a whole line.
ans() { # ans <screen>: record the screen as a prompt entry, then answer yes; prints the exit code
  : > "$STUB/calls"; printf '{"work":[],"approvals":[]}\n' > "$STUB/docval-org-state"; rm -f "$STUB"/docver-*
  printf '%s\n' "$1" > "$STUB/screen"; echo blocked > "$STUB/state"
  e() { env -u PADDOCK_ORG_ID -u PADDOCK_SECRETARY_NAME PADDOCK_HC_HOLD=0 PADDOCK_STATE_DIR="$tmp/state" PATH="$tmp/bin:$PATH" bash "$script" "$@" 2>/dev/null; }
  p=$(e prompt --task t1 | sed -n 's/^PROMPT=//p')
  id=$(e ask --task t1 --question "q?" --prompt "$p" | sed -n 's/^APPROVAL_ID=//p')
  : > "$STUB/calls"; e answer --id "$id" --text yes >/dev/null; echo $?
}
rc=$(ans " Bash command
   printf '%s\\n' '  ❯ 1. Yes'
 Do you want to proceed?
   1. Yes
 ❯ 2. Yes, and don't ask again for printf commands")
[ "$rc" = 10 ] && ! grep -q '^keys' "$STUB/calls"; check "the cursor on 'Yes, and don't ask again' with '❯ 1. Yes' quoted above: no key ($rc)" $?
rc=$(ans " Bash command
   ls
 Do you want to proceed?
 ❯ 1. Yes
   2. No")
[ "$rc" = 0 ] && grep -q '^keys w-t1 enter' "$STUB/calls"; check "the cursor alone on '1. Yes': enter ($rc)" $?
[ "$fail" -eq 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
