#!/usr/bin/env bash
# org-delegate: one command from the secretary to a running worker (Issue #62).
# Needs only bash, coreutils, git and hc. See ../SKILL.md. Run it from the secretary.
set -u

usage() {
  cat <<'USAGE'
Usage: org-delegate.sh --project <git repo> --task-id <id> (--task <text> | --task-file <file|->)
                       [--title <text>] [--base <ref>] [--no-fetch] [--branch <name>] [--allow-write <path>]...

Creates a git worktree for the task under the workers folder, writes
.claude/settings.local.json into it (hc file write), starts the worker with
`hc run --bg` from the worker template with a task_id label, and records the start
with `scripts/org report start` (before the launch). Types nothing into any agent; writes no rules or
brief file into the worktree (rules: --append-system-prompt-file in the template).

  --project      the git repository the worker changes, or a project name (no /) whose path and base
                 are read from the row in projects.md (PADDOCK_PROJECTS_FILE, else the paddock config folder)
  --task-id      [a-z0-9_-], at most 30 characters; the worker is w-<id>, the label task_id=<id>
  --task         the task text (what to change, what not to touch, how to report)
  --task-file    the task text from a file, or - for stdin
  --title        a few words for people; with it, the work entry (task_id, title, since, worktree, task) is added to
                 org-state after the launch (without it, nothing is written there)
  --base         start point of the new branch (default: the project row's base, else main); when the project has an
                 origin, it is fetched first and origin/<base> is used if it exists
  --no-fetch     do not fetch origin; branch from the local base
  --branch       new branch name (default work/<id>)
  --allow-write  an absolute path (or ~/...) the worker may also write; repeatable.
                 Goes to sandbox.filesystem.allowWrite in the worktree's settings file.

Environment overrides:
  PADDOCK_WORKERS_DIR  the one workers folder, trusted once; an absolute path (default $HOME/paddock-workers)
  PADDOCK_CORE_SOCKET_DIR  the core's socket folder, denied to the worker's sandbox in its settings
                       file (default: the folder of $HC_TERMINAL_SOCKET; with neither, exit 2)

Exit codes: 0 worker running and recorded, 2 bad argument, 3 hc or git not found,
5 core unreachable or hc failed (the new worktree and branch are removed when no worker can
exist; if the terminal may exist they are kept and named), 6 project, base, worktree or
settings path problem (the worktree is removed), 7 a terminal w-<id> exists,
10 the worker started but its first message was not sent (left as it is),
12 the start record could not be written (nothing was started),
13 the worker runs but the org-state entry could not be written (--title; add it by hand).
USAGE
}

die() { code=$1; shift; echo "org-delegate: $*" >&2; exit "$code"; }
needs() { [ $# -ge 2 ] || die 2 "$1 needs a value"; }

project= id= task= taskfile= title= base= branch= allow=() fetch=1
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --project) needs "$@"; project=$2; shift 2 ;;
    --task-id) needs "$@"; id=$2; shift 2 ;;
    --task) needs "$@"; task=$2; shift 2 ;;
    --task-file) needs "$@"; taskfile=$2; shift 2 ;;
    --title) needs "$@"; title=$2; havetitle=1; shift 2 ;;
    --base) needs "$@"; base=$2; shift 2 ;;
    --branch) needs "$@"; branch=$2; shift 2 ;;
    --no-fetch) fetch=; shift ;;
    --allow-write) needs "$@"; allow+=("$2"); shift 2 ;;
    *) echo "org-delegate: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Arguments first: nothing is created or called until they are all valid.
[ -n "$project" ] || die 2 "--project is required"
case "$id" in ''|-*|*[!a-z0-9_-]*) die 2 "--task-id is required: lowercase letters, digits, _ and -" ;; esac
[ "${#id}" -le 30 ] || die 2 "--task-id is longer than 30 characters (the terminal name w-<id> allows 32)"
if [ -n "$task" ] && [ -n "$taskfile" ]; then die 2 "give --task or --task-file, not both"; fi
if [ -n "$taskfile" ]; then
  if [ "$taskfile" = - ]; then task=$(cat); else task=$(cat "$taskfile") || die 2 "cannot read $taskfile"; fi
fi
[ -n "$task" ] || die 2 "the task text is empty: give --task or --task-file"
[ -z "${havetitle:-}" ] || [ -n "${title//[[:space:]]/}" ] || die 2 "--title is empty"
[ -n "$branch" ] || branch=work/$id
# Issue #186: a --project without a "/" is a name in projects.md; its path and base come from the row.
case "$project" in
  */*|.|..) ;;
  *) . "$(dirname "${BASH_SOURCE[0]}")/project.sh"
     project_lookup "$project"; rc=$?
     [ "$rc" -ne 2 ] || die 2 "--project $project is a name but projects.md does not exist (set PADDOCK_PROJECTS_FILE, or pass a path)"
     [ "$rc" -eq 0 ] || die 2 "no project named $project with a path in projects.md (a path has a /)"
     project=$project_path
     [ -n "$base" ] || base=$project_base ;;
esac
[ -n "$base" ] || base=main
for p in ${allow[@]+"${allow[@]}"}; do
  case "$p" in /*|"~/"*) ;; *) die 2 "--allow-write needs an absolute path or ~/...: $p" ;; esac
  case "$p" in *[\"\\]*) die 2 "--allow-write path has a quote or backslash: $p" ;; esac
  case "$p" in *[[:cntrl:]]*) die 2 "--allow-write path has a control character (a newline too)" ;; esac
done

command -v hc >/dev/null 2>&1 || die 3 "hc not found on PATH (install herdr-core)"
command -v git >/dev/null 2>&1 || die 3 "git not found on PATH"
git check-ref-format --branch "$branch" >/dev/null 2>&1 || die 2 "invalid branch name: $branch"

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
name=w-$id
workers=${PADDOCK_WORKERS_DIR:-$HOME/paddock-workers}
wt=$workers/$id
case "$workers" in /*) ;; *) die 2 "PADDOCK_WORKERS_DIR must be an absolute path: $workers" ;; esac
# L-N2 (Issue #155): the worker's sandbox denies the core's socket folder. The folder is per user
# ($XDG_RUNTIME_DIR/herdr-core on Linux), so the shared settings file cannot name it: it goes in the
# per-task file below. Source: PADDOCK_CORE_SOCKET_DIR, else the folder of the socket the core gives
# this terminal. Without one, stop: a worker without this deny is what L-N2 forbids.
if [ -n "${PADDOCK_CORE_SOCKET_DIR:-}" ]; then sockdir=$PADDOCK_CORE_SOCKET_DIR
elif [ -n "${HC_TERMINAL_SOCKET:-}" ]; then sockdir=$(dirname "$HC_TERMINAL_SOCKET")
else die 2 "cannot tell the core's socket folder: run from a core terminal (HC_TERMINAL_SOCKET) or set PADDOCK_CORE_SOCKET_DIR"; fi
case "$sockdir" in /*) ;; *) die 2 "the core socket folder must be an absolute path: $sockdir" ;; esac
case "$sockdir" in *[\"\\]*|*[[:cntrl:]]*) die 2 "the core socket folder has a quote, backslash or control character" ;; esac

# 1. The core answers, and the worker's name is free. Nothing is created before this.
hc ls >/dev/null 2>&1 || die 5 "cannot reach the herdr core (hc ls failed)"
if hc get "$name" >/dev/null 2>&1; then die 7 "a terminal named $name already exists; pick another task id, or end that terminal first"; fi

# 2. The worktree, under the one trusted workers folder (Q13 b).
git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || die 6 "$project is not a git repository"
# Fetch origin first and branch from origin/<base> when it exists, so the base is current.
# No origin remote: nothing to fetch. A failed fetch stops here (nothing created); --no-fetch skips it.
if [ -n "$fetch" ] && git -C "$project" remote get-url origin >/dev/null 2>&1; then
  git -C "$project" fetch -q origin >/dev/null 2>&1 || die 6 "git fetch origin failed in $project; fix it or pass --no-fetch"
  ! git -C "$project" rev-parse --verify -q "refs/remotes/origin/$base^{commit}" >/dev/null || base=origin/$base
fi
git -C "$project" rev-parse --verify -q "$base^{commit}" >/dev/null || die 6 "base $base is not a commit in $project"
[ ! -e "$wt" ] && [ ! -L "$wt" ] || die 6 "$wt already exists; remove it (git worktree remove) or pick another task id"
mkdir -p "$workers" || die 6 "cannot create $workers"
git -C "$project" worktree add -q -b "$branch" "$wt" "$base" >/dev/null 2>&1 \
  || die 6 "git worktree add failed for branch $branch at $base (does the branch exist already?)"

# undo removes the worktree and branch, which are new and ours, and says so if it cannot. Used only
# where no worker can exist: before the launch, or after the core answered that the terminal is not there.
undo() {
  git -C "$project" worktree remove --force "$wt" >/dev/null 2>&1 \
    || echo "org-delegate: could not remove the worktree $wt; it is left behind (git worktree remove --force -f $wt)" >&2
  # -d only: a branch with work on it, or whose base is not merged into the project's HEAD, is kept and named.
  git -C "$project" branch -q -d "$branch" >/dev/null 2>&1 \
    || echo "org-delegate: the branch $branch in $project was not deleted (git refuses -d); it is left behind" >&2
}
fail_undone() { code=$1; shift; undo; die "$code" "$*"; }

# A symlinked workers folder is fine; the worktree itself must land directly inside it.
[ "$(cd "$wt" && pwd -P)" = "$(cd "$workers" && pwd -P)/$id" ] \
  || fail_undone 6 "$wt did not land directly under $workers"

# 3. The per-task settings file (Q10 a): only what changes per task or per user (the socket folder). The role's deny list, sandbox and
# hooks come from the template's --settings file. Never write through a symlink, never overwrite a file.
sf=$wt/.claude/settings.local.json
[ ! -L "$wt/.claude" ] || fail_undone 6 "$wt/.claude is a symlink (the base $base tracks it); nothing was written"
[ ! -e "$sf" ] && [ ! -L "$sf" ] || fail_undone 6 "$sf already exists (the base $base tracks it); it is never overwritten"
fs="\"denyRead\":[\"$sockdir\"],\"denyWrite\":[\"$sockdir\"]"
if [ "${#allow[@]}" -gt 0 ]; then
  list=
  for p in "${allow[@]}"; do list="$list${list:+,}\"$p\""; done
  fs="\"allowWrite\":[$list],$fs"
fi
json="{\"sandbox\":{\"filesystem\":{$fs}}}"
printf '%s\n' "$json" | hc file write "$sf" >/dev/null 2>&1 \
  || fail_undone 5 "hc file write failed for $sf; the worktree and branch were removed"
{ [ -f "$sf" ] && [ ! -L "$sf" ] && [ "$(cd "$wt/.claude" && pwd -P)" = "$(cd "$wt" && pwd -P)/.claude" ]; } \
  || fail_undone 6 "$sf is not a plain file inside the worktree after the write"

# 4. Record before the launch, so a later report from the worker (done, blocked) is the latest
# record in list_runs and is not overwritten by this one. A failure that leaves no worker is recorded as blocked.
org=$root/scripts/org
bash "$org" --as secretary report start --task "$id" --to secretary \
  "Delegating to $name in $wt on branch $branch (base $base)." >/dev/null 2>&1 \
  || fail_undone 12 "the start record could not be written (bash scripts/org --as secretary report start); nothing was started"
mark_blocked() { bash "$org" --as secretary report blocked --task "$id" --to secretary "$1" >/dev/null 2>&1; }

# 5. Launch with the task in the launch (decision 0002), labelled so a renewed secretary finds it.
brief="Your org id is $name. Your task id is $id.

$task"
if ! out=$(hc run --bg --outlive-parent --name "$name" --cwd "$wt" --label "task_id=$id" worker "$brief" 2>&1); then
  # The request may have been accepted before the answer failed. Remove things only if the core says the terminal is not there.
  st=$(hc get "$name" 2>&1); src=$?
  if [ "$src" -ne 0 ] && printf '%s' "$st" | grep -q 'not_found'; then
    mark_blocked "Delegation failed: hc run did not start $name. The worktree was removed."
    fail_undone 5 "hc run failed: ${out:0:300}. $name does not exist; the worktree and branch were removed."
  fi
  die 5 "hc run failed: ${out:0:300}. $name may exist or its state is unknown, so nothing was removed: terminal $name, worktree $wt, branch $branch (project $project). Check 'hc get $name'."
fi
if ! printf '%s' "$out" | tr -d '\n' | grep -Eq '"sent": *true'; then
  # Q13: a worker with no first message is at a dialog or never started. Never press keys here.
  mark_blocked "Delegation stalled: $name did not get its first message. Terminal, worktree $wt and branch $branch were left."
  echo "$out" >&2
  die 10 "$name started but first_message.sent is not true. Read it with 'hc read $name'. If it shows the folder-trust dialog, $workers is not the trusted workers folder yet (Q13: a person accepts it once). If the template refused, check the read-only token file. Left as they are, nothing typed: terminal $name, worktree $wt, branch $branch."
fi

echo "org-delegate: worker=$name worktree=$wt branch=$branch"

# 6. Issue #182: with --title, the work entry goes into org-state after the launch (a failed
# launch leaves no entry). Strings are JSON-escaped; the entry is added at the end of "work" by a
# scan that skips string contents, so braces and brackets in the task do not matter.
if [ -n "${havetitle:-}" ]; then
  esc() { printf '%s\n' "$1" | tr -d '\000-\010\013\014\016-\037' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$(printf '\t')/\\\\t/g" -e "s/$(printf '\r')/\\\\r/g" \
    | awk 'NR>1{printf "%s","\\n"} {printf "%s",$0}'; }
  since=${PADDOCK_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  entry="{\"task_id\":\"$id\",\"title\":\"$(esc "$title")\",\"since\":\"$since\",\"worktree\":\"$(esc "$wt")\",\"task\":\"$(esc "$task")\"}"
  ENTRY=$entry bash "$org" --as secretary doc update org-state -- awk '
    { s = s $0 "\n" }
    END {
      e = ENVIRON["ENTRY"]
      if (s ~ /^[ \t\n]*(null)?[ \t\n]*$/) { printf "{\"work\":[%s],\"approvals\":[]}", e; exit }
      if (!match(s, /"work": *\[/)) {
        p = index(s, "{"); r = substr(s, p + 1)
        printf "%s\"work\":[%s]%s%s", substr(s, 1, p), e, (r ~ /^[ \t\n]*\}/ ? "" : ","), r; exit }
      a = RSTART + RLENGTH; n = length(s); q = 0; d = 1
      for (i = a; i <= n; i++) { c = substr(s, i, 1)
        if (q) { if (c == "\\") i++; else if (c == "\"") q = 0; continue }
        if (c == "\"") q = 1; else if (c == "[") d++; else if (c == "]" && --d == 0) break }
      printf "%s%s%s%s", substr(s, 1, i - 1), (substr(s, a, i - a) ~ /[^ \t\n]/ ? "," : ""), e, substr(s, i) }' >/dev/null 2>&1 \
    || die 13 "$name runs, but the org-state entry could not be written (bash scripts/org --as secretary doc update org-state); add the work entry by hand"
fi
