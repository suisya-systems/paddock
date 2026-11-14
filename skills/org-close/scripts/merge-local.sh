#!/usr/bin/env bash
# merge-local: close a local-repository task without a PR. See ../SKILL.md. Needs only bash and git.
set -u

usage() {
  cat <<'USAGE'
Usage: merge-local.sh --task <task_id>

After the owner agreed: fast-forwards main of the task's local repository to the worker's branch
(git merge --ff-only), so the repository itself holds the result. Refuses unless the worktree
$PADDOCK_WORKERS_DIR/<id> belongs to $PADDOCK_LOCAL_DIR/<id>, has no uncommitted tracked change,
and main can fast-forward. Pushes nothing. Then run org-close as usual.

Exit codes: 0 merged (or main already there), 2 bad argument, 3 git not found, 6 refused
(named on stderr).
USAGE
}

die() { code=$1; shift; echo "merge-local: $*" >&2; exit "$code"; }

task=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --task) [ $# -ge 2 ] || die 2 "--task needs a value"; task=$2; shift 2 ;;
    *) echo "merge-local: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$task" in ''|-*|*[!a-z0-9_-]*) die 2 "--task <task_id> is required: lowercase letters, digits, _ and -" ;; esac
command -v git >/dev/null 2>&1 || die 3 "git not found on PATH"

wt=${PADDOCK_WORKERS_DIR:-$HOME/paddock-workers}/$task
repo=${PADDOCK_LOCAL_DIR:-$HOME/paddock-local}/$task
git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 || die 6 "$wt is not a git worktree"
# the repository must be the task's own local one: this never merges into someone's real project
common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
[ "$common" = "$(cd "$repo" 2>/dev/null && pwd -P)/.git" ] || [ "$common" = "$repo/.git" ] \
  || die 6 "$wt does not belong to $repo; only a repository made by local-repo.sh is merged here"
branch=$(git -C "$wt" symbolic-ref -q --short HEAD) || die 6 "the worktree has no branch checked out"
[ "$branch" != main ] || die 6 "the worktree is on main; nothing to merge"
[ -z "$(git -C "$wt" status --porcelain --untracked-files=no)" ] || die 6 "the worktree has uncommitted changes; commit them first"
[ "$(git -C "$repo" symbolic-ref -q --short HEAD)" = main ] || die 6 "$repo is not on main"
git -C "$repo" merge --ff-only -q "$branch" || die 6 "main cannot fast-forward to $branch (main moved? no merge commit was made)"
echo "merge-local: main of $repo is at $(git -C "$repo" rev-parse --short HEAD) ($branch)"
