#!/usr/bin/env bash
# Issue #376, decision 0013 stage 3: the secretary never watches CI itself (no blocking gh pr checks
# --watch), org-pull-request holds no watch of its own (no hc wait ci-<pr>), the watcher watches, and
# the secretary quotes the watcher's CI result, not a local run.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

for f in skills/org-pull-request/SKILL.md; do
  t=$here/$f
  ! grep -qF 'hc wait ci-<pr>' "$t"; check "$f no longer names the skill's own watch hc wait ci-<pr>" $?
  ! grep -qF 'org wait --children' "$t"; check "$f does not send CI through org wait --children" $?
  grep -qi 'watcher' "$t"; check "$f names the watcher" $?
  grep -qF 'ci_requested' "$t"; check "$f names ci_requested" $?
  grep -F 'gh pr checks --watch' "$t" | grep -qE '[Nn]ever'; check "$f forbids gh pr checks --watch" $?
  grep -F 'ci_completed' "$t" | grep -qF 'local test run'; check "$f: the CI result is quoted, not a local run" $?
done
! grep -Eq 'hc (run|wait)|gh run (list|watch)' "$here/skills/org-pull-request/scripts/org-pull-request.sh"; check "the skill script has no CI watch of its own" $?
! grep -Eq '^\| (7|8) \|' "$here/skills/org-pull-request/SKILL.md"; check "skill: exits 7 and 8 (run lookup, watch) are gone" $?
exit $fail
