#!/usr/bin/env bash
# org-pull-request: push a worker's branch, open the PR and record ci_requested; org-watch watches
# CI and records ci_completed (decision 0013). With --pr, act on that record for the current head:
# raise the merge card and merge on its checked yes (human), or merge (acceptance). Needs bash, git and gh.
# See ../SKILL.md. Run it from the secretary.
set -u

usage() {
  cat <<'USAGE'
Usage: org-pull-request.sh --title TITLE (--body-file FILE | --body TEXT) [options]
       org-pull-request.sh --pr N [options]
       org-pull-request.sh --pr N --approved APPROVAL_ID [--note TEXT] [options]

Pushes the worktree's branch to origin, opens a PR and appends ci_requested for its head:
org-watch watches CI, records ci_completed (or ci_watch_failed) and mails the secretary
(decision 0013). With --pr N it reads the watcher's record for the current head and acts by
approval mode; a head with no request yet, or whose watch failed, is requested (once).
Human mode: a green head gets one merge card (org-escalation ask), once per head; a card
raised for an older head is withdrawn. The rerun with --approved merges only after
org-escalation remove --text yes found the yes in the person's own file.

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
  --recheck          with --pr: request the head again although the watcher recorded a result
                     (CI was rerun on the same commit); never while a request is open
  --approved ID      with --pr, human mode: the merge card ID was answered yes. Checked against
                     the person's file (org-escalation remove --id ID --text yes), then merged
                     with the acceptance guards (same head, required checks green)
  --note TEXT        with --approved: the note the person's yes carried
  -h, --help         this text

Environment overrides:
  PADDOCK_STATE_DIR   scripts/org's state folder, whose events/ holds the records (default
                      ${XDG_STATE_HOME:-~/.local/state}/paddock)
  PADDOCK_NOW         fixes the clock (UTC ISO 8601), for the months read

Exit codes: 0 done (no --pr: PR opened, CI requested; --pr, human: CI green, the merge card
is up, or merged on its checked yes; --pr, acceptance: merged; --pr, PR already merged:
landing placed), 2 bad argument,
3 gh or git not found, 4 no CI result recorded for the head yet (requested now or still
watched; the watcher mails it), 5 push failed, 6 PR could not be created, 9 CI failed,
10 merge refused (head moved or required checks not green), 11 merge failed, 12 the
ci_requested line could not be written, 13 merged, but the files org-start placed were not
placed again (a landing in the paddock repository), 14 the merge card could not be raised
or read, 15 --approved: no yes in the person's file (not merged, card kept).

Every exit prints one line "next: <exact action>" (or "next: ask the person: <question>"): do that.

A landing in the paddock repository itself places the files again in BOTH approval modes: after the
script's own merge (acceptance), or when a --pr rerun finds the PR merged (the person merged it in
human mode). It runs org-start.sh --place-only --from-origin BASE, starting nothing.
USAGE
}

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
self=$root/skills/org-pull-request/scripts/org-pull-request.sh
# die <code> <message> <next>: every non-zero exit ends with one `next:` line (decision 0014).
die() { echo "org-pull-request: $2" >&2; echo "next: $3" >&2; exit "$1"; }
qself=$(printf "%q" "$self")
fixcall="fix the call (bash $qself --help)"

wt=.; repo=; base=; project=; task=; mode=; pr=; title=; body=; bodyfile=; recheck=; approved=; note=
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --recheck) recheck=1; shift ;;
    --worktree|--repo|--project|--base|--task-id|--mode|--pr|--title|--body|--body-file|--approved|--note)
      [ $# -ge 2 ] || die 2 "$1 needs a value" "$fixcall"
      case $1 in
        --worktree) wt=$2 ;; --repo) repo=$2 ;; --project) project=$2 ;; --base) base=$2 ;; --task-id) task=$2 ;;
        --mode) mode=$2 ;; --pr) pr=$2 ;; --title) title=$2 ;; --body) body=$2 ;; --body-file) bodyfile=$2 ;;
        --approved) approved=$2 ;; --note) note=$2 ;;
      esac
      shift 2 ;;
    *) usage >&2; die 2 "unknown argument: $1" "$fixcall" ;;
  esac
done

if [ -n "$project" ]; then # only the row's base is used here (the worktree is the worker's)
  . "$(dirname "${BASH_SOURCE[0]}")/../../org-delegate/scripts/project.sh"
  project_lookup "$project"; rc=$?
  [ "$rc" -ne 2 ] || die 2 "--project $project: projects.md does not exist (set PADDOCK_PROJECTS_FILE)" "ask the person: projects.md is missing; where is it?"
  [ "$rc" -eq 0 ] || die 2 "no project named $project with a path in projects.md" "$fixcall (use a project name from projects.md)"
  [ -n "$base" ] || base=$project_base
fi
[ -n "$base" ] || base=main
case $mode in ""|human|acceptance) ;; *) die 2 "--mode must be human or acceptance" "$fixcall" ;; esac
case $pr in ""|*[!0-9]*) [ -z "$pr" ] || die 2 "--pr must be a number" "$fixcall" ;; esac
[ -z "$recheck" ] || [ -n "$pr" ] || die 2 "--recheck needs --pr" "$fixcall"
[ -z "$approved" ] || [ -n "$pr" ] || die 2 "--approved needs --pr" "$fixcall"
[ -z "$note" ] || [ -n "$approved" ] || die 2 "--note needs --approved" "$fixcall"
case $approved in -*|*[!A-Za-z0-9_-]*) die 2 "--approved takes the approval id (APPROVAL_ID=...)" "$fixcall" ;; esac
[ -n "$pr" ] || [ -n "$title" ] || die 2 "--title is required unless --pr is given" "$fixcall"
[ -n "$pr" ] || [ -n "$body$bodyfile" ] || die 2 "--body-file or --body is required unless --pr is given" "$fixcall"
[ -z "$bodyfile" ] || [ -f "$bodyfile" ] || die 2 "body file not found: $bodyfile" "$fixcall"
case $task in *[!A-Za-z0-9._-]*) die 2 "--task-id may hold only letters, digits, . _ -" "$fixcall" ;; esac

if [ -z "$repo" ]; then # owner/name from a GitHub origin URL only
  url=$(git -C "$wt" remote get-url origin 2>/dev/null)
  repo=$(printf '%s' "$url" | sed -n 's#^\(https://github\.com/\|git@github\.com:\|ssh://git@github\.com/\)\([^/]*/[^/]*\)$#\2#p' | sed 's#\.git$##')
  [ -n "$repo" ] || die 2 "cannot read OWNER/NAME from the origin URL; pass --repo" "$fixcall (add --repo OWNER/NAME)"
fi

for c in git gh; do command -v "$c" >/dev/null 2>&1 || die 3 "$c not found on PATH" "ask the person: $c is not on PATH; can they install it?"; done
branch=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null) || die 2 "no branch checked out in $wt" "$fixcall (--worktree must be the worker's worktree)"
sha=$(git -C "$wt" rev-parse HEAD) || die 2 "$wt is not a git worktree" "$fixcall (--worktree must be the worker's worktree)"
# A landing in the paddock repository itself (the worktree shares this folder's git store) may change the
# files org-start placed: place them again from the fetched base, starting nothing. Both modes call this:
# after the script's own merge (acceptance), or when a --pr rerun finds the PR merged (the person merged).
# $1 is the next: line when nothing else needs the person.
gitdir() { (cd "$1" && cd "$(git rev-parse --git-common-dir)" && pwd -P) 2>/dev/null; }
place_landing() {
  if [ "$(gitdir "$wt")" = "$(gitdir "$root")" ]; then
    # the branch the PR landed on: a --pr rerun need not repeat --base.
    b=$(gh pr view "$pr" --repo "$repo" --json baseRefName --jq .baseRefName 2>/dev/null); base=${b:-$base}
    out=$(bash "$root/skills/org-start/scripts/org-start.sh" --place-only --from-origin "$base" 2>&1); rc=$?
    [ -z "$out" ] || printf '%s\n' "$out"
    [ "$rc" -eq 0 ] || die 13 "merged, but the placed files were not renewed" \
      "run: bash $(printf "%q" "$root/skills/org-start/scripts/org-start.sh") --place-only --from-origin $base; if it fails again, ask the person: placing failed (output above); how do they want to proceed?"
    # both can come together: repair the checkout first, since a renewed secretary would read the old one.
    left=; case $out in *"left alone"*) left="ask the person to run the command the org-start line above gives (the paddock checkout was left alone)" ;; esac
    ren=; case $out in *"RENEWAL NEEDED"*) ren="ask the person to renew the secretary (secretary-handover skill: secretary.md changed and only a new secretary reads it)" ;; esac
    if [ -n "$left$ren" ]; then
      echo "next: ${left}${left:+, then }${ren}${ren:+, then }${1}"; return
    fi
  fi
  echo "next: $1"
}

ev=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}/events
# a rerun without --task-id: the task the first run recorded with this PR's ci_requested
[ -n "$task" ] || task=$(cat "$ev"/*/secretary.jsonl 2>/dev/null | grep '"kind":"ci_requested"' | grep "\"pr\":$pr,\"sha\"" \
  | grep "\"repo\":\"$repo\"" | sed -n 's/.*"task_id":"\([A-Za-z0-9._-]*\)".*/\1/p' | tail -1)

# The merge card (human mode) is an org-escalation approval of the task whose question is exactly
# cardq <full head sha> <lang>: the head is the full sha, so the card is bound to that one commit.
esc=$root/skills/org-escalation/scripts/org-escalation.sh; qesc=$(printf "%q" "$esc")
cardq() { if [ "$2" = ja ]; then printf 'PR #%s (%s, head %s) をマージしますか?' "$pr" "$repo" "$1"
          else printf 'Merge PR #%s (%s, head %s)?' "$pr" "$repo" "$1"; fi; }
# scan_cards <keep sha> <why, %s = the old head>: reads the open cards (org-escalation list; sets listed).
# The merge card of this PR and task for <keep sha> is $card (raised once per head); any other one
# is withdrawn with a plain remove (nobody's answer is taken), and is no longer --approved.
card=; listed=
scan_cards() {
  local cards cid tid q h o
  [ -n "$pr" ] && [ -n "$task" ] || return 0
  cards=$(bash "$esc" list 2>/dev/null) || return 0
  listed=1
  while IFS=$'\t' read -r cid tid q; do
    [ "$tid" = "$task" ] || continue
    h=$(printf '%s' "$q" | sed -n 's/.*, head \([0-9a-f]\{40\}\)).*/\1/p')
    [ -n "$h" ] && { [ "$q" = "$(cardq "$h" en)" ] || [ "$q" = "$(cardq "$h" ja)" ]; } || continue
    if [ "$h" = "$1" ]; then card=$cid; continue; fi
    o=$(bash "$esc" remove --id "$cid" 2>&1) || die 14 "the merge card $cid of PR $pr could not be withdrawn: $(printf '%s' "$o" | grep -v '^next:' | tr '\n' ' ')" \
      "ask the person: the merge card $cid of PR $pr no longer applies and could not be withdrawn (output above); never merge on it. How do they want to proceed?"
    echo "Merge card $cid withdrawn: $(printf "$2" "${h:0:7}"). Not merged by the script."
    [ "$cid" != "$approved" ] || approved=
  done <<< "$cards"
}

# A --pr rerun after the PR was merged by hand (human mode): nothing to push or watch; place and finish.
if [ -n "$pr" ] && [ "$(gh pr view "$pr" --repo "$repo" --json state --jq .state 2>/dev/null)" = MERGED ]; then
  echo "PR https://github.com/$repo/pull/$pr is merged."
  scan_cards "" "the PR (card for head %s) is merged already"   # its merge card, if one is still up
  place_landing "close the worker (org-close skill)"
  exit 0
fi

# 1. push (from the worktree)
git -C "$wt" push origin "$branch" >&2 || die 5 "git push origin $branch failed" "ask the person: git push of $branch failed (output above); nothing was opened. How do they want to proceed?"

# 1b. the task's last diff-review record in the codex-gate history. Unless it is
# codex_round_passed (or there is none), the body itself says the review did not run, so a body
# file written without that still carries it. Needs --task-id; a design review is not this review.
# gate_rec: that record; gate_text: it as "<kind>: <text>" (also the merge card's background).
gate_rec() { cat "${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}"/events/*/codex-gate.jsonl 2>/dev/null \
    | grep "\"task_id\":\"$task\",\"text\":\"diff round " | grep -E '"kind":"codex_round_(passed|failed)"' | tail -1; }
gate_text() { printf '%s' "$1" | sed 's/.*"kind":"\([^"]*\)".*"text":"\(.*\)"}$/\1: \2/'; }
if [ -z "$pr" ] && [ -n "$task" ]; then
  gl=$(gate_rec)
  case $gl in
    *'"kind":"codex_round_passed"'*) ;;
    *)
      bnote="Second-model review did not run: no passed diff review is recorded for task $task."
      [ -z "$gl" ] || bnote="Second-model review did not run. Gate record: $(gate_text "$gl")"
      bf=$(mktemp) || die 6 "cannot make a temporary body file" "ask the person: no temporary file can be made (the branch is pushed, no PR yet); is the disk full?"
      { if [ -n "$bodyfile" ]; then cat "$bodyfile"; else printf '%s\n' "$body"; fi; printf '\n%s\n' "$bnote"; } > "$bf"
      bodyfile=$bf; body= ;;
  esac
fi

# 2. PR
prgiven=$pr
if [ -z "$pr" ]; then
  args=(--repo "$repo" --head "$branch" --base "$base" --title "$title")
  if [ -n "$bodyfile" ]; then args+=(--body-file "$bodyfile"); else args+=(--body "$body"); fi
  url=$(gh pr create "${args[@]}") || die 6 "gh pr create failed" "ask the person: the branch is pushed but the PR could not be created (output above); how do they want to proceed?"
  url=$(printf '%s\n' "$url" | tail -1)
  pr=${url##*/}
  case $pr in ""|*[!0-9]*) die 6 "no PR number in the answer of gh pr create: $url" "ask the person: the branch is pushed; did the PR open? (the answer is above)" ;; esac
else
  url="https://github.com/$repo/pull/$pr"
fi
echo "PR_URL=$url"
org=$root/scripts/org
again="bash $qself --pr $pr --worktree $(printf "%q" "$wt") --repo $repo${mode:+ --mode $mode}${task:+ --task-id $task}"   # the rerun the secretary is told to make
targs=(); [ -z "$task" ] || targs=(--task "$task")

# approval mode: argument, else merge_approval_mode in org-config.md (Q14; org config set), else human
if [ -z "$mode" ]; then
  m=$(bash "$org" --as secretary config get merge_approval_mode 2>/dev/null)
  case $m in acceptance) mode=acceptance ;; *) mode=human ;; esac
fi
[ -z "$approved" ] || [ "$mode" = human ] || die 2 "--approved is for human mode (the approval mode is $mode)" "$fixcall"

# 3. the head's CI state from the records (this calendar month and the last, as org-watch reads them):
# the secretary's latest ci_requested for repo, pr and sha, and the watcher's latest ci_completed or
# ci_watch_failed at or after it. The skill's own old ci_completed lines (from secretary) do not count.
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
# --recheck: a recorded result is set aside, so the head is requested again (an open request stays one)
[ -z "$recheck" ] || case $ci in none|open|failed*) ;; *) ci="failed recheck $(date -u +%Y-%m-%dT%H:%M:%SZ)" ;; esac
# Human mode: the merge cards of this PR, kept for the current head, withdrawn for an older one.
s7=${sha:0:7}
if [ "$mode" = human ] && { [ -n "$prgiven" ] || [ "${ci%% *}" = success ]; }; then
  scan_cards "$sha" "it names head %s, the head is now $s7"
fi

case $ci in
  none|failed*)
    # no request for this head, or its watch failed: ask the watcher (once: an open request is not repeated)
    # A request is open only when it is later than the watcher's last line (ts has whole seconds), so a
    # new one in the same second as that ci_watch_failed would read as closed: wait for the next second.
    # ponytail: one sleep of up to 1 s, only on that rerun.
    case $ci in failed*) [ "${ci##* }" != "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ] || sleep 1 ;; esac
    bash "$org" --as secretary ci_requested --pr "$pr" --sha "$sha" --repo "$repo" "${targs[@]}" \
      || die 12 "the ci_requested line could not be written (scripts/org --as secretary ci_requested); nothing watches PR $pr" \
           "ask the person: nothing watches PR $pr because its ci_requested record could not be written (output above); how do they want to proceed?"
    w=; [ "$ci" = none ] || { w=${ci#failed }; w=" again (the last watch failed: ${w% *})"; }
    [ -z "$recheck" ] || [ "$ci" = none ] || w=" again (--recheck)"
    echo "CI requested for $sha$w; the watcher mails the result. PR: $url" ;;
  open) echo "CI of $sha is still watched (requested before); the watcher mails the result. PR: $url" ;;
esac
case $ci in none|failed*|open)
  echo "next: end the turn; the watcher's CI line wakes you, then run: $again"
  [ -z "$prgiven" ] || exit 4; exit 0 ;; esac
run=${ci#* }; concl=${ci%% *}
[ "$concl" = success ] || die 9 "CI failed on $sha (conclusion $concl, run $run, recorded by the watcher); PR $url" \
  "send the worker back with this failure; never merge. If CI was rerun on the same commit instead, run: $again --recheck"

# 4. human mode: the person decides on the merge card; the script raises it (once per head) and
# merges only on the rerun with --approved, once the yes is found in the person's own file.
nomerge="do not merge. If the person answered no: send their note to the worker, then run: bash $qesc remove --id ${approved:-<card id>} --text no (add --note \"<their note, as written>\" when the answer had one)"
if [ "$mode" = human ]; then
  echo "CI green on $sha (run $run). Approval mode human: the person decides on the merge card. PR: $url"
  [ -n "$task" ] || die 14 "no task id for PR $pr (no --task-id, and its ci_requested records name none); no merge card raised" \
    "$fixcall: run $again --task-id <the worker's task id>"
  [ -n "$listed" ] || die 14 "the open cards could not be read (org-escalation list); no merge card raised" \
    "ask the person: PR $url is green at $s7 (watcher: run $run), but its merge card could not be raised (org-state unreadable); merge it?"
  if [ -n "$approved" ] && [ "$approved" != "$card" ]; then
    die 2 "$approved is not the open merge card of PR $pr at head $s7; not merged" \
      "run: bash $qesc list, then rerun with --approved <the id of the card naming PR #$pr and head $s7>"
  fi
  if [ -z "$approved" ]; then
    if [ -n "$card" ]; then echo "Merge card $card for head $s7 is up already; not raised again. Not merged."
    else
      lang=$(bash "$org" --as secretary doc get org-state 2>/dev/null | sed -n 's/.*"conversation_lang" *: *"\([A-Za-z-]*\)".*/\1/p' | head -1)
      ciline="CI success on PR $pr, head $s7, run $run (recorded by the watcher)"
      gl=$(gate_rec); gok=; case $gl in *'"kind":"codex_round_passed"'*) gok=1 ;; esac
      if [ -n "$gl" ]; then gate=$(gate_text "$gl" | cut -c1-200); else gate="no diff review recorded for task $task"; fi
      if [ "$lang" = ja ]; then
        q=$(cardq "$sha" ja)
        bg="$url / $ciline。第二モデルのレビュー(タスク履歴): $gate"
        yes="秘書が PR #$pr を head $s7 のまま squash でマージし(head が変わらず必須チェックが緑のときだけ)、ワーカーを閉じます。"
        no="マージしません。メモはワーカーに送られ、ワーカーがブランチを直します。新しい head には新しいカードが出ます。"
        if [ -n "$gok" ]; then why="この head で CI が緑で、第二モデルのレビューも通っています。"
        else why="この head で CI が緑です。第二モデルのレビューは通っていません(背景を参照)。"; fi
      else
        q=$(cardq "$sha" en)
        bg="$url / $ciline. Second-model review (task history): $gate"
        yes="The secretary merges PR #$pr at head $s7 (squash; only if the head is unchanged and the required checks are green), then closes the worker."
        no="Not merged. Your note goes to the worker, who changes the branch; the new head gets a new card."
        if [ -n "$gok" ]; then why="CI is green on this exact head and the second-model review passed."
        else why="CI is green on this exact head; the second-model review did not pass (see the background)."; fi
      fi
      o=$(bash "$esc" ask --task "$task" --question "$q" --background "$bg" --if-yes "$yes" --if-no "$no" \
            --recommend yes --why "$why" ${lang:+--lang "$lang"} 2>&1) \
        || die 14 "the merge card could not be raised: $(printf '%s' "$o" | grep -v '^next:' | tr '\n' ' ')" \
             "ask the person: PR $url is green at $s7 (watcher: run $run), but its merge card could not be raised (output above); merge it?"
      card=$(printf '%s\n' "$o" | sed -n 's/^APPROVAL_ID=//p')
      echo "Merge card $card raised for head $s7. Not merged."
    fi
    echo "next: tell the person the merge card for PR $url is up, then end the turn. On yes, run: $again --approved $card (add --note \"<their note, as written>\" when the yes had one). On no: send their note to the worker, then run: bash $qesc remove --id $card --text no (with --note likewise)"
    exit 0
  fi
fi

# 5. acceptance: no local gate (Q11 d). The required checks are the repository's CI; here we only
# check that they are green on the exact head that was watched, then pin the merge to it.
# The same guards for a checked yes in human mode (--approved), whose card is withdrawn on a moved head.
now=$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq .headRefOid 2>/dev/null)
moved="run once the new head is pushed (it requests that head): $again"
if [ "$now" != "$sha" ]; then
  [ -z "$approved" ] || { bash "$esc" remove --id "$approved" >/dev/null 2>&1 && echo "Merge card $approved withdrawn: the PR head moved."; }
  die 10 "head moved: watched $sha, PR is at ${now:-unknown}; not merged" "$moved"
fi
# --watch: other workflows of the same head may still run; wait for them, do not refuse early.
gh pr checks "$pr" --repo "$repo" --required --watch >/dev/null 2>&1 \
  || die 10 "required checks are not all green on $sha; not merged" "$moved"
if [ -n "$approved" ]; then # the person's yes, from their own file (org-escalation's check); the card goes with it
  o=$(bash "$esc" remove --id "$approved" --text yes ${note:+--note "$note"} 2>&1) \
    || die 15 "no yes for $approved in the person's file: $(printf '%s' "$o" | grep -v '^next:' | tr '\n' ' ')" "$nomerge"
  printf '%s\n' "$o"
fi
gh pr merge "$pr" --repo "$repo" --squash --match-head-commit "$sha" >&2 \
  || die 11 "the merge call failed" "ask the person: merging PR $pr failed (output above); how do they want to proceed?"
echo "Merged PR $url at $sha (squash, approval mode $mode${approved:+, card $approved})."
place_landing "close the worker (org-close skill)"
