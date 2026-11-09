#!/usr/bin/env bash
# org-pull-request: push a worker's branch, open the PR, watch CI as a child terminal,
# record ci_completed, then stop (human) or merge (acceptance). Needs bash, git, gh and hc.
# See ../SKILL.md. Run it from the secretary.
set -u

usage() {
  cat <<'USAGE'
Usage: org-pull-request.sh --title TITLE (--body-file FILE | --body TEXT) [options]
       org-pull-request.sh --pr N [options]

Pushes the worktree's branch to origin, opens a PR, watches its CI run as a background
child (hc run --bg ... gh run watch --exit-status, then hc wait), appends a ci_completed
line to the secretary's events file, then acts by approval mode.

Options:
  --worktree DIR     the worker's worktree (default: current directory)
  --repo OWNER/NAME  the repository to open the PR in (default: parsed from the origin URL;
                     never guessed from anything else)
  --base BRANCH      base branch (default: main)
  --task-id ID       recorded in the ci_completed line
  --mode MODE        human | acceptance (default: merge_approval_mode in org-state, else human)
  --pr N             use an open PR instead of creating one (still pushes)
  -h, --help         this text

Environment overrides:
  PADDOCK_EVENTS_DIR  events folder (default ${XDG_STATE_HOME:-~/.local/state}/paddock/events)
  PADDOCK_RUN_TRIES   tries to find the CI run (default 10)
  PADDOCK_RUN_SLEEP   seconds between tries (default 6)

Exit codes: 0 done (human: CI green, the person decides; acceptance: merged), 2 bad argument,
3 hc, gh or git not found, 5 push failed, 6 PR could not be created, 7 no CI run found,
8 watch result unreadable, 9 CI failed, 10 merge refused (head moved or required checks
not green), 11 merge failed, 12 events line could not be written.
USAGE
}

die() { code=$1; shift; echo "org-pull-request: $*" >&2; exit "$code"; }

wt=.; repo=; base=main; task=; mode=; pr=; title=; body=; bodyfile=
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --worktree|--repo|--base|--task-id|--mode|--pr|--title|--body|--body-file)
      [ $# -ge 2 ] || die 2 "$1 needs a value"
      case $1 in
        --worktree) wt=$2 ;; --repo) repo=$2 ;; --base) base=$2 ;; --task-id) task=$2 ;;
        --mode) mode=$2 ;; --pr) pr=$2 ;; --title) title=$2 ;; --body) body=$2 ;; --body-file) bodyfile=$2 ;;
      esac
      shift 2 ;;
    *) echo "org-pull-request: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case $mode in ""|human|acceptance) ;; *) die 2 "--mode must be human or acceptance" ;; esac
case $pr in ""|*[!0-9]*) [ -z "$pr" ] || die 2 "--pr must be a number" ;; esac
[ -n "$pr" ] || [ -n "$title" ] || die 2 "--title is required unless --pr is given"
[ -n "$pr" ] || [ -n "$body$bodyfile" ] || die 2 "--body-file or --body is required unless --pr is given"
[ -z "$bodyfile" ] || [ -f "$bodyfile" ] || die 2 "body file not found: $bodyfile"
case $task in *[!A-Za-z0-9._-]*) die 2 "--task-id may hold only letters, digits, . _ -" ;; esac

if [ -z "$repo" ]; then # owner/name from a GitHub origin URL only
  url=$(git -C "$wt" remote get-url origin 2>/dev/null)
  repo=$(printf '%s' "$url" | sed -n 's#^\(https://github\.com/\|git@github\.com:\|ssh://git@github\.com/\)\([^/]*/[^/]*\)$#\2#p' | sed 's#\.git$##')
  [ -n "$repo" ] || die 2 "cannot read OWNER/NAME from the origin URL; pass --repo"
fi

for c in git gh hc; do command -v "$c" >/dev/null 2>&1 || die 3 "$c not found on PATH"; done
branch=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null) || die 2 "no branch checked out in $wt"
sha=$(git -C "$wt" rev-parse HEAD) || die 2 "$wt is not a git worktree"

# 1. push (from the worktree)
git -C "$wt" push origin "$branch" >&2 || die 5 "git push origin $branch failed"

# 2. PR
if [ -z "$pr" ]; then
  args=(--repo "$repo" --head "$branch" --base "$base" --title "$title")
  if [ -n "$bodyfile" ]; then args+=(--body-file "$bodyfile"); else args+=(--body "$body"); fi
  url=$(gh pr create "${args[@]}") || die 6 "gh pr create failed"
  url=$(printf '%s\n' "$url" | tail -1)
  pr=${url##*/}
  case $pr in ""|*[!0-9]*) die 6 "no PR number in the answer of gh pr create: $url" ;; esac
else
  url="https://github.com/$repo/pull/$pr"
fi
echo "PR_URL=$url"

# 3. CI run id from the head sha, retrying while no run exists yet
tries=${PADDOCK_RUN_TRIES:-10}; run=
while [ "$tries" -gt 0 ]; do
  run=$(gh run list --repo "$repo" --commit "$sha" --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)
  case $run in ""|*[!0-9]*) run= ;; *) break ;; esac
  tries=$((tries - 1)); [ "$tries" -le 0 ] || sleep "${PADDOCK_RUN_SLEEP:-6}"
done
[ -n "$run" ] || die 7 "no CI run for $sha after ${PADDOCK_RUN_TRIES:-10} tries"

# 3b. watch it as a child, then wait: measured in MON-12 (Issue #55).
name=ci-$pr
hc run --bg --rm --no-notify --name "$name" -- gh run watch "$run" --repo "$repo" --exit-status >/dev/null \
  || die 8 "hc run could not start the watcher $name"
res=$(hc wait "$name" 2>&1 | tr -d '\n')
code=$(printf '%s' "$res" | sed -n 's/.*"exit_code": *\([0-9][0-9]*\).*/\1/p')
[ -n "$code" ] || die 8 "no integer exit_code in the hc wait answer: $res"
[ "$code" -eq 0 ] && concl=success || concl=failure

# 4. ci_completed (decision 0004: events/<YYYY-MM>/<writer>.jsonl, own seq, UTC ts)
evdir=${PADDOCK_EVENTS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock/events}/$(date -u +%Y-%m)
evfile=$evdir/secretary.jsonl
mkdir -p "$evdir" || die 12 "cannot create $evdir"
seq=$(( $( [ -f "$evfile" ] && wc -l < "$evfile" || echo 0 ) + 1 ))
tj=; [ -z "$task" ] || tj=",\"task_id\":\"$task\""
printf '{"seq":%d,"ts":"%s","kind":"ci_completed","writer":"secretary"%s,"pr":%d,"sha":"%s","run_id":%d,"exit_code":%d,"conclusion":"%s"}\n' \
  "$seq" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tj" "$pr" "$sha" "$run" "$code" "$concl" >> "$evfile" \
  || die 12 "cannot write $evfile"

[ "$code" -eq 0 ] || die 9 "CI failed on $sha (exit_code $code, run $run); PR $url"

# 5. approval mode: argument, else org-state (hc has no document verb; hold the input 1 s), else human
if [ -z "$mode" ]; then
  req='{"jsonrpc":"2.0","id":1,"method":"doc.get","params":{"name":"org-state"}}'
  doc=$({ printf '%s\n' "$req"; sleep 1; } | hc connect 2>/dev/null | tr -d '\n')
  m=$(printf '%s' "$doc" | sed -n 's/.*"merge_approval_mode": *"\([a-z]*\)".*/\1/p')
  case $m in acceptance) mode=acceptance ;; *) mode=human ;; esac
fi

if [ "$mode" = human ]; then
  echo "CI green on $sha (run $run). Approval mode human: the person decides. Not merged. PR: $url"
  exit 0
fi

# acceptance: no local gate (Q11 d). The required checks are the repository's CI; here we only
# check that they are green on the exact head that was watched, then pin the merge to it.
now=$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq .headRefOid 2>/dev/null)
[ "$now" = "$sha" ] || die 10 "head moved: watched $sha, PR is at ${now:-unknown}; not merged"
# --watch: other workflows of the same head may still run; wait for them, do not refuse early.
gh pr checks "$pr" --repo "$repo" --required --watch >/dev/null 2>&1 \
  || die 10 "required checks are not all green on $sha; not merged"
gh pr merge "$pr" --repo "$repo" --squash --match-head-commit "$sha" >&2 || die 11 "gh pr merge failed"
echo "Merged PR $url at $sha (squash, approval mode acceptance)."
