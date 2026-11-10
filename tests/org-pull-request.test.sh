#!/usr/bin/env bash
# Acceptance test for skills/org-pull-request/scripts/org-pull-request.sh (stubbed hc and gh).
# Needs only bash, coreutils and git: a local bare repository stands in for origin, so
# nothing reaches GitHub and no core runs.
#
# Stub knobs (environment of the script under test):
#   STUB_RUN_AFTER=N    `gh run list` prints nothing for the first N calls, then the run id (777)
#   STUB_WATCH_CODE=N   `hc wait` reports exit_code N (default 0)
#   STUB_WAIT_RAW=text  `hc wait` prints this text instead of its JSON line
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
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
echo "hc $*" >> "$STUB/calls"
case $1 in
  run) echo '{"started":true}'; exit 0 ;;
  wait)
    if [ -n "${STUB_WAIT_RAW:-}" ]; then echo "$STUB_WAIT_RAW"; exit 0; fi
    echo "{\"children\":[],\"ended\":true,\"exit_code\":${STUB_WATCH_CODE:-0},\"reason\":\"exit\",\"signal\":null,\"status\":null,\"terminal\":\"t2d\",\"turn\":0}"
    exit 0 ;;
  connect) cat >/dev/null
    cat "$STUB/doc" 2>/dev/null || echo '{"jsonrpc":"2.0","id":1,"result":{"value":null,"version":0}}'
    exit 0 ;;
esac
exit 0
EOF2
cat > "$stubdir/gh" <<'EOF2'
#!/bin/sh
echo "gh $*" >> "$STUB/calls"
case "$1 $2" in
  "pr create") [ -z "${STUB_PR_FAIL:-}" ] || { echo 'gh: create failed' >&2; exit 1; }
    echo "https://github.com/o/r/pull/42"; exit 0 ;;
  "run list")
    n=$(cat "$STUB/runlist-n" 2>/dev/null || echo 0); echo $((n + 1)) > "$STUB/runlist-n"
    [ "$n" -ge "${STUB_RUN_AFTER:-0}" ] && echo 777
    exit 0 ;;
  "pr view") echo "${STUB_HEAD:-$(cat "$STUB/head")}"; exit 0 ;;
  "pr checks") exit "${STUB_CHECKS_RC:-0}" ;;
  "pr merge") [ -z "${STUB_MERGE_FAIL:-}" ] || { echo 'gh: merge failed' >&2; exit 1; }
    exit 0 ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc" "$stubdir/gh"

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
  env -u PADDOCK_NOW STUB="$tmp/stub" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_RUN_SLEEP=0 PADDOCK_RUN_TRIES=3 \
      PATH="$stubdir:$PATH" ${ENVX:-} bash "$script" --worktree "$wt" --repo o/r "$@" 2>&1
}
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
mkdir -p "$tmp/nohc"; ln -s "$(command -v git)" "$tmp/nohc/git"
out=$(env PATH="$tmp/nohc" "$(command -v bash)" "$script" --worktree "$wt" --repo o/r "${args[@]}" 2>&1); rc=$?
[ "$rc" -eq 3 ]; check "no hc or gh on PATH exits 3" $?

# Happy path, human mode (the default): push, create, find the run, watch, record, stop.
reset; out=$(run_script "${args[@]}"); rc=$?
[ "$rc" -eq 0 ]; check "human mode, green CI exits 0 ($out)" $?
[ "$(git -C "$origin" rev-parse refs/heads/feat/x 2>/dev/null)" = "$head" ]; check "the branch was pushed to origin" $?
has '^gh pr create .*--repo o/r' && has '^gh pr create .*--head feat/x' && has '^gh pr create .*--title feat: x' && has "^gh pr create .*--body-file $body"; check "gh pr create names the repo, head, title and body file" $?
grep -q 'https://github.com/o/r/pull/42' <<<"$out"; check "the PR URL is printed" $?
has '^hc run --bg --rm --no-notify --name ci-42 -- gh run watch 777 .*--exit-status'; check "CI is watched as a background child: hc run --bg --rm --no-notify --name ci-<pr> -- gh run watch <id> --exit-status" $?
has '^gh run watch|^gh run list .*--commit '"$head" ; check "the run id is resolved from the head sha with gh run list" $?
[ "$(line_run=$(grep -n '^hc run' "$calls" | head -1 | cut -d: -f1); line_wait=$(grep -n '^hc wait ci-42' "$calls" | head -1 | cut -d: -f1); [ -n "$line_run" ] && [ -n "$line_wait" ] && [ "$line_run" -lt "$line_wait" ] && echo yes)" = yes ]; check "hc wait ci-<pr> comes after hc run" $?
! merged && ! has '^gh pr (view|checks)'; check "human mode stops: no merge, no head or checks query" $?
grep -qi 'human' <<<"$out"; check "the output says the person decides" $?

# ci_completed line.
[ -f "$evfile" ] && [ "$(wc -l < "$evfile")" -eq 1 ]; check "one line in events/<YYYY-MM>/secretary.jsonl" $?
l=$(cat "$evfile" 2>/dev/null)
grep -q '"kind":"ci_completed"' <<<"$l" && grep -q '"seq":1[,}]' <<<"$l"; check "ci_completed line carries kind and seq 1" $?
grep -Eq '"ts":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"' <<<"$l"; check "ci_completed line carries a UTC ts" $?
grep -q '"pr":42[,}]' <<<"$l" && grep -q "\"sha\":\"$head\"" <<<"$l" && grep -q '"run_id":777[,}]' <<<"$l" && grep -q '"exit_code":0[,}]' <<<"$l"; check "ci_completed line carries pr, sha, run_id and exit_code" $?
grep -q '"conclusion":"success"' <<<"$l"; check "ci_completed line carries conclusion success for exit 0" $?
run_script "${args[@]}" >/dev/null
[ "$(wc -l < "$evfile")" -eq 2 ] && tail -1 "$evfile" | grep -q '"seq":2[,}]'; check "a second run appends with seq 2 (own file, own sequence)" $?

# Run id: retry while no run exists yet.
reset; ENVX=STUB_RUN_AFTER=2 run_script "${args[@]}" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c '^gh run list' "$calls")" -eq 3 ]; check "run id found on the third try after two empty answers" $?
reset; ENVX=STUB_RUN_AFTER=99 run_script "${args[@]}" >/dev/null; rc=$?
[ "$rc" -eq 7 ] && [ "$(grep -c '^gh run list' "$calls")" -eq 3 ] && ! has '^hc run' && [ ! -e "$evfile" ]; check "no run after PADDOCK_RUN_TRIES exits 7, starts no watcher, records nothing" $?

# hc wait JSON parse.
reset; ENVX=STUB_WATCH_CODE=1 run_script "${args[@]}" >/dev/null; rc=$?
[ "$rc" -eq 9 ]; check "CI failure (exit_code 1) exits 9" $?
grep -q '"exit_code":1[,}]' "$evfile" && grep -q '"conclusion":"failure"' "$evfile"; check "a failed run is recorded too (exit_code 1, failure)" $?
reset; ENVX='STUB_WAIT_RAW={"ended":true,"exit_code":null,"reason":"signal","signal":9}' run_script "${args[@]}" >/dev/null; rc=$?
[ "$rc" -eq 8 ] && [ ! -e "$evfile" ]; check "a wait without an integer exit_code exits 8 and records nothing" $?
reset; ENVX=STUB_WAIT_RAW=garbage run_script "${args[@]}" >/dev/null; rc=$?
[ "$rc" -eq 8 ]; check "unparseable wait output exits 8" $?
reset; ENVX='STUB_WAIT_RAW={"children":[],"ended":true,"exit_code":0,"reason":"exit","signal":null,"status":null,"terminal":"t2d","turn":0}' run_script "${args[@]}" >/dev/null; rc=$?
[ "$rc" -eq 0 ]; check "the measured MON-12 output line parses" $?

# Approval mode.
reset; printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"value":{"work":[],"approvals":[],"merge_approval_mode":"acceptance"},"version":4}}' > "$tmp/stub/doc"
run_script "${args[@]}" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && merged; check "mode acceptance is read from the org-state document" $?
reset; printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"value":{"merge_approval_mode":"acceptance"},"version":4}}' > "$tmp/stub/doc"
run_script --mode human "${args[@]}" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ! merged; check "--mode human overrides the org-state document" $?
reset; printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"value":{"merge_approval_mode":"nonsense"},"version":4}}' > "$tmp/stub/doc"
run_script "${args[@]}" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ! merged; check "an unknown value in org-state falls back to human" $?

# Acceptance mode.
reset; out=$(run_script --mode acceptance "${args[@]}"); rc=$?
[ "$rc" -eq 0 ]; check "acceptance, green CI, head unmoved exits 0 ($out)" $?
has "^gh pr merge 42 .*--repo o/r .*--squash .*--match-head-commit $head( |\$)"; check "merge call: gh pr merge <n> --squash --match-head-commit <sha>" $?
has '^gh pr view 42 .*headRefOid'; check "the head is read with gh pr view --json headRefOid" $?
has '^gh pr checks 42 .*--required'; check "required checks are queried with gh pr checks --required" $?
! has '--admin|--auto'; check "no --admin and no --auto" $?
reset; ENVX=STUB_HEAD=0000000000000000000000000000000000000000 run_script --mode acceptance "${args[@]}" >/dev/null; rc=$?
[ "$rc" -eq 10 ] && ! merged; check "head moved after the watched run: refuse, exit 10, no merge" $?
reset; ENVX=STUB_CHECKS_RC=1 run_script --mode acceptance "${args[@]}" >/dev/null; rc=$?
[ "$rc" -eq 10 ] && ! merged; check "required checks not green: refuse, exit 10, no merge" $?
reset; ENVX=STUB_WATCH_CODE=1 run_script --mode acceptance "${args[@]}" >/dev/null; rc=$?
[ "$rc" -eq 9 ] && ! merged && ! has '^gh pr (view|checks)'; check "CI failed in acceptance mode: exit 9, no merge" $?
reset; ENVX=STUB_MERGE_FAIL=1 run_script --mode acceptance "${args[@]}" >/dev/null; rc=$?
[ "$rc" -eq 11 ]; check "merge call fails: exit 11" $?

# Other failure and reuse paths.
reset; ENVX=STUB_PR_FAIL=1 run_script "${args[@]}" >/dev/null; rc=$?
[ "$rc" -eq 6 ] && ! has '^hc run'; check "gh pr create fails: exit 6, no watcher" $?
reset; run_script --pr 42 >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ! has '^gh pr create' && has '^hc run .*--name ci-42'; check "--pr 42 reuses an open PR: no create, same watch" $?
reset; git -C "$wt" remote set-url origin "$tmp/missing.git"
run_script "${args[@]}" >/dev/null; rc=$?
git -C "$wt" remote set-url origin "$origin"
[ "$rc" -eq 5 ] && ! has '^gh pr create'; check "push fails: exit 5, no PR" $?
exit $fail
