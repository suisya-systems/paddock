#!/usr/bin/env bash
# org-clone: clone the repository a request names, so org-delegate --project <name> can run on it.
# Needs bash, coreutils, awk and git; uses the GitHub CLI for the clone when it is on PATH. See ../SKILL.md.
set -u

usage() {
  cat <<'USAGE'
Usage: org-clone.sh OWNER/NAME | https://github.com/OWNER/NAME[.git] | git@github.com:OWNER/NAME.git

Clones the repository with the login of the person running it (the secretary's own) into
$PADDOCK_PROJECTS_DIR/<owner>/<name> (default $HOME/paddock-projects/<owner>/<name>), into
.<name>.partial first and renamed only after the clone passed a git check. Then adds the row
| <name> | <path> | <base> | to projects.md (base from origin/HEAD, else main) and prints <name>.
A clone with the same origin that is already recorded is not cloned again: its name is printed.
GitHub only. A bare name is not guessed: ask for OWNER/NAME.

A fresh clone gets a marker (<clone>/.git/paddock-trust-pending): the first worker's folder-trust
dialog is held for the person (org-escalation prompt, ask, answer), never answered automatically.

Environment: PADDOCK_PROJECTS_DIR  the folder for clones; an absolute path
             PADDOCK_PROJECTS_FILE projects.md (see org-delegate)

Exit codes: 0 done (name on stdout), 2 bad argument, 3 git not found, 4 not found or no access,
5 network, 6 the target path exists and is not a clone of that origin, 7 NAME is already another
row in projects.md, 8 other failure (the clone failed for another reason, or the row was not
written). Nothing is recorded and no partial folder is left on exit 4, 5, 6, 7; no retry.
USAGE
}

die() { code=$1; shift; echo "org-clone: $*" >&2; exit "$code"; }

case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ $# -eq 1 ] || { usage >&2; exit 2; }

# slug <OWNER/NAME | URL>: OWNER/NAME on stdout, or nothing when the text is not a GitHub repository.
slug() {
  local s=$1
  case $s in https://github.com/*) s=${s#https://github.com/} ;; ssh://git@github.com/*) s=${s#ssh://git@github.com/} ;; git@github.com:*) s=${s#git@github.com:} ;; esac
  s=${s%/}; s=${s%.git}
  case $s in */*) ;; *) return 0 ;; esac
  case $s in */*/*|*/|/*|*[!A-Za-z0-9._/-]*) return 0 ;; esac
  case ${s%%/*} in ''|-*|*[!A-Za-z0-9-]*) return 0 ;; esac
  case ${s#*/} in ''|.|..|*.partial) return 0 ;; esac # NAME.partial would collide with another clone's staging folder
  printf '%s' "$s"
}

want=$(slug "$1")
if [ -z "$want" ]; then
  case $1 in
    */*) die 2 "not a GitHub repository: $1 (accepted: OWNER/NAME or a github.com URL)" ;;
    *) die 2 "'$1' is a bare name, which is not guessed: ask the person for OWNER/NAME (or a github.com URL)" ;;
  esac
fi
owner=${want%%/*}; name=${want#*/}
key=$(printf '%s' "$want" | tr 'A-Z' 'a-z')

dir=${PADDOCK_PROJECTS_DIR:-$HOME/paddock-projects}
case $dir in /*) ;; *) die 2 "PADDOCK_PROJECTS_DIR must be an absolute path: $dir" ;; esac
command -v git >/dev/null 2>&1 || die 3 "git not found on PATH"

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=../../org-delegate/scripts/project.sh
. "$root/skills/org-delegate/scripts/project.sh"
projf=${PADDOCK_PROJECTS_FILE:-}
if [ -z "$projf" ]; then
  cfg=${XDG_CONFIG_HOME:-$HOME/.config}; [ -n "${APPDATA:-}" ] && cfg=$APPDATA # as project.sh
  projf=$cfg/paddock/projects.md
fi

# origin_key <git folder>: the OWNER/NAME of its origin (lower case), or nothing.
origin_key() {
  local u; u=$(git -C "$1" remote get-url origin 2>/dev/null) || return 0
  slug "$u" | tr 'A-Z' 'a-z'
}

# 1. Already recorded (same origin): no second clone.
if [ -f "$projf" ]; then
  while IFS=$'\t' read -r n p; do
    [ -n "$n" ] && [ -n "$p" ] && [ "$(origin_key "$p")" = "$key" ] || continue
    echo "org-clone: $want is already recorded as '$n' ($p); not cloned again" >&2
    printf '%s\n' "$n"; exit 0
  done < <(awk -F'|' '
    function trim(s) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
    !hdr && /^[ \t]*\|/ { for (i = 2; i < NF; i++) c[tolower(trim($i))] = i; hdr = (c["name"] && c["path"]); next }
    hdr && /^[ \t]*\|/ { print trim($(c["name"])) "\t" trim($(c["path"])) }' "$projf")
fi

# 2. NAME is taken by another row: never overwrite; the secretary asks the person for a name.
project_lookup "$name"; rc=$?
[ $rc -eq 1 ] || [ $rc -eq 2 ] || die 7 "the name '$name' is already another project in $projf; ask the person for a different name to register $want under (config project add <name> <path>), do not overwrite"

tgt=$dir/$owner/$name
part=$dir/$owner/.$name.partial
fresh=
base=main
if [ -e "$tgt" ] || [ -L "$tgt" ]; then
  # 3. The target exists: reuse it only when it is a clone of the same origin; otherwise stop.
  [ "$(origin_key "$tgt")" = "$key" ] || die 6 "$tgt exists and is not a clone of $want; nothing was touched"
else
  # 4. Clone into the partial folder, with the person's own login. No retry, no other credential.
  mkdir -p "$dir/$owner" || die 8 "cannot create $dir/$owner"
  # One clone of a target at a time: the staging folder is shared by name. mkdir is the atomic lock.
  # ponytail: a run killed with SIGKILL leaves the lock; the message names it, remove it by hand.
  lock=$dir/$owner/.$name.lock
  mkdir "$lock" 2>/dev/null || die 8 "another org-clone of $want is running (or died: remove $lock if no run is left)"
  trap 'rmdir "$lock" 2>/dev/null' EXIT
  [ ! -e "$part" ] || rm -r "$part" # left by an earlier failed run of this script
  err=$(mktemp "${TMPDIR:-/tmp}/org-clone.XXXXXX") || die 8 "cannot create a temporary file"
  # GH_HOST=github.com: a secretary with GH_HOST set to another host must not resolve OWNER/NAME there.
  if command -v gh >/dev/null 2>&1; then GH_HOST=github.com GIT_TERMINAL_PROMPT=0 gh repo clone "$want" "$part" >/dev/null 2>"$err"
  else GIT_TERMINAL_PROMPT=0 git clone -q "https://github.com/$want.git" "$part" >/dev/null 2>"$err"; fi
  rc=$?
  if [ $rc -eq 0 ] && ! git -C "$part" rev-parse --git-dir >/dev/null 2>&1; then rc=1; echo "the clone is not a git repository" > "$err"; fi
  if [ $rc -ne 0 ]; then
    cat "$err" >&2; why=$(cat "$err"); rm -f "$err"; [ ! -e "$part" ] || rm -r "$part"
    if printf '%s' "$why" | grep -qiE 'not found|could not read username|authentication failed|permission denied|access denied|could not resolve to a repository|does not exist|returned error: 40[134]|http 40[134]|gh auth login'; then
      die 4 "$want was not cloned: not found, or the login has no access (nothing recorded; if the person must act, e.g. gh auth login, say so)"
    elif printf '%s' "$why" | grep -qiE 'could not resolve host|unable to access|timed out|connection|network|unreachable'; then
      die 5 "$want was not cloned: network failure (nothing recorded; no retry)"
    fi
    die 8 "$want was not cloned (nothing recorded; no retry)"
  fi
  rm -f "$err"
  b=$(git -C "$part" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) && [ -n "${b#origin/}" ] && base=${b#origin/}
  # The marker keeps org-escalation from answering the first worker's folder-trust dialog by itself.
  : > "$(git -C "$part" rev-parse --absolute-git-dir)/paddock-trust-pending" || { rm -r "$part"; die 8 "cannot write the trust marker in $part"; }
  mv "$part" "$tgt" || { rm -r "$part"; die 8 "cannot rename $part to $tgt"; }
  fresh=1
fi
if [ -z "$fresh" ]; then
  b=$(git -C "$tgt" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) && [ -n "${b#origin/}" ] && base=${b#origin/}
fi

# 5. Record it, only now. A failure here leaves the clone (and its marker): a second run registers it.
bash "$root/scripts/org" --as secretary config project add "$name" "$tgt" --base "$base" >&2 \
  || die 8 "$tgt is cloned but the projects.md row was not written; run this again after fixing the cause"
if [ -n "$fresh" ] || [ -e "$(git -C "$tgt" rev-parse --absolute-git-dir)/paddock-trust-pending" ]; then
  echo "org-clone: $want is cloned into $tgt. Its first worker stops at Claude Code's folder-trust dialog: it is not answered automatically. Ask the person on an approval card (trust) before the first worker; see org-escalation prompt." >&2
fi
printf '%s\n' "$name"
