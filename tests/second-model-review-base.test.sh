#!/usr/bin/env bash
# Review findings of Issue #177 on scripts/second-model-review.sh: the diff is taken against the base
# org-delegate recorded for the branch (branch.<name>.paddockBase), not always origin/main, and a branch
# whose commits cancel out (a change and its revert) has nothing to review, so the reviewer is not called.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
gate=$here/scripts/second-model-review.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
repo=$tmp/repo; mkdir -p "$repo" "$tmp/bin"
(
  cd "$repo" && git init -q -b main . && git config user.email t@example.com && git config user.name t \
    && echo one > a.txt && git add a.txt && git commit -q -m one \
    && git update-ref refs/remotes/origin/dev HEAD && git checkout -q -b work \
    && echo two >> a.txt && git commit -q -am two
) >/dev/null 2>&1
printf '#!/bin/sh\necho "$*" >> "$STUB_LOG"; echo " succeeded in 1ms:"\n' > "$tmp/bin/codex"; chmod +x "$tmp/bin/codex"
export STUB_LOG=$tmp/calls
run() { : > "$STUB_LOG"; out=$(cd "$repo" && TMPDIR="$tmp" PATH="$tmp/bin:$PATH" bash "$gate" 2>&1 </dev/null); rc=$?; }

run   # no origin/main in this fixture and no recorded base
[ "$rc" -eq 1 ] && ! grep -q . "$STUB_LOG"; check "no recorded base and no origin/main: nothing to review, reviewer not called" $?
git -C "$repo" config branch.work.paddockBase origin/dev
run
[ "$rc" -eq 0 ] && grep -q -- '--base origin/dev' "$STUB_LOG"; check "the recorded base is the review's base" $?
(cd "$repo" && git revert --no-edit HEAD >/dev/null 2>&1)
run
[ "$rc" -eq 1 ] && ! grep -q . "$STUB_LOG"; check "a change and its revert: commits ahead but no diff, reviewer not called" $?
# a command that exits non-zero is reported as "exited <n> in <time>" by the reviewer's text output
git -C "$repo" reset -q --hard HEAD~1 2>/dev/null
printf '#!/bin/sh\necho " succeeded in 1ms:"; echo " exited 1 in 4ms:"\n' > "$tmp/bin/codex"
run
[ "$rc" -eq 1 ] && grep -q 'not-established' <<<"$out"; check "a command that exited non-zero is not established" $?
exit $fail
