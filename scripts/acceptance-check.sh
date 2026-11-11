#!/usr/bin/env bash
# acceptance-check: the CI check that replaces the predecessor's acceptance gate (Q11 decided (d),
# inventory GT-1 and HK-15). Run from the repository root on full history:
#   bash scripts/acceptance-check.sh BASE_SHA HEAD_SHA
# The branch's own commits are HEAD's first-parent line not reachable from BASE; the oldest of
# them (whose parent is then in BASE) may declare tests with "Acceptance-Test: <path>" trailers
# (file or directory). The base may be merged in after it (no force push). When it declares:
#   - it is the only commit that declares, and it changes only declared paths and test helpers;
#   - every declared *.test.sh (directories: every *.test.sh under them) fails at that commit
#     and passes at HEAD (each runs as `bash <path>` from the tree root);
#   - the test commit is not a merge, and the branch's own commits after it leave the declared
#     paths, test helpers (files under tests/ that are not *.test.sh), .github/ and this script
#     unchanged (what a merge brings from its other parents does not count).
# Last line: ACCEPTANCE: pass | none | fail. Exit 0 pass or none (nothing declared), 1 fail, 2 usage.
set -u
[ $# -eq 2 ] || { echo "usage: acceptance-check.sh BASE_SHA HEAD_SHA" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "acceptance-check: not in a git repository" >&2; exit 2; }
head=$(git rev-parse --verify "$2^{commit}" 2>/dev/null) || { echo "acceptance-check: unknown head $2" >&2; exit 2; }
mb=$(git merge-base "$1" "$head" 2>/dev/null) || { echo "acceptance-check: no merge base of $1 and $2" >&2; exit 2; }

bad=0
no() { echo "acceptance-check: $*"; bad=1; }
declared() { git log -1 --format='%(trailers:key=Acceptance-Test,valueonly)' "$1" | sed '/^[[:space:]]*$/d'; }

commits=$(git rev-list --reverse --first-parent "$head" --not "$1")
first=$(printf '%s\n' "$commits" | head -1)
[ -n "$first" ] && paths=$(declared "$first") || paths=
for c in $(printf '%s\n' "$commits" | tail -n +2); do
  [ -z "$(declared "$c")" ] || no "commit $c declares Acceptance-Test but is not the first commit of the branch"
done
if [ -z "$paths" ]; then
  [ "$bad" -eq 0 ] || { echo "ACCEPTANCE: fail"; exit 1; }
  echo "acceptance-check: no Acceptance-Test trailer on the first commit; nothing to check"
  echo "ACCEPTANCE: none"; exit 0
fi
echo "acceptance-check: test commit $first declares: $(echo $paths)"
[ "$(git rev-list --parents -n 1 "$first" | wc -w)" -eq 2 ] || no "test commit $first is a merge; no join commit may come before or at the test commit"

under() { # under <file> <path>: the file is the path or inside it
  local p=${2%/}; [ "$1" = "$p" ] || case $1 in "$p"/*) true ;; *) false ;; esac
}
is_helper() { case $1 in tests/*.test.sh) false ;; tests/*) true ;; *) false ;; esac; }
is_declared() { local p; while IFS= read -r p; do under "$1" "$p" && return 0; done <<<"$paths"; return 1; }

# 1. the test commit changes only declared paths and test helpers
while IFS= read -r f; do
  [ -n "$f" ] || continue
  is_declared "$f" || is_helper "$f" || no "test commit changes $f, which is neither declared nor a test helper"
done < <(git diff --no-renames --name-only "$first^" "$first")

# 2. protected paths unchanged by the branch's own commits after the test commit. A merge (of
# the base) counts only for files it leaves different from every parent: its own resolution.
own_changes() {
  local c ps p
  for c in $(printf '%s\n' "$commits" | tail -n +2); do
    ps=$(git rev-list --parents -n 1 "$c" | cut -d' ' -f2-)
    if [ "$(echo $ps | wc -w)" -eq 1 ]; then
      git diff --no-renames --name-only "$c^" "$c"
    else
      local f
      for p in $ps; do git diff --no-renames --name-only "$p" "$c"; done | sort | uniq -c |
        while read -r n f; do [ "$n" -lt "$(echo $ps | wc -w)" ] || printf '%s\n' "$f"; done
    fi
  done | sed '/^$/d' | sort -u
}
# A merge may bring in only the base: a side branch's own commits are off the first-parent line.
for c in $(printf '%s\n' "$commits" | tail -n +2); do
  for p in $(git rev-list --parents -n 1 "$c" | cut -d' ' -f3-); do
    git merge-base --is-ancestor "$p" "$1" || no "merge $c brings in $p, which is not in the base"
  done
done
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if is_declared "$f" || is_helper "$f" || under "$f" .github || [ "$f" = scripts/acceptance-check.sh ]; then
    no "$f changed after the test commit (declared tests, test helpers, .github/ and this script are protected)"
  fi
done < <(own_changes)

# 3. declared tests fail at the test commit and pass at head
work=$(mktemp -d)
trap 'git worktree remove --force "$work/t" >/dev/null 2>&1; git worktree remove --force "$work/h" >/dev/null 2>&1; rm -rf "$work"' EXIT
git worktree add -q --detach "$work/t" "$first" && git worktree add -q --detach "$work/h" "$head" \
  || { echo "acceptance-check: git worktree add failed" >&2; echo "ACCEPTANCE: fail"; exit 1; }
tests=
while IFS= read -r p; do
  p=${p%/}
  if [ -f "$work/t/$p" ]; then
    case $p in *.test.sh) tests+=$p$'\n' ;; esac
  elif [ -d "$work/t/$p" ]; then
    tests+=$(cd "$work/t" && find "$p" -type f -name '*.test.sh' | sort)$'\n'
  else
    no "declared path $p does not exist at the test commit"
  fi
done <<<"$paths"
tests=$(printf '%s' "$tests" | sed '/^$/d')
[ -n "$tests" ] || no "no *.test.sh among the declared paths; nothing was run"
while IFS= read -r t; do
  [ -n "$t" ] || continue
  if (cd "$work/t" && bash "$t") >"$work/out" 2>&1; then
    no "$t passes at the test commit $first; it must fail before the fix"
  else
    echo "acceptance-check: $t fails at the test commit (expected)"
  fi
  if (cd "$work/h" && bash "$t") >"$work/out" 2>&1; then
    echo "acceptance-check: $t passes at head"
  else
    no "$t fails at head $head:"; sed 's/^/  /' "$work/out" | tail -20
  fi
done <<<"$tests"

if [ "$bad" -eq 0 ]; then echo "ACCEPTANCE: pass"; exit 0; fi
echo "ACCEPTANCE: fail"; exit 1
