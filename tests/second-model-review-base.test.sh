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
# Issue #323: the base is the file org-delegate wrote in the state folder (<state>/bases/<task>, the task being the worktree's folder name)
mkdir -p "$tmp/state/bases"; echo origin/dev > "$tmp/state/bases/repo"
export PADDOCK_STATE_DIR=$tmp/state
run
[ "$rc" -eq 0 ] && grep -q -- '--base origin/dev' "$STUB_LOG"; check "the base recorded in the state folder is the review's base" $?
# A worktree made before #323 has the base in git config only: read it when the state folder has none.
rm "$tmp/state/bases/repo"; git -C "$repo" config branch.work.paddockBase origin/dev
run
[ "$rc" -eq 0 ] && grep -q -- '--base origin/dev' "$STUB_LOG"; check "no state file: the base in git config (older worktree) is still found" $?
# The state folder wins over git config.
git -C "$repo" branch origin/other HEAD~1; echo origin/other > "$tmp/state/bases/repo"
run
[ "$rc" -eq 0 ] && grep -q -- '--base origin/other' "$STUB_LOG"; check "the state folder's base wins over git config" $?
rm "$tmp/state/bases/repo"
(cd "$repo" && git revert --no-edit HEAD >/dev/null 2>&1)
run
[ "$rc" -eq 1 ] && ! grep -q . "$STUB_LOG"; check "a change and its revert: commits ahead but no diff, reviewer not called" $?
# a command that exits non-zero is reported as "exited <n> in <time>" by the reviewer's text output
git -C "$repo" reset -q --hard HEAD~1 2>/dev/null
printf '#!/bin/sh\necho " succeeded in 1ms:"; echo " exited 1 in 4ms:"\n' > "$tmp/bin/codex"
run
[ "$rc" -eq 1 ] && grep -q 'not-established' <<<"$out"; check "a command that exited non-zero is not established" $?
# The gate runs outside the worker sandbox: the log is a fresh mktemp file, never a path a worker can pre-create,
# and a CODEX_HOME that is a symlink is refused before anything is written through it.
printf '#!/bin/sh\necho " succeeded in 1ms:"\n' > "$tmp/bin/codex"
mkdir -p "$tmp/victim"; : > "$tmp/victim/keep"; mkdir -p "$tmp/tmpd"
for n in 1 2 3; do ln -sf "$tmp/victim/keep" "$tmp/tmpd/second-review-diff.$n" 2>/dev/null; done
ln -sf "$tmp/victim/keep" "$tmp/tmpd/second-review-diff.log"
echo precious > "$tmp/victim/keep"
: > "$STUB_LOG"; out=$(cd "$repo" && TMPDIR="$tmp/tmpd" PATH="$tmp/bin:$PATH" bash "$gate" 2>&1 </dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$tmp/victim/keep")" = precious ]; check "a pre-made link in the temp folder is not written through" $?
rm -rf "$repo/.codex-home"; ln -s "$tmp/victim" "$repo/.codex-home"
out=$(cd "$repo" && TMPDIR="$tmp/tmpd" PATH="$tmp/bin:$PATH" bash "$gate" 2>&1 </dev/null); rc=$?
[ "$rc" -eq 1 ] && grep -q 'symlink' <<<"$out" && [ ! -e "$tmp/victim/auth.json" ] && [ ! -L "$tmp/victim/auth.json" ]; check "a symlinked .codex-home is refused, nothing written through it" $?
exit $fail
