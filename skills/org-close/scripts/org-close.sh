#!/usr/bin/env bash
# org-close: end a finished or failed worker in one call. Needs only bash,
# coreutils, awk, git and hc. See ../SKILL.md. Run it from the secretary.
set -u
export LC_ALL=C

usage() {
  cat <<'USAGE'
Usage: org-close.sh --task <task_id> [--drop]

Without --drop (the worker finished): needs a done record for the task, written by w-<task_id>
and addressed to secretary, and a terminal w-<task_id> that carries the label task_id=<task_id>.
Then hc kill, hc rm, and the work entry is removed from org-state. The worktree and branch stay
(org-pull-request still needs them).

--drop (the work is abandoned or the launch failed): needs no report. Also removes the worktree
(uncommitted work in it is lost) and the branch, the branch only when it has no commit beyond its
base (git branch -d; otherwise it is kept and named).

Environment: PADDOCK_WORKERS_DIR (default $HOME/paddock-workers) is where org-delegate put the
worktree; PADDOCK_STATE_DIR is the mailbox folder of scripts/org.

Exit codes: 0 closed, 2 bad argument, 3 hc not found, 5 core or org-state error (or hc kill/rm
failed), 6 no done record for the task addressed to secretary, 7 the terminal does not carry the
task's label, 8 the worktree could not be removed.
USAGE
}

die() { code=$1; shift; echo "org-close: $*" >&2; exit "$code"; }

task= drop=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --task) [ $# -ge 2 ] || die 2 "--task needs a value"; task=$2; shift 2 ;;
    --drop) drop=1; shift ;;
    *) echo "org-close: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$task" in ''|-*|*[!a-z0-9_-]*) die 2 "--task <task_id> is required: lowercase letters, digits, _ and -" ;; esac
command -v hc >/dev/null 2>&1 || die 3 "hc not found on PATH (install herdr-core)"

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/../../org-suspend/scripts/lib.sh"   # term_label
org=$here/../../../scripts/org
state=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}
name=w-$task
wt=${PADDOCK_WORKERS_DIR:-$HOME/paddock-workers}/$task

# 1. Checks first; nothing is ended until they pass.
if [ -z "$drop" ]; then
  # The done must be at or after the latest start of this task id, so a done from an earlier,
  # dropped delegation of the same id does not count.
  # ponytail: reads the mailbox file layout of scripts/org directly; ask scripts/org if that changes.
  # ts has one-second resolution: a done in the same second as the start counts.
  ts_of() { sed -n 's/^{"seq":[0-9]*,"ts":"\([^"]*\)".*/\1/p' | sort | tail -1; }
  started=$(cat "$state"/events/*/secretary.jsonl 2>/dev/null \
    | grep -F "\"kind\":\"run_started\"" | grep -F "\"task_id\":\"$task\"," | ts_of)
  done_at=$(cat "$state"/events/*/"$name".jsonl 2>/dev/null \
    | grep -F "\"from\":\"$name\",\"kind\":\"run_completed\",\"to\":\"secretary\",\"task_id\":\"$task\"," | ts_of)
  { [ -n "$done_at" ] && [ ! "$done_at" \< "$started" ]; } \
    || die 6 "no done record for $task from $name addressed to secretary since its start; ask the worker to report, or use --drop"
fi
hc ls >/dev/null 2>&1 || die 5 "cannot reach the herdr core (hc ls failed)"
# Only the core's own not_found means the terminal is gone; any other failure stops here.
have=1; got=$(hc get "$name" 2>&1) || { have=; printf '%s' "$got" | grep -q 'not_found' || die 5 "hc get $name failed: ${got:0:200}"; }
if [ -n "$have" ]; then
  [ "$(term_label "$name")" = "$task" ] || die 7 "terminal $name does not carry the label task_id=$task; it is not ended"
fi

# 2. End the terminal. A terminal already gone (an earlier run stopped after it) is not an error.
if [ -n "$have" ]; then
  hc kill "$name" >/dev/null 2>&1 || die 5 "hc kill $name failed; nothing else was done"
  hc rm "$name" >/dev/null 2>&1 || die 5 "hc rm $name failed (killed); run it again"
fi
# The killed worker may have left Claude Code's 0-byte read-only config.lock in the clone's shared .git.
sweep_config_lock "$wt"

# 3. --drop: the worktree, then the branch if it is unused.
if [ -n "$drop" ] && [ -e "$wt" ]; then
  common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die 8 "$wt is not a git worktree; left as it is"
  proj=${common%/.git}
  [ "$proj" != "$common" ] && [ "$(git -C "$wt" rev-parse --show-toplevel)" = "$(cd "$wt" && pwd -P)" ] \
    && [ -f "$wt/.git" ] || die 8 "$wt is not a linked worktree of a project; left as it is"
  branch=$(git -C "$wt" symbolic-ref --short -q HEAD)
  git -C "$proj" worktree remove --force "$wt" >/dev/null 2>&1 || die 8 "could not remove the worktree $wt"
  # ponytail: -d refuses unless the branch is merged into the project's HEAD, so a base other than
  # that HEAD keeps an unused branch (named below); compare with the base from the start record if it matters.
  if [ -n "$branch" ] && ! git -C "$proj" branch -q -d "$branch" >/dev/null 2>&1; then
    echo "org-close: the branch $branch in $proj was kept (it has a commit beyond its base)" >&2
  fi
fi

# 4. Remove the work entry (approvals with the same task_id are not touched). Entries are flat objects.
TASK=$task bash "$org" --as secretary doc update org-state --record work_removed --task "$task" --text "" -- awk '
  { s = s $0 "\n" }
  END {
    t = ENVIRON["TASK"]
    if (!match(s, /"work": *\[/)) { printf "%s", s; exit }
    # The entries are cut out with a scan that skips string contents, so a "]" or
    # braces inside a task or title do not end an entry or the array.
    a = RSTART + RLENGTH; n = length(s); q = 0; ob = 0; out = ""
    for (i = a; i <= n; i++) { c = substr(s, i, 1)
      if (q) { if (c == "\\") i++; else if (c == "\"") q = 0; continue }
      if (c == "\"") q = 1
      else if (c == "{") { if (ob++ == 0) st = i }
      else if (c == "}") { if (--ob == 0) { o = substr(s, st, i - st + 1)
          if (o !~ ("\"task_id\": *\"" t "\"")) out = out (out == "" ? "" : ",") o } }
      else if (c == "]" && ob == 0) break
    }
    printf "%s%s%s", substr(s, 1, a - 1), out, substr(s, i)
  }' >/dev/null 2>&1 || die 5 "org-state was not written; the terminal is already ended, run again"

echo "org-close: closed $name${drop:+ (dropped: worktree and unused branch removed)}"

# Decision 0009: tell the secretary when raw notes pile up (a count, no resident process).
( cd "$here/../../org-curate/scripts" && bash org-curate.sh count )
