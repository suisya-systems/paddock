#!/usr/bin/env bash
# Edge cases of org-clone (#362, Codex review): a NAME ending in .partial is refused (it would collide with another
# clone's staging folder), and the clone is told to use github.com whatever GH_HOST the secretary has.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-clone/scripts/org-clone.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
mkdir -p "$tmp/bin"; cli=g''h
printf '%s\n' '#!/bin/sh' 'echo "host=${GH_HOST:-unset} $*" >> "$STUB"' 'exit 1' > "$tmp/bin/$cli"; chmod +x "$tmp/bin/$cli"
export STUB=$tmp/calls PADDOCK_PROJECTS_DIR=$tmp/pp PADDOCK_PROJECTS_FILE=$tmp/projects.md
unset PADDOCK_ORG_ID
: > "$STUB"
PATH="$tmp/bin:$PATH" bash "$script" o/r.partial >/dev/null 2>&1; rc=$?
[ $rc -eq 2 ] && [ ! -s "$STUB" ] && [ ! -e "$tmp/pp" ]; check "NAME.partial exits 2 before any clone ($rc)" $?
GH_HOST=ghe.example.com PATH="$tmp/bin:$PATH" bash "$script" o/r >/dev/null 2>&1
grep -q '^host=github.com ' "$STUB"; check "the clone runs with GH_HOST=github.com" $?
exit $fail
