#!/usr/bin/env bash
# org-resume: find the workers again, compare git state with the record, print a plan,
# and with --apply relaunch workers whose terminal is gone (Q4 decision B).
# Needs only bash, coreutils, git and hc. See ../SKILL.md. Run it from the person's login shell.
set -u

usage() {
  cat <<'USAGE'
Usage: org-resume.sh [--apply] [-h|--help]

Reads the record org-suspend wrote (without one, the work entries of org-state; it says so), finds each worker's terminal by its task_id label,
compares its worktree's git state with the record, and prints a plan. It launches
nothing unless --apply is given. With --apply, for a worker whose terminal is gone it
tries worker-continue (claude --continue in the worktree, original task in the launch)
and, if that fails, a fresh worker with the original task.

Environment overrides:
  PADDOCK_STATE_DIR                      folder of the record
  PADDOCK_WORKER_TEMPLATE                fresh worker template (default worker)
  PADDOCK_WORKER_CONTINUE_TEMPLATE       template whose command is claude --continue
                                         (default worker-continue)
  PADDOCK_READY_TRIES                    seconds to wait for a status (default 15)

Exit codes: 0 plan printed or workers resumed, 2 bad argument, 3 hc not found,
4 run inside an agent, 5 core unreachable or hc kill/rm failed, 9 no suspend record and no work in org-state,
13 a worker could not be relaunched.
USAGE
}

apply=
case "${1:-}" in
  "") ;;
  -h|--help) usage; exit 0 ;;
  --apply) apply=1 ;;
  *) echo "org-resume: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

die() { code=$1; shift; echo "org-resume: $*" >&2; exit "$code"; }
command -v hc >/dev/null 2>&1 || die 3 "hc not found on PATH (install herdr-core)"
. "$(dirname "${BASH_SOURCE[0]}")/../../org-suspend/scripts/lib.sh"
refuse_in_agent

dir=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}
rec=$dir/suspend.record
fresh_t=${PADDOCK_WORKER_TEMPLATE:-worker}
cont_t=${PADDOCK_WORKER_CONTINUE_TEMPLATE:-worker-continue}
tries=${PADDOCK_READY_TRIES:-15}
hc ls >/dev/null 2>&1 || die 5 "cannot reach the herdr core (hc ls failed)"
fromlist=
if [ ! -f "$rec" ]; then
  # No suspend record (an unplanned core stop): the work list in org-state has what a resume needs.
  doc=$(org_state_doc 2>&1) || die 5 "no suspend record at $rec and org-state is unreadable ($doc); nothing was launched"
  works=$(work_lines "$doc" 2>&1) || die 5 "$works; nothing was launched"
  [ -n "$works" ] || die 9 "no suspend record at $rec and no in-progress work in the work list (org-state); nothing was launched"
  rec=$(mktemp "${TMPDIR:-/tmp}/org-resume.XXXXXX") || die 5 "cannot create a temporary file"
  trap 'rm -f "$rec"' EXIT
  printf '%s\n' "$works" > "$rec"; fromlist=1
  echo "org-resume: no suspend record; resuming from the work list in org-state."
  echo "org-resume: could not restore: the git comparison with a record (none was written), the recorded terminal names (w-<task_id> is used) and the recorded terminal states (read from the core now)."
fi

# launch <template> <name> <cwd> <id> <task>: ok only when the task reached the worker and a status shows.
launch() {
  local out s i=0
  out=$(hc run --bg --outlive-parent --name "$2" --cwd "$3" --label "task_id=$4" "$1" "$5" 2>/dev/null) || return 1
  printf '%s' "$out" | tr -d '\n' | grep -Eq '"sent": *true' || return 1
  while [ "$i" -lt "$tries" ]; do
    s=$(term_status "$2" 2>/dev/null) && [ "$s" != none ] && return 0
    i=$((i + 1)); [ "$i" -lt "$tries" ] && sleep 1
  done
  return 1
}
# end <name> <id>: kill and remove a terminal, only if it carries this task_id.
end() {
  [ "$(term_label "$1")" = "$2" ] || return 0
  hc kill "$1" >/dev/null 2>&1 || true # ponytail: an already finished terminal may refuse the kill
  hc rm "$1" >/dev/null 2>&1 || die 5 "hc rm $1 failed"
}

cur=$(paddock_terminals) || die 5 "cannot reach the herdr core (hc ls failed)"
failed=0
while IFS=$'\t' read -r kind id wt head dirty task title; do
  [ "$kind" = work ] || continue
  # Rediscover by label: the terminal may have been recreated under another name.
  name=$(printf '%s\n' "$cur" | awk -F'\t' -v id="$id" '$2==id {print $1; exit}')
  if [ -n "$name" ]; then st=$(term_status "$name" 2>/dev/null) || st=gone
  else
    name=$(awk -F'\t' -v id="$id" '$1=="terminal" && $3==id {print $2; exit}' "$rec"); name=${name:-w-$id}; st=gone
  fi
  # Git: what changed in the worktree since the record.
  if [ "$wt" = - ] || ! git -C "$wt" rev-parse HEAD >/dev/null 2>&1; then
    echo "$id: git: worktree missing ($wt)"
  else
    now=$(git -C "$wt" rev-parse HEAD); dn=$(git -C "$wt" status --porcelain | wc -l | tr -d ' ')
    if [ -n "$fromlist" ]; then echo "$id: git: HEAD $now, $dn uncommitted file(s) (no record to compare with)"
    elif [ "$now" = "$head" ]; then echo "$id: git: HEAD unchanged, $dn uncommitted file(s) (was $dirty)"
    else echo "$id: git: HEAD changed since the record ($head -> $now), $dn uncommitted file(s) (was $dirty)"; fi
  fi
  if [ "$st" != gone ] && [ "$st" != none ]; then
    echo "$id: terminal $name is alive (status $st): keep"; continue
  fi
  echo "$id: terminal $name is gone: try $cont_t (claude --continue in $wt), else a fresh worker ($fresh_t) with the original task"
  [ -n "$apply" ] || continue
  if [ "$task" = - ]; then echo "$id: no original task in the record; not relaunched"; failed=1; continue; fi
  task=$(printf '%s' "$task" | sed 's/\\"/"/g; s/\\\\/\\/g') # ponytail: only \" and \\ unescaped
  [ "$st" = none ] && end "$name" "$id"
  if launch "$cont_t" "$name" "$wt" "$id" "$task"; then
    echo "$id: resumed with $cont_t as $name"
  else
    echo "$id: $cont_t did not come up; falling back to a fresh worker"
    end "$name" "$id"
    if launch "$fresh_t" "$name" "$wt" "$id" "$task"; then echo "$id: started a fresh worker as $name"
    else echo "$id: fresh worker did not come up; read it with 'hc read $name'" >&2; failed=1; fi
  fi
done < "$rec"

[ -n "$apply" ] || echo "org-resume: this was a plan; nothing was launched. Rerun with --apply to relaunch."
[ "$failed" -eq 0 ] || exit 13
