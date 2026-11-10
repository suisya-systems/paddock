#!/usr/bin/env bash
# org-issue: a --depends value that is empty or holds several words is refused, not dropped
# (Codex review round 1 of Issue #72). Stubbed `gh`; nothing reaches GitHub.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
script=$here/skills/org-issue/scripts/org-issue.sh
mkdir -p "$tmp/bin"
printf '#!/bin/sh\necho "gh $*" >> "%s/calls"\nexit 0\n' "$tmp" > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"

for v in "" "1 2" " " "#5"; do
  : > "$tmp/calls"
  PATH="$tmp/bin:$PATH" bash "$script" --repo o/r --kind build --title t --goal "G2 x" --why w --done d --depends "$v" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] && ! grep -q 'issue create' "$tmp/calls"; check "--depends '$v' is refused, nothing created" $?
done
exit $fail
