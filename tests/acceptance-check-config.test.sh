#!/usr/bin/env bash
# Issue #265. The organization's landing gate reads .github/acceptance-check on the base
# branch: one line naming the repository's own test-first CI check. Needs only bash and grep.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cfg=$here/.github/acceptance-check
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

[ -f "$cfg" ]; check ".github/acceptance-check exists" $?
[ "$(grep -c . "$cfg" 2>/dev/null)" -eq 1 ] && [ "$(wc -l < "$cfg")" -le 1 ]; check "it holds exactly one non-empty line" $?
name=$(grep . "$cfg" 2>/dev/null | head -n1)
[ -n "$name" ] && grep -qE "^  $name:" "$here/.github/workflows/ci.yml"; check "job '$name' exists in .github/workflows/ci.yml" $?
grep -q '\.github/acceptance-check' "$here/docs/design/acceptance-check.md"; check "docs/design/acceptance-check.md mentions it" $?
exit "$fail"
