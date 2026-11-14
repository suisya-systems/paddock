#!/usr/bin/env bash
# Issue #330: in a worker (PADDOCK_ORG set) org-update-branch does not stop on a failed fetch (the worker
# sandbox cannot reach GitHub); it checks and merges with the origin/<base> the secretary already fetched.
# Without origin/<base> it still exits 5 and says to ask the secretary. The secretary (PADDOCK_ORG unset)
# keeps exit 5 on a failed fetch. A local bare repository stands in for origin; breaking its URL after
# the fetch stands in for the sandbox's refused connection.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-update-branch/scripts/org-update-branch.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# fresh <name> <path>: main moves by one commit adding <path>; the clone fetched it; then origin is unreachable.
fresh() {
  o=$tmp/$1.git; w=$tmp/$1; up=$tmp/$1-up
  git init -q --bare -b main "$o"
  git clone -q "$o" "$up" 2>/dev/null
  (cd "$up" && echo base > base.txt && git add base.txt && git commit -qm base && git push -q origin main)
  git clone -q "$o" "$w" 2>/dev/null
  (cd "$w" && git checkout -qb feat/x && echo work > work.txt && git add work.txt && git commit -qm work)
  (cd "$up" && mkdir -p "$(dirname "$2")" && echo up > "$2" && git add -f "$2" && git commit -qm "main: $2" && git push -q origin main)
  git -C "$w" fetch -q origin
  git -C "$w" remote set-url origin "$tmp/unreachable.git"
}
head_of() { git -C "$tmp/$1" rev-parse HEAD; }
worker() { local n=$1; shift; PADDOCK_ORG=/x/org bash "$script" --worktree "$tmp/$n" "$@"; }

fresh a docs/plain.txt
out=$(worker a 2>&1); rc=$?
[ "$rc" -eq 0 ]; check "worker, fetch fails, ordinary range: exit 0 ($rc)" $?
git -C "$tmp/a" merge-base --is-ancestor origin/main HEAD; check "worker, fetch fails: the branch holds the already fetched origin/main" $?
grep -qi 'fetch' <<<"$out"; check "worker, fetch fails: the output says the fetch failed" $?

p=.claude/skills/x/SKILL.md
fresh b "$p"; before=$(head_of b)
out=$(worker b 2>&1); rc=$?
[ "$rc" -eq 4 ] && [ "$(head_of b)" = "$before" ]; check "worker, fetch fails, protected range: exit 4, branch unchanged ($rc)" $?
grep -q -- "$p" <<<"$out"; check "worker, fetch fails: the protected path is named" $?

fresh c docs/plain.txt; before=$(head_of c)
out=$(worker c --base nope 2>&1); rc=$?
[ "$rc" -eq 5 ] && [ "$(head_of c)" = "$before" ]; check "worker, no origin/<base>: exit 5, branch unchanged ($rc)" $?
grep -qi 'secretary' <<<"$out"; check "worker, no origin/<base>: says to ask the secretary to fetch" $?

fresh d docs/plain.txt; before=$(head_of d)
env -u PADDOCK_ORG bash "$script" --worktree "$tmp/d" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 5 ] && [ "$(head_of d)" = "$before" ]; check "secretary, fetch fails: still exit 5, branch unchanged ($rc)" $?
exit $fail
