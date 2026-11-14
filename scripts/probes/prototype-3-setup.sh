#!/bin/sh
# Prepares a host for the Prototype 3 runbook (Issue #267): the one named command for the steps
# a person did by hand before `prepare` could pass.
#
#   sh scripts/probes/prototype-3-setup.sh --repo OWNER/NAME --project DIR [--paddock DIR]
#
# It does, and a rerun repeats nothing:
#   1. clones the throwaway repository OWNER/NAME to --project (gh repo clone), when DIR is missing;
#   2. makes a clean paddock clone at --paddock (default ~/paddock-run) from PADDOCK_REPO_URL
#      (default https://github.com/suisya-systems/paddock), or fast-forwards an existing clean one
#      on main to origin/main. Run `prepare` from that clone;
#   3. makes the workers folder (PADDOCK_WORKERS_DIR, default ~/paddock-workers).
# It never writes ~/.claude.json and never touches GitHub beyond the clone.
# What only a person can do it prints as TODO lines, each with the exact action:
#   - the folder trust of the throwaway clone (Q13, reopened: trust follows the git repository, not
#     the workers folder), unless the config under ~ (or CLAUDE_CONFIG_DIR) has it accepted.
# Never the paddock repository itself as --repo.
#   --check-trust DIR   only report whether DIR itself is recorded as trusted (used by prepare)
# Exit: 0 nothing is left for a person, 1 a TODO is printed, 2 bad argument, 3 a tool is missing,
# 6 refused or failed.
set -u

die() { c=$1; shift; echo "prototype-3-setup: $*" >&2; exit "$c"; }
usage() { sed -n '2,25p' "$0"; }

# fr_trusted comes from first-run-checks.sh (Issue #328): the clone it is given, else the one this script sits in (a fetched copy has none of its own).
frlib() { for b in "$1" "$(dirname "$0")/../.."; do [ -f "$b/skills/org-start/scripts/first-run-checks.sh" ] && { . "$b/skills/org-start/scripts/first-run-checks.sh"; return 0; }; done; die 6 "no first-run-checks.sh under $1"; }

repo= project= paddock=$HOME/paddock-run
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --check-trust) [ $# -ge 2 ] || die 2 "$1 needs a value"; frlib "$(dirname "$0")/../.."; fr_trusted "$2"; exit $? ;;
    --repo|--project|--paddock) [ $# -ge 2 ] || die 2 "$1 needs a value"
      case "$1" in --repo) repo=$2 ;; --project) project=$2 ;; *) paddock=$2 ;; esac; shift 2 ;;
    *) die 2 "unknown option: $1" ;;
  esac
done

[ -n "$repo" ] && [ -n "$project" ] || die 2 "needs --repo OWNER/NAME and --project DIR"
repo=$(printf '%s' "$repo" | tr 'A-Z' 'a-z')
case "$repo" in */*/*|*/|/*) die 2 "--repo must be OWNER/NAME" ;; */*) ;; *) die 2 "--repo must be OWNER/NAME" ;; esac
[ "$repo" != suisya-systems/paddock ] || die 6 "never this repository: name a throwaway repository"
for c in git gh; do command -v "$c" >/dev/null 2>&1 || die 3 "$c not found on PATH"; done
todo=0

# 1. The throwaway repository.
if [ -e "$project" ]; then
  git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || die 6 "$project exists and is not a git repository"
else
  gh repo clone "$repo" "$project" >/dev/null || die 6 "gh repo clone $repo failed (is gh logged in: gh auth login?)"
fi
project=$(cd "$project" && pwd)
echo "ok   throwaway repository: $project"

# 2. The clean paddock clone.
purl=${PADDOCK_REPO_URL:-https://github.com/suisya-systems/paddock}
if [ -e "$paddock" ]; then
  [ "$(git -C "$paddock" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$paddock" && pwd -P)" ] \
    && [ "$(git -C "$paddock" remote get-url origin 2>/dev/null)" = "$purl" ] \
    || die 6 "$paddock is not the root of a clone of $purl (set PADDOCK_REPO_URL when it was cloned from another URL); use another --paddock"
  [ "$(git -C "$paddock" symbolic-ref --short HEAD 2>/dev/null)" = main ] || die 6 "$paddock is not a paddock clone on main"
  [ -z "$(git -C "$paddock" status --porcelain 2>/dev/null)" ] || die 6 "$paddock is not clean (git status --porcelain shows changes); use another --paddock or clean it"
  git -C "$paddock" fetch -q origin && git -C "$paddock" merge -q --ff-only origin/main || die 6 "$paddock cannot fast-forward to origin/main"
  [ "$(git -C "$paddock" rev-parse HEAD)" = "$(git -C "$paddock" rev-parse origin/main)" ] \
    || die 6 "$paddock has commits that origin/main lacks; use another --paddock (a fresh clone)"
else
  git clone -q "$purl" "$paddock" || die 6 "cannot clone paddock to $paddock"
fi
echo "ok   paddock clone: $paddock at $(git -C "$paddock" rev-parse --short HEAD)"

frlib "$paddock"

# 3. The workers folder.
workers=${PADDOCK_WORKERS_DIR:-$HOME/paddock-workers}
mkdir -p "$workers" || die 6 "cannot make $workers"
echo "ok   workers folder: $workers"

# 4. Folder trust of the throwaway clone (Q13): worktrees take the trust of their repository, and
# only the person can answer the dialog.
if fr_trusted "$project"; then
  echo "ok   folder trust: $project is recorded as trusted"
else
  todo=1
  echo "TODO folder-trust: $project is not recorded as trusted; a worker cut from it would stop at the dialog. Run once:"
  echo "  cd '$project' && claude   # answer 'Yes, I trust this folder', then leave with /exit"
fi

echo "next: cd '$paddock' && sh scripts/probes/prototype-3.sh prepare --project '$project' --repo $repo"
exit $todo
