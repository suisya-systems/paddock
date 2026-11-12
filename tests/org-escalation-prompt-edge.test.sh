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
  get) if [ "$(cat "$STUB/state")" = none ]; then echo '{"name":"w-t1","status":null}'; else echo "{\"name\":\"w-t1\",\"status\":{\"state\":\"$(cat "$STUB/state")\"}}"; fi ;;
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
[ "$fail" -eq 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
