#!/usr/bin/env bash
# local-repo: make the git repository a request with no repository runs in. See ../SKILL.md.
# Needs only bash and git. Prints the repository path on stdout.
set -u

usage() {
  cat <<'USAGE'
Usage: local-repo.sh --task-id <id>

Makes $PADDOCK_LOCAL_DIR/<id> (default $HOME/paddock-local/<id>): git init on branch main plus one
empty commit, no remote. One repository per task. Prints its path; pass that to
org-delegate --project. Writes nothing else and never touches Claude Code's configuration.

Exit codes: 0 made, 2 bad argument or PADDOCK_LOCAL_DIR not absolute, 3 git not found,
6 the path exists already or git failed (what was made is left, named).
USAGE
}

die() { code=$1; shift; echo "local-repo: $*" >&2; exit "$code"; }

id=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --task-id) [ $# -ge 2 ] || die 2 "--task-id needs a value"; id=$2; shift 2 ;;
    *) echo "local-repo: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$id" in ''|-*|*[!a-z0-9_-]*) die 2 "--task-id is required: lowercase letters, digits, _ and -" ;; esac
[ "${#id}" -le 30 ] || die 2 "--task-id is longer than 30 characters"
dir=${PADDOCK_LOCAL_DIR:-$HOME/paddock-local}
case "$dir" in /*) ;; *) die 2 "PADDOCK_LOCAL_DIR must be an absolute path: $dir" ;; esac
command -v git >/dev/null 2>&1 || die 3 "git not found on PATH"

repo=$dir/$id
[ ! -e "$repo" ] && [ ! -L "$repo" ] || die 6 "$repo already exists; reuse goes through a projects.md row, or pick another task id"
mkdir -p "$dir" || die 6 "cannot create $dir"
git init -q -b main "$repo" >/dev/null 2>&1 || die 6 "git init failed at $repo"
# explicit author: a machine with no user.name / user.email still gets its first commit
git -C "$repo" -c user.name=paddock -c user.email=paddock@localhost.invalid commit -q --allow-empty -m "Start $id" \
  || die 6 "the first commit failed in $repo (the repository is left there)"
echo "$repo"
