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

Every exit prints one line "next: <exact action>" (or "next: ask the person: <question>"): do that.
Exit codes: 0 merged or already up to date; 2 bad argument; 3 git not found; 4 worker: the incoming
range touches a protected path (nothing changed; the secretary runs this outside the sandbox);
5 the secretary's fetch failed (a worker goes on with the origin/<base> already fetched), or
no origin/<base>; 6 merge conflict (aborted, branch unchanged); 7 tracked files
have uncommitted changes (nothing changed).

A worker is told apart by PADDOCK_ORG, which only the worker's launch command sets.
USAGE
}
# die <code> <message> <next>: every non-zero exit ends with one `next:` line (decision 0014).
die() { echo "org-update-branch: $2" >&2; echo "next: $3" >&2; exit "$1"; }
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
self=$root/skills/org-update-branch/scripts/org-update-branch.sh
qself=$(printf "%q" "$self")
fixcall="fix the call (bash $qself --help)"

wt=.; base=main
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --worktree) [ $# -ge 2 ] || die 2 "--worktree needs a value" "$fixcall"; wt=$2; shift 2 ;;
    --base) [ $# -ge 2 ] || die 2 "--base needs a value" "$fixcall"; base=$2; shift 2 ;;
    *) usage >&2; die 2 "unknown argument: $1" "$fixcall" ;;
  esac
done

qwt=$(printf "%q" "$wt")
command -v git >/dev/null 2>&1 || die 3 "git not found on PATH" "ask the person: git is not on PATH; can they install it?"
git -C "$wt" symbolic-ref -q HEAD >/dev/null || die 2 "no branch checked out in $wt" "$fixcall (--worktree must be the worker's worktree)"

if ! git -C "$wt" fetch -q origin 2>/dev/null; then
  # A worker's sandbox cannot reach GitHub (docs/design/worker-github-access.md): it goes on with the
  # origin/<base> the secretary fetched in the project clone. The secretary's own failed fetch stays exit 5.
  [ -n "${PADDOCK_ORG:-}" ] || die 5 "git fetch origin failed" "run git fetch origin in the project clone yourself, then rerun: bash $qself --worktree $qwt --base $base; if the fetch fails there too, ask the person: origin cannot be reached; why?"
  echo "org-update-branch: fetch failed (a worker cannot fetch); using the existing origin/$base" >&2
fi
git -C "$wt" rev-parse -q --verify "refs/remotes/origin/$base^{commit}" >/dev/null \
  || die 5 "no origin/$base; a worker cannot fetch, ask the secretary to run git fetch origin in the project clone" "run git fetch origin in the project clone, then rerun: bash $qself --worktree $qwt --base $base"
[ -z "$(git -C "$wt" status --porcelain --untracked-files=no)" ] || die 7 "tracked files have uncommitted changes; commit them first" "have the worker commit its changes, then rerun: bash $qself --worktree $qwt --base $base"

next_ok="next: run the org-pull-request skill: bash skills/org-pull-request/scripts/org-pull-request.sh --pr <n> --worktree $qwt (it sends the branch, no force, and requests CI for the new head)"
if git -C "$wt" merge-base --is-ancestor "origin/$base" HEAD; then echo "already up to date with origin/$base"; echo "$next_ok"; exit 0; fi

# The paths Claude Code's sandbox makes read-only in a worktree (measured in GT-3); a
# merge over one of them stops the same way a rebase does. ponytail: a fixed list; read it from the
# placed settings if the sandbox ever protects more.
if [ -n "${PADDOCK_ORG:-}" ]; then
  mb=$(git -C "$wt" merge-base HEAD "origin/$base") || die 5 "no merge base with origin/$base" "ask the person: the branch shares no history with origin/$base; is --base right?"
  hit=$(git -C "$wt" diff --no-renames --name-only "$mb" "origin/$base" | grep -E '^\.claude/(skills|hooks)(/|$)|^\.claude/settings(\.local)?\.json$')
  if [ -n "$hit" ]; then
    echo "$hit" | sed 's/^/protected: /' >&2
    die 4 "origin/$base changes paths this sandbox protects (listed above); nothing was merged. Ask the secretary to run org-update-branch outside the sandbox" \
      "run it from your own shell, outside the worker's sandbox: bash $qself --worktree $qwt --base $base"
  fi
fi

if ! git -C "$wt" merge --no-edit "origin/$base" >/dev/null 2>&1; then
  git -C "$wt" merge --abort >/dev/null 2>&1
  die 6 "merging origin/$base conflicts; aborted, the branch is unchanged. Resolve by hand" \
    "send the worker back to resolve the conflict with origin/$base in $wt (its branch is unchanged), then it pushes; or resolve it by hand"
fi
echo "merged origin/$base into $(git -C "$wt" symbolic-ref --short HEAD) at $(git -C "$wt" rev-parse --short HEAD)"
echo "$next_ok"
