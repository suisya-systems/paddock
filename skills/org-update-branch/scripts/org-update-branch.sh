#!/usr/bin/env bash
# org-update-branch: take origin/<base> into the worktree's branch with a merge (never a rebase), so
# the next push is a fast-forward and needs no force. In a worker it stops before the merge when the
# incoming range touches a path the sandbox protects. Needs bash and git. See ../SKILL.md.
set -u

usage() {
  cat <<'USAGE'
Usage: org-update-branch.sh [--worktree DIR] [--base BRANCH]

Fetches origin, then merges origin/<base> into the branch checked out in DIR. On a conflict the
merge is aborted and the branch is left as it was.

Options:
  --worktree DIR   the worktree to update (default: current directory)
  --base BRANCH    base branch (default: main)
  -h, --help       this text

Exit codes: 0 merged or already up to date; 2 bad argument; 3 git not found; 4 worker: the incoming
range touches a protected path (nothing changed; the secretary runs this outside the sandbox);
5 fetch failed or no origin/<base>; 6 merge conflict (aborted, branch unchanged); 7 tracked files
have uncommitted changes (nothing changed).

A worker is told apart by PADDOCK_ORG, which only the worker's launch command sets.
USAGE
}
die() { code=$1; shift; echo "org-update-branch: $*" >&2; exit "$code"; }

wt=.; base=main
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --worktree) [ $# -ge 2 ] || die 2 "--worktree needs a value"; wt=$2; shift 2 ;;
    --base) [ $# -ge 2 ] || die 2 "--base needs a value"; base=$2; shift 2 ;;
    *) usage >&2; die 2 "unknown argument: $1" ;;
  esac
done

command -v git >/dev/null 2>&1 || die 3 "git not found on PATH"
git -C "$wt" symbolic-ref -q HEAD >/dev/null || die 2 "no branch checked out in $wt"

git -C "$wt" fetch -q origin 2>/dev/null || die 5 "git fetch origin failed"
git -C "$wt" rev-parse -q --verify "refs/remotes/origin/$base^{commit}" >/dev/null || die 5 "no origin/$base after the fetch"
[ -z "$(git -C "$wt" status --porcelain --untracked-files=no)" ] || die 7 "tracked files have uncommitted changes; commit them first"

if git -C "$wt" merge-base --is-ancestor "origin/$base" HEAD; then echo "already up to date with origin/$base"; exit 0; fi

# The paths Claude Code's sandbox makes read-only in a worktree (measured in GT-3, Issue #50); a
# merge over one of them stops the same way a rebase does. ponytail: a fixed list; read it from the
# placed settings if the sandbox ever protects more.
if [ -n "${PADDOCK_ORG:-}" ]; then
  mb=$(git -C "$wt" merge-base HEAD "origin/$base") || die 5 "no merge base with origin/$base"
  hit=$(git -C "$wt" diff --name-only "$mb" "origin/$base" | grep -E '^\.claude/(skills|hooks)(/|$)|^\.claude/settings(\.local)?\.json$')
  if [ -n "$hit" ]; then
    echo "$hit" | sed 's/^/protected: /' >&2
    die 4 "origin/$base changes paths this sandbox protects (listed above); nothing was merged. Ask the secretary to run org-update-branch outside the sandbox"
  fi
fi

if ! git -C "$wt" merge --no-edit "origin/$base" >/dev/null 2>&1; then
  git -C "$wt" merge --abort >/dev/null 2>&1
  die 6 "merging origin/$base conflicts; aborted, the branch is unchanged. Resolve by hand"
fi
echo "merged origin/$base into $(git -C "$wt" symbolic-ref --short HEAD) at $(git -C "$wt" rev-parse --short HEAD)"
