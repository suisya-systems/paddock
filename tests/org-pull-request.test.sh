#!/usr/bin/env bash
# Acceptance test for skills/org-pull-request/scripts/org-pull-request.sh (stubbed gh). Decision 0013,
# stage 3: the skill pushes, opens the PR and records ci_requested; org-watch watches CI and records
# ci_completed (here written with scripts/org --as watcher, as ci-watch.sh does); --pr acts on it.
# Needs only bash, coreutils and git: a local bare repository stands in for origin, so
# nothing reaches GitHub and no core runs.
#
# Stub knobs (environment of the script under test):
#   STUB_HEAD=sha       `gh pr view` reports this head (default: the pushed head)
#   STUB_CHECKS_RC=N    `gh pr checks` exits N (default 0)
#   STUB_MERGE_FAIL=1   `gh pr merge` fails
#   STUB_PR_FAIL=1      `gh pr create` fails
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
script=$here/skills/org-pull-request/scripts/org-pull-request.sh

stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/gh" <<'EOF2'
#!/bin/sh
echo "gh $*" >> "$STUB/calls"
case "$1 $2" in
  "pr create") [ -z "${STUB_PR_FAIL:-}" ] || { echo 'gh: create failed' >&2; exit 1; }
    echo "https://github.com/o/r/pull/42"; exit 0 ;;
  "pr view") echo "${STUB_HEAD:-$(cat "$STUB/head")}"; exit 0 ;;
  "pr checks") exit "${STUB_CHECKS_RC:-0}" ;;
  "pr merge") [ -z "${STUB_MERGE_FAIL:-}" ] || { echo 'gh: merge failed' >&2; exit 1; }
    exit 0 ;;
esac
exit 0
EOF2
chmod +x "$stubdir/gh"

# origin is a bare repo; the worker's worktree is a clone on branch feat/x.
origin=$tmp/origin.git; wt=$tmp/wt
git init -q --bare "$origin"
git clone -q "$origin" "$wt" 2>/dev/null
gitc() { git -C "$wt" -c user.name=t -c user.email=t@t "$@"; }
gitc checkout -q -b feat/x
gitc commit -q --allow-empty -m one
head=$(git -C "$wt" rev-parse HEAD)

ev=$tmp/state/events
month=$(date -u +%Y-%m)
evfile=$ev/$month/secretary.jsonl
calls=$tmp/stub/calls
reset() { # fresh stub state, empty events folder, empty origin refs
  rm -rf "$tmp/stub" "$ev"; mkdir -p "$tmp/stub" "$ev"; : > "$calls"
  printf '%s\n' "$head" > "$tmp/stub/head"
  git -C "$origin" for-each-ref --format='%(refname)' | while read -r r; do git -C "$origin" update-ref -d "$r"; done
}
run_script() { # run_script [args...]; extra env via ENVX (space separated)
  env -u PADDOCK_NOW STUB="$tmp/stub" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_ORG_CONFIG_FILE="$tmp/no-org-config.md" \
      PATH="$stubdir:$PATH" ${ENVX:-} bash "$script" --worktree "$wt" --repo o/r "$@" 2>&1
}
# watcher <ci_completed|ci_watch_failed> [args]: the watcher's record of this head, as ci-watch.sh writes it
watcher() { local k=$1; shift
  if [ "$k" = ci_completed ]; then set -- --run-id 777 --exit-code "${CODE:-0}" "$@"; else set -- --reason "${REASON:-no_run}" --log /x.log "$@"; fi
  env -u PADDOCK_NOW -u PADDOCK_ORG_ID PADDOCK_STATE_DIR="$tmp/state" PATH="/usr/bin:/bin" bash "$here/scripts/org" --as watcher "$k" \
    --pr 42 --sha "$head" --repo o/r "$@" >/dev/null; }
nreq() { grep -c '"kind":"ci_requested"' "$evfile" 2>/dev/null || echo 0; }
has() { grep -Eq -- "$1" "$calls"; }
merged() { has '^gh pr merge'; }
body=$tmp/body.md; printf 'Body text\n' > "$body"
args=(--title "feat: x" --body-file "$body")

[ -f "$script" ]; check "script exists" $?
[ -f "$here/skills/org-pull-request/SKILL.md" ]; check "SKILL.md exists" $?
bash -n "$script" 2>/dev/null; check "script parses" $?

out=$(bash "$script" --help 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -qi usage <<<"$out"; check "--help exits 0 with usage" $?
bash "$script" --no-such-flag >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; check "unknown argument exits 2" $?
reset; run_script --mode sometimes "${args[@]}" >/dev/null; rc=$?
[ "$rc" -eq 2 ] && [ ! -s "$calls" ]; check "invalid mode exits 2 before any call" $?
reset; run_script --body-file "$body" >/dev/null; rc=$?
[ "$rc" -eq 2 ] && [ ! -s "$calls" ]; check "missing title (no --pr) exits 2 before any call" $?
reset; env STUB="$tmp/stub" PATH="$stubdir:$PATH" bash "$script" --worktree "$wt" "${args[@]}" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && [ ! -s "$calls" ]; check "no --repo and an origin that is not a GitHub URL exits 2 (never guesses a repository)" $?
mkdir -p "$tmp/nogh"; ln -s "$(command -v git)" "$tmp/nogh/git"
out=$(env PATH="$tmp/nogh" "$(command -v bash)" "$script" --worktree "$wt" --repo o/r "${args[@]}" 2>&1); rc=$?
[ "$rc" -eq 3 ]; check "no gh on PATH exits 3" $?
mkdir -p "$tmp/nohc"; ln -s "$(command -v git)" "$tmp/nohc/git"; ln -s "$stubdir/gh" "$tmp/nohc/gh"
reset; env STUB="$tmp/stub" PADDOCK_STATE_DIR="$tmp/state" PATH="$tmp/nohc:/usr/bin:/bin" bash "$script" --worktree "$wt" --repo o/r "${args[@]}" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; check "hc is not needed any more (the watcher watches CI)" $?

# First run: push, create, record ci_requested, exit 0. No watch of its own.
reset; out=$(run_script "${args[@]}"); rc=$?
[ "$rc" -eq 0 ]; check "the first run exits 0 once the PR is opened and CI requested ($out)" $?
[ "$(git -C "$origin" rev-parse refs/heads/feat/x 2>/dev/null)" = "$head" ]; check "the branch was pushed to origin" $?
has '^gh pr create .*--repo o/r' && has '^gh pr create .*--head feat/x' && has '^gh pr create .*--title feat: x' && has "^gh pr create .*--body-file $body"; check "gh pr create names the repo, head, title and body file" $?
grep -q 'https://github.com/o/r/pull/42' <<<"$out"; check "the PR URL is printed" $?
grep -qi 'watcher' <<<"$out"; check "the output says the watcher mails the result" $?
! has '^gh run|^hc ' && ! merged && ! has '^gh pr (view|checks)'; check "no run lookup, no gh run watch, no hc, no merge" $?
[ -f "$evfile" ] && [ "$(wc -l < "$evfile")" -eq 1 ]; check "one line in events/<YYYY-MM>/secretary.jsonl" $?
r=$(head -1 "$evfile" 2>/dev/null)
grep -q '"seq":1,' <<<"$r" && grep -q '"kind":"ci_requested","from":"secretary"' <<<"$r" && grep -q '"pr":42,' <<<"$r" \
  && grep -q "\"sha\":\"$head\"" <<<"$r" && grep -q '"repo":"o/r"' <<<"$r"; check "ci_requested: from secretary, pr, sha and repo ($r)" $?
! grep -q ci_completed "$evfile"; check "the skill writes no ci_completed of its own" $?

# --pr before the watcher's result: exit 4, and no second request for the same head.
out=$(run_script --pr 42); rc=$?
[ "$rc" -eq 4 ] && [ "$(nreq)" -eq 1 ] && ! merged; check "--pr with the request still open exits 4 and writes no second ci_requested ($out)" $?
reset; out=$(run_script --pr 42); rc=$?
[ "$rc" -eq 4 ] && [ "$(nreq)" -eq 1 ] && ! has '^gh pr create'; check "--pr on a head with no request: no create, requests it once, exit 4" $?

# The watcher's result for the head.
watcher ci_completed --task t1
out=$(run_script --pr 42); rc=$?
[ "$rc" -eq 0 ] && ! merged && ! has '^gh pr (view|checks)' && grep -qi human <<<"$out" && grep -q 'run 777' <<<"$out"
check "--pr after the watcher's success, human mode: exit 0, the person decides, not merged ($out)" $?
run_script --pr 42 >/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ "$(nreq)" -eq 1 ]; check "rerunning --pr on a head with a result writes no second ci_requested" $?
reset; run_script "${args[@]}" >/dev/null; CODE=1 watcher ci_completed
run_script --pr 42 >/dev/null; rc=$?
[ "$rc" -eq 9 ] && ! merged; check "the watcher's failure for the head: exit 9, no merge" $?
reset; run_script "${args[@]}" >/dev/null
env -u PADDOCK_NOW -u PADDOCK_ORG_ID PADDOCK_STATE_DIR="$tmp/state" PATH="/usr/bin:/bin" bash "$here/scripts/org" --as secretary ci_completed \
  --pr 42 --sha "$head" --run-id 5 --exit-code 0 >/dev/null
run_script --pr 42 >/dev/null; rc=$?
[ "$rc" -eq 4 ]; check "an old ci_completed from secretary (the skill's former watch) does not count" $?
reset; run_script "${args[@]}" >/dev/null; watcher ci_completed --repo o/other
run_script --pr 42 >/dev/null; rc=$?
[ "$rc" -eq 4 ]; check "the watcher's result for another repository does not count" $?

# A failed watch: --pr requests the head again, once.
reset; run_script "${args[@]}" >/dev/null; REASON=gh_error watcher ci_watch_failed
out=$(run_script --pr 42); rc=$?
[ "$rc" -eq 4 ] && [ "$(nreq)" -eq 2 ] && grep -q gh_error <<<"$out"; check "after ci_watch_failed, --pr requests the head again and exits 4 ($out)" $?
run_script --pr 42 >/dev/null; rc=$?
[ "$rc" -eq 4 ] && [ "$(nreq)" -eq 2 ]; check "and a further --pr does not request it a third time" $?

# --recheck: CI rerun on the same commit after a recorded failure; the head is requested again, once.
reset; run_script "${args[@]}" >/dev/null; CODE=1 watcher ci_completed
run_script --recheck "${args[@]}" >/dev/null; rc=$?
[ "$rc" -eq 2 ]; check "--recheck without --pr exits 2" $?
out=$(run_script --pr 42 --recheck); rc=$?
[ "$rc" -eq 4 ] && [ "$(nreq)" -eq 2 ]; check "--pr --recheck after a recorded failure requests the head again, exit 4 ($out)" $?
run_script --pr 42 --recheck >/dev/null; rc=$?
[ "$rc" -eq 4 ] && [ "$(nreq)" -eq 2 ]; check "--recheck while that request is open writes no third one" $?
watcher ci_completed
run_script --pr 42 >/dev/null; rc=$?
[ "$rc" -eq 0 ]; check "the rerun's success is read for the same head" $?

# The request line cannot be written: exit 12.
reset; mkdir -p "$ev/$month"; : > "$evfile"; chmod a-w "$ev/$month" "$evfile"
run_script "${args[@]}" >/dev/null; rc=$?
chmod u+w "$ev/$month" "$evfile"
[ "$rc" -eq 12 ]; check "a ci_requested line that cannot be written exits 12 ($rc)" $?

# Approval mode (with the watcher's success recorded).
ok_head() { reset; run_script "${args[@]}" >/dev/null; watcher ci_completed; : > "$calls"; }
cfgf=$tmp/org-config.md
ok_head; printf '%s\n' 'merge_approval_mode: acceptance' > "$cfgf"
ENVX=PADDOCK_ORG_CONFIG_FILE=$cfgf run_script --pr 42 >/dev/null; rc=$?
[ "$rc" -eq 0 ] && merged; check "mode acceptance is read from org-config.md" $?
ok_head; ENVX=PADDOCK_ORG_CONFIG_FILE=$cfgf run_script --pr 42 --mode human >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ! merged; check "--mode human overrides org-config.md" $?
ok_head; printf '%s\n' 'merge_approval_mode: nonsense' > "$cfgf"
ENVX=PADDOCK_ORG_CONFIG_FILE=$cfgf run_script --pr 42 >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ! merged; check "an unknown value in org-config.md falls back to human" $?
reset; ENVX=PADDOCK_ORG_CONFIG_FILE=$cfgf run_script --mode acceptance "${args[@]}" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ! merged; check "acceptance, first run: never merges before the watcher's result" $?

# Acceptance mode.
ok_head; out=$(run_script --pr 42 --mode acceptance); rc=$?
[ "$rc" -eq 0 ]; check "acceptance, green CI, head unmoved exits 0 ($out)" $?
has "^gh pr merge 42 .*--repo o/r .*--squash .*--match-head-commit $head( |\$)"; check "merge call: gh pr merge <n> --squash --match-head-commit <sha>" $?
has '^gh pr view 42 .*headRefOid'; check "the head is read with gh pr view --json headRefOid" $?
has '^gh pr checks 42 .*--required'; check "required checks are queried with gh pr checks --required" $?
! has '--admin|--auto'; check "no --admin and no --auto" $?
ok_head; ENVX=STUB_HEAD=0000000000000000000000000000000000000000 run_script --pr 42 --mode acceptance >/dev/null; rc=$?
[ "$rc" -eq 10 ] && ! merged; check "head moved after the watched run: refuse, exit 10, no merge" $?
ok_head; ENVX=STUB_CHECKS_RC=1 run_script --pr 42 --mode acceptance >/dev/null; rc=$?
[ "$rc" -eq 10 ] && ! merged; check "required checks not green: refuse, exit 10, no merge" $?
reset; run_script "${args[@]}" >/dev/null; CODE=1 watcher ci_completed
run_script --pr 42 --mode acceptance >/dev/null; rc=$?
[ "$rc" -eq 9 ] && ! merged && ! has '^gh pr (view|checks)'; check "CI failed in acceptance mode: exit 9, no merge" $?
ok_head; ENVX=STUB_MERGE_FAIL=1 run_script --pr 42 --mode acceptance >/dev/null; rc=$?
[ "$rc" -eq 11 ]; check "merge call fails: exit 11" $?

# Other failure paths.
reset; ENVX=STUB_PR_FAIL=1 run_script "${args[@]}" >/dev/null; rc=$?
[ "$rc" -eq 6 ] && [ "$(nreq)" -eq 0 ]; check "gh pr create fails: exit 6, nothing requested" $?
reset; git -C "$wt" remote set-url origin "$tmp/missing.git"
run_script "${args[@]}" >/dev/null; rc=$?
git -C "$wt" remote set-url origin "$origin"
[ "$rc" -eq 5 ] && ! has '^gh pr create'; check "push fails: exit 5, no PR" $?
exit $fail
