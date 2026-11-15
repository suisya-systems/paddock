#!/usr/bin/env bash
# org-pull-request: push a worker's branch, open the PR and record ci_requested; org-watch watches
# CI and records ci_completed (decision 0013). With --pr, act on that record for the current head:
# stop (human) or merge (acceptance). Needs bash, git and gh.
# See ../SKILL.md. Run it from the secretary.
set -u

usage() {
  cat <<'USAGE'
Usage: org-pull-request.sh --title TITLE (--body-file FILE | --body TEXT) [options]
       org-pull-request.sh --pr N [options]

Pushes the worktree's branch to origin, opens a PR and appends ci_requested for its head:
org-watch watches CI, records ci_completed (or ci_watch_failed) and mails the secretary
(decision 0013). With --pr N it reads the watcher's record for the current head and acts by
approval mode; a head with no request yet, or whose watch failed, is requested (once).

Options:
  --worktree DIR     the worker's worktree (default: current directory)
  --repo OWNER/NAME  the repository to open the PR in (default: parsed from the origin URL;
                     never guessed from anything else)
  --project NAME     a project name in projects.md; its base is the default base
  --base BRANCH      base branch (default: the project row's base, else main)
  --task-id ID       recorded in the ci_requested line
  --mode MODE        human | acceptance (default: merge_approval_mode in org-config.md, else human)
  --pr N             use an open PR instead of creating one (still pushes), and act on
                     the watcher's CI record for its head
  -h, --help         this text

Environment overrides:
  PADDOCK_STATE_DIR   scripts/org's state folder, whose events/ holds the records (default
                      ${XDG_STATE_HOME:-~/.local/state}/paddock)
  PADDOCK_NOW         fixes the clock (UTC ISO 8601), for the months read

Exit codes: 0 done (no --pr: PR opened, CI requested; --pr, human: CI green, the person
decides; --pr, acceptance: merged), 2 bad argument, 3 gh or git not found, 4 no CI result
recorded for the head yet (requested now or still watched; the watcher mails it), 5 push
failed, 6 PR could not be created, 9 CI failed, 10 merge refused (head moved or required
checks not green), 11 merge failed, 12 the ci_requested line could not be written.
USAGE
}

die() { code=$1; shift; echo "org-pull-request: $*" >&2; exit "$code"; }

wt=.; repo=; base=; project=; task=; mode=; pr=; title=; body=; bodyfile=
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --worktree|--repo|--project|--base|--task-id|--mode|--pr|--title|--body|--body-file)
      [ $# -ge 2 ] || die 2 "$1 needs a value"
      case $1 in
        --worktree) wt=$2 ;; --repo) repo=$2 ;; --project) project=$2 ;; --base) base=$2 ;; --task-id) task=$2 ;;
        --mode) mode=$2 ;; --pr) pr=$2 ;; --title) title=$2 ;; --body) body=$2 ;; --body-file) bodyfile=$2 ;;
      esac
      shift 2 ;;
    *) echo "org-pull-request: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -n "$project" ]; then # only the row's base is used here (the worktree is the worker's)
  . "$(dirname "${BASH_SOURCE[0]}")/../../org-delegate/scripts/project.sh"
  project_lookup "$project"; rc=$?
  [ "$rc" -ne 2 ] || die 2 "--project $project: projects.md does not exist (set PADDOCK_PROJECTS_FILE)"
  [ "$rc" -eq 0 ] || die 2 "no project named $project with a path in projects.md"
  [ -n "$base" ] || base=$project_base
fi
[ -n "$base" ] || base=main
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

for c in git gh; do command -v "$c" >/dev/null 2>&1 || die 3 "$c not found on PATH"; done
branch=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null) || die 2 "no branch checked out in $wt"
sha=$(git -C "$wt" rev-parse HEAD) || die 2 "$wt is not a git worktree"

# 1. push (from the worktree)
git -C "$wt" push origin "$branch" >&2 || die 5 "git push origin $branch failed"

# 1b. the task's last diff-review record in the codex-gate history. Unless it is
# codex_round_passed (or there is none), the body itself says the review did not run, so a body
# file written without that still carries it. Needs --task-id; a design review is not this review.
if [ -z "$pr" ] && [ -n "$task" ]; then
  gl=$(cat "${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}"/events/*/codex-gate.jsonl 2>/dev/null \
    | grep "\"task_id\":\"$task\",\"text\":\"diff round " | grep -E '"kind":"codex_round_(passed|failed)"' | tail -1)
  case $gl in
    *'"kind":"codex_round_passed"'*) ;;
    *)
      note="Second-model review did not run: no passed diff review is recorded for task $task."
      [ -z "$gl" ] || note="Second-model review did not run. Gate record: $(printf '%s' "$gl" | sed 's/.*"kind":"\([^"]*\)".*"text":"\(.*\)"}$/\1: \2/')"
      bf=$(mktemp) || die 6 "cannot make a temporary body file"
      { if [ -n "$bodyfile" ]; then cat "$bodyfile"; else printf '%s\n' "$body"; fi; printf '\n%s\n' "$note"; } > "$bf"
      bodyfile=$bf; body= ;;
  esac
fi

# 2. PR
prgiven=$pr
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
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
org=$root/scripts/org
targs=(); [ -z "$task" ] || targs=(--task "$task")

# 3. the head's CI state from the records (this calendar month and the last, as org-watch reads them):
# the secretary's latest ci_requested for repo, pr and sha, and the watcher's latest ci_completed or
# ci_watch_failed at or after it. The skill's own old ci_completed lines (from secretary) do not count.
ev=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}/events
cur=$(printf '%s' "${PADDOCK_NOW:-}" | cut -c1-7); [ -n "$cur" ] || cur=$(date -u +%Y-%m)
y=${cur%-*}; m=$((10#${cur#*-} - 1)); [ "$m" -gt 0 ] || { m=12; y=$((10#$y - 1)); }
ci=$(for d in "$ev/$(printf '%04d-%02d' "$((10#$y))" "$m")" "$ev/$cur"; do
    [ ! -f "$d/secretary.jsonl" ] || grep -h '"kind":"ci_requested"' "$d/secretary.jsonl" | sed 's/^/R /'
    [ ! -f "$d/watcher.jsonl" ] || grep -hE '"kind":"(ci_completed|ci_watch_failed)"' "$d/watcher.jsonl" | sed 's/^/D /'
  done | K="$repo $pr $sha" awk '
    function v(k) { if (match($0, "\"" k "\":\"[^\"]*\"")) return substr($0, RSTART + length(k) + 4, RLENGTH - length(k) - 5)
                    if (match($0, "\"" k "\":[0-9]+")) return substr($0, RSTART + length(k) + 3, RLENGTH - length(k) - 3); return "" }
    v("repo") " " v("pr") " " v("sha") != ENVIRON["K"] { next }
    $1 == "R" { if (v("ts") >= rt) rt = v("ts"); next }
    { if (v("ts") >= dt) { dt = v("ts"); dk = v("kind"); dc = v("conclusion"); dr = v("run_id"); dw = v("reason") } }
    END { if (rt == "") print "none"; else if (dt == "" || dt < rt) print "open"
          else if (dk == "ci_completed") print dc, dr; else print "failed", dw, dt }')
case $ci in
  none|failed*)
    # no request for this head, or its watch failed: ask the watcher (once: an open request is not repeated)
    # A request is open only when it is later than the watcher's last line (ts has whole seconds), so a
    # new one in the same second as that ci_watch_failed would read as closed: wait for the next second.
    # ponytail: one sleep of up to 1 s, only on that rerun.
    case $ci in failed*) [ "${ci##* }" != "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ] || sleep 1 ;; esac
    bash "$org" --as secretary ci_requested --pr "$pr" --sha "$sha" --repo "$repo" "${targs[@]}" \
      || die 12 "the ci_requested line could not be written (scripts/org --as secretary ci_requested); nothing watches PR $pr"
    w=; [ "$ci" = none ] || { w=${ci#failed }; w=" again (the last watch failed: ${w% *})"; }
    echo "CI requested for $sha$w; the watcher mails the result. PR: $url" ;;
  open) echo "CI of $sha is still watched (requested before); the watcher mails the result. PR: $url" ;;
esac
case $ci in none|failed*|open) [ -z "$prgiven" ] || exit 4; exit 0 ;; esac
run=${ci#* }; concl=${ci%% *}
[ "$concl" = success ] || die 9 "CI failed on $sha (conclusion $concl, run $run, recorded by the watcher); PR $url"

# 4. approval mode: argument, else merge_approval_mode in org-config.md (Q14; org config set), else human
if [ -z "$mode" ]; then
  m=$(bash "$org" --as secretary config get merge_approval_mode 2>/dev/null)
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
