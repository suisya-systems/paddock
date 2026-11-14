#!/bin/sh
# Host probe for Issue #330: org-pull-request in acceptance mode and org-update-branch, run against a
# real repository whose `main` requires the `acceptance` check and "up to date before merging".
# What was only tested against stubs and a local bare repository (skills/org-pull-request/SKILL.md
# "Not measured", skills/org-update-branch/SKILL.md "Not measured") is run for real:
# `gh pr checks --required` under branch protection, `gh pr merge --squash --match-head-commit`,
# and a real push after org-update-branch.
#
#   sh scripts/probes/acceptance-mode.sh --repo OWNER/NAME --project DIR [--set-protection] [--task-id T]
#   sh scripts/probes/acceptance-mode.sh --only-settings          # only record paddock's own settings
#
# Run from the paddock repository root, inside a terminal that hc launched (org-pull-request starts
# its CI watcher with `hc run --bg` and waits with `hc wait`), as the person whose gh login may push
# to --repo. Needs git, gh, hc, bash, sh. About 10 minutes (five CI runs of the fixture job).
#
# The repository: the throwaway repository of Prototype 3 (docs/design/prototype-3.md, "Seed the
# throwaway repository"), already holding .github/workflows/acceptance.yml (job `acceptance`) and
# scripts/acceptance-check.sh on main, and no other workflow. --project is a clone of it (only its
# origin URL is read; the probe works in its own clones under the run folder). Never
# suisya-systems/paddock: the probe refuses it for anything it writes.
#   --set-protection  put the settings on main of --repo: require `acceptance`, require branches up
#                     to date, enforce for admins (so the owner's own login cannot bypass; needs admin
#                     on --repo). Without it the probe only reads them and stops when they are off.
#
# What it does, in order (every verdict line starts with "RESULT <name>:"):
#   settings-*    the throwaway's protection of main (read back); paddock's own, read only (INFO)
#   1-green-merge       branch A (a declared acceptance test first, then the file) goes through
#                       org-pull-request --mode acceptance with stdin closed: exit 0, the PR is
#                       MERGED, the CI run was green, nobody touched anything
#   2-update-branch     branch B was pushed and has a green PR before A merged, so main is now under
#                       it: org-update-branch merges origin/main, exit 0
#   2-push-no-force     the next `git push origin B` (no force flag) is a fast-forward and succeeds
#   3-stale-base-refused  before 2: org-pull-request --pr B --mode acceptance on the behind branch
#                       exits 10 or 11 and the PR stays OPEN
#   3-stale-head-refused  after 2, with the new head green: gh pr merge --match-head-commit <old
#                       head> is refused and the PR stays OPEN
#   2-merge-after-update  org-pull-request --pr B --mode acceptance on the updated head: exit 0, MERGED
# PASS needs the stated exit code and the stated PR state; anything else is FAIL, a step that could
# not run is NO DATA. Paste the whole output back. Order actually run: 3-stale-base, 2-update, push,
# green on the new head, 3-stale-head, 2-merge-after-update.
# The probe never touches ~/.claude.json, the claude install or any folder trust: it starts no
# claude. It writes only in the run folder, in --repo (branches and PRs named p330-<T>-*), and with
# --set-protection the protection of main of --repo. At the end (also on a failure) it closes its
# own open PRs and deletes its remote branches. The protection stays; the command that removes it
# is printed. The merged commits stay in --repo's main.
# Run folder: ${XDG_STATE_HOME:-~/.local/state}/paddock-p330/<T>. Exit: 0 all PASS, 1 a FAIL, 2 bad
# argument, 3 a tool is missing, 6 a precondition failed.
set -u

die() { c=$1; shift; echo "acceptance-mode: $*" >&2; exit "$c"; }
usage() { sed -n '2,47p' "$0"; }

repo= project= T= setp=0 only=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --only-settings) only=1; shift ;;
    --set-protection) setp=1; shift ;;
    --repo|--project|--task-id) [ $# -ge 2 ] || die 2 "$1 needs a value"
      case "$1" in --repo) repo=$2 ;; --project) project=$2 ;; *) T=$2 ;; esac; shift 2 ;;
    *) die 2 "unknown option: $1" ;;
  esac
done

for c in git gh bash; do command -v "$c" >/dev/null 2>&1 || die 3 "$c not found on PATH"; done
ROOT=$(pwd)
[ -f "$ROOT/skills/org-pull-request/scripts/org-pull-request.sh" ] || die 2 "run from the paddock repository root"
OPR="$ROOT/skills/org-pull-request/scripts/org-pull-request.sh"
OUB="$ROOT/skills/org-update-branch/scripts/org-update-branch.sh"
PADDOCK=suisya-systems/paddock
fail=0
res() { echo "RESULT $1: $2${3:+ ($3)}"; [ "$2" != FAIL ] || fail=1; }

# Paddock's own settings, read only. A 404/403 is recorded as what it is, not as "off".
gj() { gh api "$@" 2>&1; }
record_paddock() {
  p=$(gj "repos/$PADDOCK/branches/main/protection" --jq '"required=" + ((.required_status_checks.contexts // []) | join(",")) + " strict=" + ((.required_status_checks.strict // false) | tostring) + " enforce_admins=" + ((.enforce_admins.enabled // false) | tostring)')
  case $p in required=*) res settings-paddock-protection INFO "$p" ;; *) res settings-paddock-protection INFO "no readable classic protection: $(printf '%s' "$p" | tr '\n' ' ' | cut -c1-160)" ;; esac
  r=$(gj "repos/$PADDOCK/rules/branches/main" --jq '[.[] | .type + (if .parameters.strict_required_status_checks_policy then "(strict=" + (.parameters.strict_required_status_checks_policy|tostring) + " checks=" + ([.parameters.required_status_checks[]?.context] | join(",")) + ")" else "" end)] | join(" ")')
  res settings-paddock-rules INFO "${r:-none}"
}

if [ "$only" -eq 1 ]; then record_paddock; exit 0; fi

[ -n "$repo" ] && [ -n "$project" ] || die 2 "needs --repo OWNER/NAME and --project DIR (or --only-settings)"
repo=$(printf '%s' "$repo" | tr 'A-Z' 'a-z')
case "$repo" in */*/*|*/|/*|*/) die 2 "--repo must be OWNER/NAME" ;; */*) ;; *) die 2 "--repo must be OWNER/NAME" ;; esac
[ "$repo" != "$PADDOCK" ] || die 6 "never this repository: name a throwaway repository"
command -v hc >/dev/null 2>&1 || die 3 "hc not found on PATH (run inside a terminal that hc launched)"
[ -d "$project/.git" ] || git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || die 6 "$project is not a git repository"
url=$(git -C "$project" remote get-url origin 2>/dev/null) || die 6 "$project has no origin"
got=$(printf '%s' "$url" | sed -n 's#^\(https://github\.com/\|git@github\.com:\|ssh://git@github\.com/\)\([^/]*/[^/]*\)$#\2#p' | sed 's#\.git$##' | tr 'A-Z' 'a-z')
[ "$got" = "$repo" ] || die 6 "origin of $project is ${got:-not a GitHub URL}, not $repo"

[ -n "$T" ] || T=p330-$(date -u +%Y%m%d%H%M)
case "$T" in *[!A-Za-z0-9._-]*|"") die 2 "--task-id may hold only letters, digits, . _ -" ;; esac
RUN=${XDG_STATE_HOME:-$HOME/.local/state}/paddock-p330/$T
[ ! -e "$RUN" ] || die 6 "$RUN exists; use another --task-id"
mkdir -p "$RUN" || die 6 "cannot make $RUN"
export PADDOCK_STATE_DIR=$RUN/state # ci_completed lines go here, never into the real history
mkdir -p "$PADDOCK_STATE_DIR"
BA=$T-a BB=$T-b
PRS=

cleanup() {
  for n in $PRS; do
    [ "$(gh pr view "$n" --repo "$repo" --json state --jq .state 2>/dev/null)" = OPEN ] \
      && gh pr close "$n" --repo "$repo" --comment "p330 probe cleanup" >/dev/null 2>&1
  done
  for b in $BA $BB; do git -C "$RUN/a" push origin --delete "$b" >/dev/null 2>&1; done
  echo "cleanup: own open PRs closed, remote branches $BA $BB deleted; run folder kept: $RUN"
  echo "to remove the protection of main of $repo: gh api -X DELETE repos/$repo/branches/main/protection"
}
trap cleanup EXIT

# --- settings --------------------------------------------------------------------------------
if [ "$setp" -eq 1 ]; then
  printf '%s' '{"required_status_checks":{"strict":true,"contexts":["acceptance"]},"enforce_admins":true,"required_pull_request_reviews":null,"restrictions":null}' \
    | gh api -X PUT "repos/$repo/branches/main/protection" --input - >/dev/null 2>"$RUN/protect.err" \
    || die 6 "cannot set the protection of main of $repo (admin needed): $(cut -c1-200 "$RUN/protect.err")"
fi
p=$(gj "repos/$repo/branches/main/protection" --jq '(.required_status_checks.contexts // [] | join(",")) + "|" + (.required_status_checks.strict // false | tostring) + "|" + (.enforce_admins.enabled // false | tostring)')
case $p in *'|'*'|'*) ;; *) die 6 "cannot read the protection of main of $repo: $(printf '%s' "$p" | cut -c1-200)" ;; esac
ctx=${p%%|*}; rest=${p#*|}; strict=${rest%%|*}; adm=${rest#*|}
case ",$ctx," in *,acceptance,*) res settings-acceptance-required PASS "contexts=$ctx" ;; *) res settings-acceptance-required FAIL "contexts=$ctx"; die 6 "main does not require acceptance; rerun with --set-protection" ;; esac
if [ "$strict" = true ]; then res settings-up-to-date PASS; else res settings-up-to-date FAIL; die 6 "main does not require up-to-date branches; rerun with --set-protection"; fi
res settings-enforce-admins INFO "enforce_admins=$adm (false: the owner's login may bypass the checks, so a refusal below means less)"
record_paddock

# --- two clones, two branches ------------------------------------------------------------------
git clone -q "$url" "$RUN/a" && git clone -q "$url" "$RUN/b" || die 6 "cannot clone $url"
for d in a b; do git -C "$RUN/$d" switch -q main; done
base0=$(git -C "$RUN/a" rev-parse origin/main)
[ -f "$RUN/a/scripts/acceptance-check.sh" ] && [ -f "$RUN/a/.github/workflows/acceptance.yml" ] \
  || die 6 "main of $repo lacks the acceptance job (see docs/design/prototype-3.md, Seed the throwaway repository)"

# B first: one undeclared commit, pushed with a PR whose CI is green, not merged (human mode).
git -C "$RUN/b" switch -q -c "$BB"
echo "p330 $T b" > "$RUN/b/p330-$T-b.txt"
git -C "$RUN/b" add "p330-$T-b.txt" && git -C "$RUN/b" commit -q -m "p330 probe: branch B ($T)" || die 6 "cannot commit B"
out=$(bash "$OPR" --worktree "$RUN/b" --repo "$repo" --title "p330 probe B ($T)" --body "Throwaway PR of the Issue #330 probe; closed by the probe." --task-id "$T-b" --mode human </dev/null 2>&1); rc=$?
echo "$out" > "$RUN/b-open.out"
nb=$(printf '%s\n' "$out" | sed -n 's#^PR_URL=.*/pull/\([0-9][0-9]*\)$#\1#p' | tail -1)
[ -n "$nb" ] && PRS="$PRS $nb"
[ "$rc" -eq 0 ] && [ -n "$nb" ] || die 6 "B did not reach a green PR in human mode (exit $rc): see $RUN/b-open.out"
b_old=$(git -C "$RUN/b" rev-parse HEAD)

# 1. A: a declared acceptance test first, the file second; org-pull-request, acceptance mode, no hand step.
git -C "$RUN/a" switch -q -c "$BA"
mkdir -p "$RUN/a/tests"
printf '%s\n' '#!/usr/bin/env bash' "[ \"\$(cat p330-$T-a.txt 2>/dev/null)\" = \"p330 $T a\" ]" > "$RUN/a/tests/p330-$T.test.sh"
git -C "$RUN/a" add "tests/p330-$T.test.sh"
git -C "$RUN/a" commit -q -m "p330 probe: failing test first" -m "Acceptance-Test: tests/p330-$T.test.sh" || die 6 "cannot commit A's test"
echo "p330 $T a" > "$RUN/a/p330-$T-a.txt"
git -C "$RUN/a" add "p330-$T-a.txt" && git -C "$RUN/a" commit -q -m "p330 probe: the file" || die 6 "cannot commit A's file"
out=$(bash "$OPR" --worktree "$RUN/a" --repo "$repo" --title "p330 probe A ($T)" --body "Throwaway PR of the Issue #330 probe; merged by org-pull-request in acceptance mode." --task-id "$T-a" --mode acceptance </dev/null 2>&1); rc=$?
echo "$out" > "$RUN/a-merge.out"
na=$(printf '%s\n' "$out" | sed -n 's#^PR_URL=.*/pull/\([0-9][0-9]*\)$#\1#p' | tail -1)
[ -n "$na" ] && PRS="$PRS $na"
st=$(gh pr view "$na" --repo "$repo" --json state --jq .state 2>/dev/null)
ok=$(cat "$PADDOCK_STATE_DIR"/events/*/secretary.jsonl 2>/dev/null | grep -c "\"pr\":$na,.*\"exit_code\":0")
if [ "$rc" -eq 0 ] && [ "$st" = MERGED ] && [ "$ok" -ge 1 ]; then res 1-green-merge PASS "exit 0, PR $na MERGED, ci_completed exit_code 0 recorded"
elif [ -z "$na" ]; then res 1-green-merge "NO DATA" "no PR was opened; see $RUN/a-merge.out"
else res 1-green-merge FAIL "exit $rc, PR $na state ${st:-unknown}, ci_completed lines $ok; see $RUN/a-merge.out"; fi
git -C "$RUN/b" fetch -q origin
base1=$(git -C "$RUN/b" rev-parse origin/main)
[ "$base1" != "$base0" ] || { res 2-update-branch "NO DATA" "main did not move (A not merged)"; exit 1; }

# 3a. B is behind main now: acceptance mode must refuse.
out=$(bash "$OPR" --worktree "$RUN/b" --repo "$repo" --pr "$nb" --task-id "$T-b" --mode acceptance </dev/null 2>&1); rc=$?
echo "$out" > "$RUN/b-stale-base.out"
st=$(gh pr view "$nb" --repo "$repo" --json state,mergeStateStatus --jq '.state + "/" + .mergeStateStatus' 2>/dev/null)
case "$rc:$st" in
  10:OPEN/*|11:OPEN/*) res 3-stale-base-refused PASS "exit $rc, PR $nb $st" ;;
  *) res 3-stale-base-refused FAIL "exit $rc, PR $nb ${st:-unknown}, expected exit 10 or 11 and OPEN; see $RUN/b-stale-base.out" ;;
esac

# 2. org-update-branch, then a plain push (no force flag) that must fast-forward.
bash "$OUB" --worktree "$RUN/b" >"$RUN/b-update.out" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && git -C "$RUN/b" merge-base --is-ancestor "$base1" HEAD && git -C "$RUN/b" merge-base --is-ancestor "$b_old" HEAD; then
  res 2-update-branch PASS "exit 0, origin/main $(echo "$base1" | cut -c1-9) and the old head are both in the branch"
else res 2-update-branch FAIL "exit $rc; see $RUN/b-update.out"; fi
if git -C "$RUN/b" push origin "$BB" >"$RUN/b-push.out" 2>&1 \
   && [ "$(git ls-remote origin "refs/heads/$BB" 2>/dev/null | cut -f1)" = "$(git -C "$RUN/b" rev-parse HEAD)" ]; then
  res 2-push-no-force PASS "plain git push accepted"
else res 2-push-no-force FAIL "see $RUN/b-push.out"; fi
b_new=$(git -C "$RUN/b" rev-parse HEAD)

# The new head must be green and up to date first, so the next refusal can only be about the head pin.
out=$(bash "$OPR" --worktree "$RUN/b" --repo "$repo" --pr "$nb" --task-id "$T-b" --mode human </dev/null 2>&1); rc=$?
echo "$out" > "$RUN/b-new-head.out"
if [ "$rc" -ne 0 ]; then
  res 3-stale-head-refused "NO DATA" "the updated head did not go green (exit $rc); see $RUN/b-new-head.out"
  res 2-merge-after-update "NO DATA" "same"
else
  # 3b. merge pinned to the OLD head: refused, PR stays open.
  gh pr merge "$nb" --repo "$repo" --squash --match-head-commit "$b_old" >"$RUN/b-stale-head.out" 2>&1; rc=$?
  st=$(gh pr view "$nb" --repo "$repo" --json state --jq .state 2>/dev/null)
  if [ "$rc" -ne 0 ] && [ "$st" = OPEN ]; then res 3-stale-head-refused PASS "exit $rc, PR $nb OPEN"
  else res 3-stale-head-refused FAIL "exit $rc, PR $nb ${st:-unknown}; see $RUN/b-stale-head.out"; fi
  # Finally the real thing on the updated head.
  out=$(bash "$OPR" --worktree "$RUN/b" --repo "$repo" --pr "$nb" --task-id "$T-b" --mode acceptance </dev/null 2>&1); rc=$?
  echo "$out" > "$RUN/b-merge.out"
  st=$(gh pr view "$nb" --repo "$repo" --json state --jq .state 2>/dev/null)
  if [ "$rc" -eq 0 ] && [ "$st" = MERGED ]; then res 2-merge-after-update PASS "exit 0, PR $nb MERGED on $(echo "$b_new" | cut -c1-9)"
  else res 2-merge-after-update FAIL "exit $rc, PR $nb ${st:-unknown}; see $RUN/b-merge.out"; fi
fi

echo "NOT COVERED: PADDOCK_ORG in a real worker session (org-update-branch's worker check); run org-update-branch from a worker for that."
echo "run folder: $RUN"
exit $fail
