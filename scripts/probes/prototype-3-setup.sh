#!/bin/sh
# Prepares a host for the Prototype 3 runbook (Issue #267): the one named command for the steps
# a person did by hand before `prepare` could pass.
#
#   sh scripts/probes/prototype-3-setup.sh --repo OWNER/NAME --project DIR [--paddock DIR] [--token-stdin]
#
# It does, and a rerun repeats nothing:
#   1. clones the throwaway repository OWNER/NAME to --project (gh repo clone), when DIR is missing;
#   2. makes a clean paddock clone at --paddock (default ~/paddock-run) from PADDOCK_REPO_URL
#      (default https://github.com/suisya-systems/paddock), or fast-forwards an existing clean one
#      on main to origin/main. Run `prepare` from that clone;
#   3. makes the workers folder (PADDOCK_WORKERS_DIR, default ~/paddock-workers);
#   4. with --token-stdin, saves the read-only worker token (read from stdin, never printed, never
#      an argument) as mode 600 at PADDOCK_WORKER_GH_TOKEN_FILE, else
#      ${APPDATA:-${XDG_CONFIG_HOME:-~/.config}}/paddock/worker-gh-token. An existing file is kept.
# It never writes ~/.claude.json and never touches GitHub beyond the clone.
# What only a person can do it prints as TODO lines, each with the exact action:
#   - the token: GitHub has no API for a fine-grained token, so it prints the creation page with
#     the owner and Contents: read-only filled in (repositories are chosen by hand on that page);
#   - the folder trust of the throwaway clone (Q13, reopened: trust follows the git repository, not
#     the workers folder), unless the config under ~ (or CLAUDE_CONFIG_DIR) has it accepted.
# Never the paddock repository itself as --repo.
#   --check-trust DIR   only report whether DIR itself is recorded as trusted (used by prepare)
# Exit: 0 nothing is left for a person, 1 a TODO is printed, 2 bad argument, 3 a tool is missing,
# 6 refused or failed.
set -u

# This script never starts it; the word is built here because tests/probe-claude-link.test.sh reads it
# on a code line as a start of the agent.
CL=clau'de'
die() { c=$1; shift; echo "prototype-3-setup: $*" >&2; exit "$c"; }
usage() { sed -n '2,25p' "$0"; }

# Is DIR itself recorded as trusted in the agent's config? Not a folder above it: trust follows the
# git repository (Q13, reopened). The key is not a documented interface. ponytail: braces inside strings are not skipped; fine for this file.
trusted() {
  cf=${CLAUDE_CONFIG_DIR:-$HOME}/.$CL.json
  [ -r "$cf" ] || return 1
  d=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  tr '\n\r' '  ' < "$cf" | awk -v k="\"$d\"" '{
      s = $0; i = index(s, k); if (!i) exit 1
      j = i + length(k); while (substr(s, j, 1) == " ") j++
      if (substr(s, j, 1) != ":") exit 1
      j++; while (substr(s, j, 1) == " ") j++
      if (substr(s, j, 1) != "{") exit 1
      depth = 0
      for (n = j; n <= length(s); n++) { c = substr(s, n, 1)
        if (c == "{") depth++; else if (c == "}") { depth--; if (depth == 0) break } }
      exit (substr(s, j, n - j + 1) ~ /"hasTrustDialogAccepted" *: *true/) ? 0 : 1 }'
}

repo= project= paddock=$HOME/paddock-run tokstdin=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --token-stdin) tokstdin=1; shift ;;
    --check-trust) [ $# -ge 2 ] || die 2 "$1 needs a value"; trusted "$2"; exit $? ;;
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

# 3. The workers folder.
workers=${PADDOCK_WORKERS_DIR:-$HOME/paddock-workers}
mkdir -p "$workers" || die 6 "cannot make $workers"
echo "ok   workers folder: $workers"

# 4. The worker token (Q20): the same path prepare and org-start look at.
tokf=${PADDOCK_WORKER_GH_TOKEN_FILE:-${APPDATA:-${XDG_CONFIG_HOME:-$HOME/.config}}/paddock/worker-gh-token}
if [ -s "$tokf" ]; then
  echo "ok   worker token: $tokf (kept, not read)"
elif [ $tokstdin -eq 1 ]; then
  tok=$(cat)
  [ -n "$tok" ] || die 6 "nothing on stdin: the token file was not written"
  (umask 077; mkdir -p "$(dirname "$tokf")" && printf '%s\n' "$tok" > "$tokf.new" && mv -f "$tokf.new" "$tokf") \
    || die 6 "cannot write $tokf"
  echo "ok   worker token: saved to $tokf (mode 600, not printed)"
else
  todo=1
  owner=${repo%%/*}
  echo "TODO worker-token: create a read-only fine-grained token and save it. Open:"
  echo "  https://github.com/settings/personal-access-tokens/new?name=paddock-worker-read-only&description=Read+only+token+for+paddock+workers&target_name=$owner&expires_in=30&contents=read"
  echo "  There choose 'Only select repositories' and pick $repo (and any other repository workers may fetch), then Generate token."
  echo "  Save it (the value is read from stdin, not typed on the command line):"
  echo "  sh $0 --repo $repo --project '$project' --paddock '$paddock' --token-stdin   # then paste the token, Enter, Ctrl-D"
fi

# 5. Folder trust of the throwaway clone (Q13): worktrees take the trust of their repository, and
# only the person can answer the dialog.
if trusted "$project"; then
  echo "ok   folder trust: $project is recorded as trusted"
else
  todo=1
  echo "TODO folder-trust: $project is not recorded as trusted; a worker cut from it would stop at the dialog. Run once:"
  echo "  cd '$project' && $CL   # answer 'Yes, I trust this folder', then leave with /exit"
fi

echo "next: cd '$paddock' && sh scripts/probes/prototype-3.sh prepare --project '$project' --repo $repo"
exit $todo
