#!/usr/bin/env bash
# Decision 0014, wave 2 unit 5: org-update-branch prints one `next: ...` line on every exit, and its
# SKILL.md has the 0014 form (when_to_use, allowed-tools, no exit-code table, under 12 KB).
# A local bare repository stands in for origin.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
script=$here/skills/org-update-branch/scripts/org-update-branch.sh
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

fresh() { # fresh <name>: origin with main, clone on feat/x one commit ahead
  o=$tmp/$1.git; w=$tmp/$1; up=$tmp/$1-up
  git init -q --bare -b main "$o"; git clone -q "$o" "$up" 2>/dev/null
  (cd "$up" && echo base > base.txt && git add base.txt && git commit -qm base && git push -q origin main)
  git clone -q "$o" "$w" 2>/dev/null
  (cd "$w" && git checkout -qb feat/x && echo work > work.txt && git add work.txt && git commit -qm work)
}
upstream() { (cd "$tmp/$1-up" && mkdir -p "$(dirname "$2")" && echo "${3:-up}" > "$2" && git add -f "$2" && git commit -qm "main: $2" && git push -q origin main); }
run() { local n=$1; shift; env -u PADDOCK_ORG "$@" bash "$script" --worktree "$tmp/$n" 2>&1; }
nexts() { grep -c '^next: ' <<<"$1"; }

fresh a; upstream a docs/new.txt
out=$(run a); rc=$?
[ "$rc" -eq 0 ] && [ "$(nexts "$out")" -eq 1 ] && grep -q '^next: .*org-pull-request.sh.*--pr' <<<"$out"; check "merged: exit 0, next: reruns org-pull-request with --pr ($out)" $?
out=$(run a); rc=$?
[ "$rc" -eq 0 ] && [ "$(nexts "$out")" -eq 1 ]; check "already up to date: exit 0, one next: line" $?

out=$(bash "$script" --no-such-flag 2>&1); rc=$?
[ "$rc" -eq 2 ] && [ "$(nexts "$out")" -eq 1 ]; check "exit 2: one next: line" $?
fresh b; echo dirty >> "$tmp/b/work.txt"; upstream b docs/new.txt
out=$(run b); rc=$?
[ "$rc" -eq 7 ] && [ "$(nexts "$out")" -eq 1 ]; check "exit 7: one next: line" $?
fresh c; upstream c f.txt one; (cd "$tmp/c" && echo two > f.txt && git add f.txt && git commit -qm "branch f"); upstream c f.txt three
out=$(run c); rc=$?
[ "$rc" -eq 6 ] && [ "$(nexts "$out")" -eq 1 ]; check "exit 6: one next: line" $?
fresh d; upstream d .claude/skills/x/SKILL.md
out=$(run d PADDOCK_ORG=1); rc=$?
[ "$rc" -eq 4 ] && [ "$(nexts "$out")" -eq 1 ] && grep -q '^next: .*org-update-branch.sh' <<<"$out"; check "exit 4: next: names the command to run outside the worker ($out)" $?
fresh e; git -C "$tmp/e" remote set-url origin "$tmp/missing.git"
out=$(run e); rc=$?
[ "$rc" -eq 5 ] && [ "$(nexts "$out")" -eq 1 ]; check "exit 5: one next: line" $?
mkdir -p "$tmp/nogit"
out=$(env PATH="$tmp/nogit" /bin/bash "$script" --worktree "$tmp/a" 2>&1); rc=$?
[ "$rc" -eq 3 ] && [ "$(nexts "$out")" -eq 1 ]; check "exit 3: one next: line" $?

# SKILL.md: the 0014 form.
sk=$here/skills/org-update-branch/SKILL.md
fm=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$sk")
grep -Eq '^when_to_use:[[:space:]]*[^[:space:]]' <<<"$fm"; check "SKILL.md has when_to_use" $?
[ "$(printf '%s' "$fm" | grep -E '^(description|when_to_use):' | wc -c)" -lt 1536 ]; check "description + when_to_use under 1,536 characters" $?
[ "$(wc -c < "$sk")" -lt 12288 ]; check "SKILL.md under 12 KB" $?
grep -q '^allowed-tools:.*org-update-branch.sh' <<<"$fm"; check "SKILL.md allowed-tools names the skill's own script" $?
! grep -qE '^\| (Code|[0-9]+) \|' "$sk"; check "no exit-code table in SKILL.md" $?
grep -q 'next:' "$sk"; check "SKILL.md points at the next: lines" $?
exit $fail
