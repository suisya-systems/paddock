#!/usr/bin/env bash
# Acceptance test for skills/org-update-branch/scripts/org-update-branch.sh (Issue #187).
# Needs only bash, coreutils and git: a local bare repository stands in for origin.
#   exit 0 merged (or already up to date)   4 worker: the incoming range touches a protected path
#   5 fetch failed   6 merge conflict (aborted, branch unchanged)   7 worktree not clean
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
script=$here/skills/org-update-branch/scripts/org-update-branch.sh
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# fresh <name>: origin (bare) with main, a clone "$tmp/<name>" on feat/x (one commit ahead, sent to origin).
fresh() {
  o=$tmp/$1.git; w=$tmp/$1; up=$tmp/$1-up
  git init -q --bare -b main "$o"
  git clone -q "$o" "$up" 2>/dev/null
  (cd "$up" && echo base > base.txt && git add base.txt && git commit -qm base && git push -q origin main)
  git clone -q "$o" "$w" 2>/dev/null
  (cd "$w" && git checkout -qb feat/x && echo work > work.txt && git add work.txt && git commit -qm work && git push -q origin feat/x)
}
# upstream <name> <path>: main moves one commit, adding <path>.
upstream() { (cd "$tmp/$1-up" && mkdir -p "$(dirname "$2")" && echo up > "$2" && git add -f "$2" && git commit -qm "main: $2" && git push -q origin main); }
head_of() { git -C "$tmp/$1" rev-parse HEAD; }
# secretary run: PADDOCK_ORG is set only in a worker's environment, so it is unset here.
run() { local n=$1; shift; env -u PADDOCK_ORG bash "$script" --worktree "$tmp/$n" "$@"; }

[ -f "$script" ]; check "script exists" $?
[ -f "$here/skills/org-update-branch/SKILL.md" ]; check "SKILL.md exists" $?
bash -n "$script" 2>/dev/null; check "script parses" $?
out=$(bash "$script" --help 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -qi usage <<<"$out"; check "--help exits 0 with usage" $?
bash "$script" --no-such-flag >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; check "unknown argument exits 2" $?

# Main one commit ahead: the branch contains it, through a merge, so the next send needs no force.
fresh a; upstream a docs/new.txt; before=$(head_of a)
run a >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; check "main one commit ahead: exit 0" $?
git -C "$tmp/a" merge-base --is-ancestor origin/main HEAD; check "the branch contains origin/main" $?
[ -f "$tmp/a/docs/new.txt" ]; check "the incoming file is in the working tree" $?
[ "$(git -C "$tmp/a" rev-parse HEAD^1)" = "$before" ] && [ "$(git -C "$tmp/a" rev-list --parents -1 HEAD | wc -w)" -eq 3 ]; check "the result is a merge commit on top of the old head (no rebase)" $?
git -C "$tmp/a" merge-base --is-ancestor origin/feat/x HEAD; check "the branch already on origin is an ancestor, so the send is a fast-forward" $?
(cd "$tmp/a" && git push -q origin feat/x 2>/dev/null); check "a plain send (no force) is accepted" $?
run a >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ "$(head_of a)" = "$(git -C "$tmp/a" rev-parse origin/feat/x)" ]; check "already up to date: exit 0, no new commit" $?

# A worker: the range touches a protected path -> its own exit code, branch unchanged.
for p in .claude/skills/x/SKILL.md .claude/hooks/h.sh .claude/settings.json .claude/settings.local.json; do
  n=w$(printf '%s' "$p" | tr -c 'a-z' '_'); fresh "$n"; upstream "$n" "$p"; before=$(head_of "$n")
  out=$(env PADDOCK_ORG=/x/org bash "$script" --worktree "$tmp/$n" 2>&1); rc=$?
  [ "$rc" -eq 4 ]; check "worker, range touches $p: exit 4" $?
  [ "$(head_of "$n")" = "$before" ] && [ -z "$(git -C "$tmp/$n" status --porcelain --untracked-files=no)" ] && [ ! -e "$tmp/$n/$p" ]; check "worker, $p: branch and working tree unchanged" $?
  grep -q -- "$p" <<<"$out"; check "worker, $p: the protected path is named" $?
done
n=wok; fresh $n; upstream $n docs/plain.txt
env PADDOCK_ORG=/x/org bash "$script" --worktree "$tmp/$n" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && git -C "$tmp/$n" merge-base --is-ancestor origin/main HEAD; check "worker, ordinary range: merged" $?

# The secretary (outside the sandbox) is not stopped by the same range.
fresh s; upstream s .claude/skills/x/SKILL.md
run s >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ -f "$tmp/s/.claude/skills/x/SKILL.md" ]; check "secretary, protected path in range: merged" $?

# A conflict: aborted, the branch unchanged, exit 6.
fresh c; (cd "$tmp/c" && echo mine > clash.txt && git add clash.txt && git commit -qm mine)
(cd "$tmp/c-up" && echo theirs > clash.txt && git add clash.txt && git commit -qm theirs && git push -q origin main)
before=$(head_of c); run c >/dev/null 2>&1; rc=$?
[ "$rc" -eq 6 ] && [ "$(head_of c)" = "$before" ] && [ -z "$(git -C "$tmp/c" status --porcelain --untracked-files=no)" ] && [ ! -e "$tmp/c/.git/MERGE_HEAD" ]; check "conflict: exit 6, merge aborted, branch unchanged" $?

# A dirty tracked file: refused before the merge, exit 7.
fresh d; upstream d docs/new.txt; echo dirty >> "$tmp/d/work.txt"; before=$(head_of d)
run d >/dev/null 2>&1; rc=$?
[ "$rc" -eq 7 ] && [ "$(head_of d)" = "$before" ]; check "uncommitted change: exit 7, nothing merged" $?

# Fetch failure.
fresh f; git -C "$tmp/f" remote set-url origin "$tmp/nonexistent.git"
run f >/dev/null 2>&1; rc=$?
[ "$rc" -eq 5 ]; check "fetch failure: exit 5" $?

# --base names another base branch.
fresh b; (cd "$tmp/b-up" && git checkout -qb dev && echo dev > dev.txt && git add dev.txt && git commit -qm dev && git push -q origin dev)
run b --base dev >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ -f "$tmp/b/dev.txt" ]; check "--base dev merges origin/dev" $?

exit $fail
