#!/usr/bin/env bash
# Issue #376: the secretary watches CI only through org-pull-request's child (hc wait ci-<pr>) and
# org wait, never by its own blocking gh pr checks --watch, and quotes the CI result, not a local run.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

for f in templates/secretary.md skills/org-pull-request/SKILL.md; do
  t=$here/$f
  grep -qF 'hc wait ci-<pr>' "$t"; check "$f names the watch path hc wait ci-<pr>" $?
  grep -qF 'org wait --children' "$t"; check "$f names org wait --children" $?
  grep -F 'gh pr checks --watch' "$t" | grep -qE '[Nn]ever'; check "$f forbids gh pr checks --watch" $?
  grep -F 'ci_completed' "$t" | grep -qF 'local test run'; check "$f: the CI result is quoted, not a local run" $?
done
grep -E '^\| 8 \|' "$here/skills/org-pull-request/SKILL.md" | grep -qF 'org wait --children'; check "skill: exit 8 goes back to org wait" $?
exit $fail
