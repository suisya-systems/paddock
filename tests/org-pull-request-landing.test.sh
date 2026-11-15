#!/usr/bin/env bash
# Decision 0014, wave 2 unit 5: org-pull-request. A landing places the changed files again in BOTH
# approval modes (the secretary no longer remembers it), every exit prints one `next:` line, the
# SKILL.md has the 0014 form, and template section "Pull request" is emptied into the skills.
# A copy of the checkout is the "paddock folder", a git worktree of it is the worker's, a bare
# repository is origin, and gh and org-start.sh are stubs, so nothing reaches GitHub or a core.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# The paddock folder: only what the script reads, plus a stub org-start.sh that records its call.
root=$tmp/paddock
mkdir -p "$root/skills/org-pull-request" "$root/skills/org-delegate" "$root/skills/org-start/scripts" "$root/scripts"
cp -R "$here/skills/org-pull-request/." "$root/skills/org-pull-request/"
cp -R "$here/skills/org-delegate/scripts" "$root/skills/org-delegate/"
cp "$here/scripts/org" "$root/scripts/org"
cat > "$root/skills/org-start/scripts/org-start.sh" <<'EOF2'
#!/bin/sh
echo "org-start $*" >> "$STUB/calls"
[ -z "${STUB_START_OUT:-}" ] || echo "$STUB_START_OUT"
exit "${STUB_START_RC:-0}"
EOF2
git init -q -b main "$root"; git -C "$root" add -A; git -C "$root" commit -qm init
script=$root/skills/org-pull-request/scripts/org-pull-request.sh

stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/gh" <<'EOF2'
#!/bin/sh
echo "gh $*" >> "$STUB/calls"
case "$1 $2" in
  "pr create") [ -z "${STUB_CREATE_FAIL:-}" ] || exit 1; echo "https://github.com/o/r/pull/42" ;;
  "pr view") case "$*" in
      *state*) echo "${STUB_STATE:-OPEN}" ;;
      *baseRefName*) echo "${STUB_BASE:-main}" ;;
      *) echo "$(cat "$STUB/head")" ;;
    esac ;;
  "pr checks") exit "${STUB_CHECKS_RC:-0}" ;;
  "pr merge") [ -z "${STUB_MERGE_FAIL:-}" ] || exit 1 ;;
esac
exit 0
EOF2
chmod +x "$stubdir/gh"

origin=$tmp/origin.git; git init -q --bare "$origin"
wt=$tmp/wt; git -C "$root" worktree add -q -b feat/x "$wt"       # shares the paddock folder's git store
git -C "$wt" remote add origin "$origin"
git -C "$wt" commit -q --allow-empty -m one
head=$(git -C "$wt" rev-parse HEAD)
alien=$tmp/alien; git clone -q "$origin" "$alien" 2>/dev/null     # a worktree of some other repository
git -C "$alien" checkout -q -b feat/y; git -C "$alien" commit -q --allow-empty -m one
git -C "$alien" push -q origin feat/y 2>/dev/null

calls=$tmp/stub/calls; ev=$tmp/state/events
reset() { rm -rf "$tmp/stub" "$ev"; mkdir -p "$tmp/stub" "$ev"; : > "$calls"; printf '%s\n' "$head" > "$tmp/stub/head"; }
run() { # run [args]; ENVX = extra env; W = worktree (default wt)
  env -u PADDOCK_NOW STUB="$tmp/stub" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_ORG_CONFIG_FILE="$tmp/none.md" \
      PATH="$stubdir:$PATH" ${ENVX:-} bash "$script" --worktree "${W:-$wt}" --repo o/r "$@" 2>&1; }
watcher() { env -u PADDOCK_NOW -u PADDOCK_ORG_ID PADDOCK_STATE_DIR="$tmp/state" PATH="/usr/bin:/bin" bash "$root/scripts/org" --as watcher \
  ci_completed --run-id 777 --exit-code "${CODE:-0}" --pr 42 --sha "$head" --repo o/r >/dev/null; }
has() { grep -Eq -- "$1" "$calls"; }
nexts() { grep -c '^next: ' <<<"$1"; }
body=$tmp/body.md; printf 'Body\n' > "$body"
first=(--title "feat: x" --body-file "$body")

# Landing places in human mode: the person merged by hand; the rerun sees the PR is merged.
reset; run "${first[@]}" >/dev/null; : > "$calls"
out=$(ENVX="STUB_STATE=MERGED" run --pr 42 --mode human); rc=$?
[ "$rc" -eq 0 ]; check "human, PR already merged: exit 0 ($out)" $?
has '^org-start --place-only --from-origin main$'; check "human, merged: placed again from origin/main" $?
! has '^gh pr merge'; check "human, merged: the script merges nothing" $?
[ "$(nexts "$out")" -eq 1 ]; check "human, merged: exactly one next: line" $?
reset; run "${first[@]}" >/dev/null; : > "$calls"
ENVX="STUB_STATE=MERGED STUB_BASE=release" run --pr 42 --mode human >/dev/null
has '^org-start --place-only --from-origin release$'; check "merged: the base is the one the PR landed on" $?
reset; run "${first[@]}" >/dev/null; : > "$calls"
out=$(ENVX="STUB_STATE=MERGED STUB_START_RC=1" run --pr 42 --mode human); rc=$?
[ "$rc" -eq 13 ] && grep -q '^next: .*org-start.sh --place-only --from-origin main' <<<"$out"; check "merged, placing fails: exit 13 and next: names the command ($out)" $?
reset; run "${first[@]}" >/dev/null; : > "$calls"
out=$(ENVX="STUB_STATE=MERGED STUB_START_OUT=org-start:RENEWAL-NEEDED" run --pr 42 --mode human)
grep -q 'RENEWAL-NEEDED' <<<"$out" && [ "$(nexts "$out")" -ge 1 ]; check "merged: org-start's own lines are shown, next: follows" $?
reset; run "${first[@]}" >/dev/null; : > "$calls"
ENVX="STUB_STATE=MERGED" W=$alien run --pr 42 --mode human >/dev/null
! has '^org-start'; check "merged in another repository: nothing is placed" $?
reset; run "${first[@]}" >/dev/null; : > "$calls"; watcher
out=$(run --pr 42 --mode human); rc=$?
[ "$rc" -eq 0 ] && ! has '^org-start' && ! has '^gh pr merge'; check "human, open PR, CI green: nothing placed, not merged" $?
[ "$(nexts "$out")" -eq 1 ]; check "human, CI green: one next: line (tell the person, wait)" $?
reset; run "${first[@]}" >/dev/null; : > "$calls"; watcher
out=$(run --pr 42 --mode acceptance); rc=$?
[ "$rc" -eq 0 ] && has '^org-start --place-only --from-origin main$'; check "acceptance: still placed after its own merge" $?
reset; run "${first[@]}" >/dev/null; : > "$calls"; watcher
out=$(ENVX=STUB_START_RC=1 run --pr 42 --mode acceptance); rc=$?
[ "$rc" -eq 13 ]; check "acceptance, placing fails: exit 13 still" $?

# next: on every exit.
reset; out=$(run "${first[@]}"); rc=$?
[ "$rc" -eq 0 ] && [ "$(nexts "$out")" -eq 1 ] && grep -q '^next: .*--pr' <<<"$out"; check "first run exit 0: next: says to rerun with --pr on the watcher's line" $?
out=$(run --pr 42 --mode human); rc=$?
[ "$rc" -eq 4 ] && [ "$(nexts "$out")" -eq 1 ]; check "exit 4: one next: line" $?
reset; out=$(run --mode sometimes "${first[@]}"); rc=$?
[ "$rc" -eq 2 ] && [ "$(nexts "$out")" -eq 1 ]; check "exit 2: one next: line" $?
mkdir -p "$tmp/nohc"; ln -sf "$(command -v git)" "$tmp/nohc/git"
reset; out=$(env -u PADDOCK_NOW STUB="$tmp/stub" PADDOCK_STATE_DIR="$tmp/state" PATH="$tmp/nohc" /bin/bash "$script" --worktree "$wt" --repo o/r --pr 42 2>&1); rc=$?
[ "$rc" -eq 3 ] && [ "$(nexts "$out")" -eq 1 ]; check "exit 3: one next: line" $?
reset; git -C "$wt" remote set-url origin "$tmp/missing.git"; out=$(run "${first[@]}"); rc=$?; git -C "$wt" remote set-url origin "$origin"
[ "$rc" -eq 5 ] && [ "$(nexts "$out")" -eq 1 ]; check "exit 5: one next: line" $?
reset; out=$(ENVX=STUB_CREATE_FAIL=1 run "${first[@]}"); rc=$?
[ "$rc" -eq 6 ] && [ "$(nexts "$out")" -eq 1 ]; check "exit 6: one next: line" $?
reset; run "${first[@]}" >/dev/null; CODE=1 watcher
out=$(run --pr 42 --mode human); rc=$?
[ "$rc" -eq 9 ] && [ "$(nexts "$out")" -eq 1 ]; check "exit 9: one next: line" $?
reset; run "${first[@]}" >/dev/null; watcher
out=$(ENVX=STUB_CHECKS_RC=1 run --pr 42 --mode acceptance); rc=$?
[ "$rc" -eq 10 ] && [ "$(nexts "$out")" -eq 1 ]; check "exit 10: one next: line" $?
reset; run "${first[@]}" >/dev/null; watcher
out=$(ENVX=STUB_MERGE_FAIL=1 run --pr 42 --mode acceptance); rc=$?
[ "$rc" -eq 11 ] && [ "$(nexts "$out")" -eq 1 ]; check "exit 11: one next: line" $?
reset; run "${first[@]}" >/dev/null
out=$(ENVX="PADDOCK_STATE_DIR=/dev/null/x" run --pr 42 --mode human); rc=$?
[ "$rc" -eq 12 ] && [ "$(nexts "$out")" -eq 1 ]; check "exit 12: one next: line" $?
reset; run "${first[@]}" >/dev/null; watcher
out=$(ENVX=STUB_MERGE_FAIL=1 run --pr 42 --mode acceptance); [ "$(nexts "$out")" -eq 1 ] && ! grep -q 'next: .*\bpr merge' <<<"$out"; check "a failed merge never tells the secretary to merge by hand" $?

# SKILL.md: the 0014 form.
sk=$here/skills/org-pull-request/SKILL.md
fm=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$sk")
grep -Eq '^when_to_use:[[:space:]]*[^[:space:]]' <<<"$fm"; check "SKILL.md has when_to_use" $?
[ "$(sed -n 's/^name: *//p' <<<"$fm")" = org-pull-request ]; check "SKILL.md name equals the folder" $?
[ "$(printf '%s' "$fm" | grep -E '^(description|when_to_use):' | wc -c)" -lt 1536 ]; check "description + when_to_use under 1,536 characters" $?
[ "$(wc -c < "$sk")" -lt 12288 ]; check "SKILL.md under 12 KB" $?
grep -q '^allowed-tools:.*org-pull-request.sh' <<<"$fm"; check "SKILL.md allowed-tools names the skill's own script" $?
! grep -qE '^\| (Code|[0-9]+) \|' "$sk"; check "no exit-code table in SKILL.md (the script's next: lines say it)" $?
grep -q 'next:' "$sk"; check "SKILL.md points at the next: lines" $?
grep -F 'gh pr checks --watch' "$sk" | grep -qE '[Nn]ever'; check "SKILL.md keeps: never watch CI by hand" $?
grep -qF 'CODEX_GATE: passed' "$sk" && grep -E 'did not run' "$sk" | grep -qE 'report'; check "SKILL.md keeps the gate-line rule (PR body and report)" $?
grep -F 'ci_completed' "$sk" | grep -qF 'local test run'; check "SKILL.md keeps: quote the watcher's CI line, not a local run" $?

# The template's "Pull request" section is emptied into the skills.
sec=$here/templates/secretary.md
! grep -qE 'org-pull-request\.sh|org-update-branch\.sh|ci_requested|--match-head-commit' "$sec" "$here/templates/secretary-rules.md"; check "template: no script call or CI record detail for pull requests" $?
grep -q 'paddock:org-pull-request' "$sec"; check "template: names the skill paddock:org-pull-request" $?
exit $fail
