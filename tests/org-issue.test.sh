#!/usr/bin/env bash
# Acceptance test for skills/org-issue/scripts/org-issue.sh (Issue #72), with a stubbed `gh`.
# Needs only bash and coreutils. Nothing reaches GitHub: the stub only logs its calls.
#
# Stub knobs (environment of the script under test):
#   STUB_MISSING="7 9"   `gh issue view N` fails for these numbers
#   STUB_CREATE_FAIL=1   `gh issue create` fails
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
script=$here/skills/org-issue/scripts/org-issue.sh
template=$here/.github/ISSUE_TEMPLATE/issue.md

stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/gh" <<'EOF2'
#!/bin/sh
echo "gh $*" >> "$STUB/calls"
case "$1 $2" in
  "issue view")
    for m in ${STUB_MISSING:-}; do [ "$m" != "$3" ] || { echo 'not found' >&2; exit 1; }; done
    exit 0 ;;
  "issue create")
    [ -z "${STUB_CREATE_FAIL:-}" ] || { echo 'gh: create failed' >&2; exit 1; }
    while [ $# -gt 0 ]; do
      [ "$1" != "--body-file" ] || cp "$2" "$STUB/body"
      [ "$1" != "--title" ] || echo "$2" > "$STUB/title"
      shift
    done
    echo "https://github.com/o/r/issues/99"; exit 0 ;;
esac
exit 0
EOF2
chmod +x "$stubdir/gh"

# run <args...>: fresh stub state, the script with the stub gh first on PATH. Sets rc, out.
run() {
  export STUB=$tmp/stub; rm -rf "$STUB"; mkdir -p "$STUB"
  out=$(PATH="$stubdir:$PATH" bash "$script" "$@" 2>&1); rc=$?
}
created() { grep -q '^gh issue create' "$STUB/calls" 2>/dev/null; }

decide=(--repo o/r --kind decide --title "Q?" --goal "G1 Start a worker" --question "Which?"
        --known "A fact (source)." --options "A or B." --done "Decided.")
build=(--repo o/r --kind build --title "Build it" --goal "G2 Permissions" --why "Because." --done "Works.")
follow=(--repo o/r --kind followup --title "Saw it" --goal "G3 Approvals" --seen "A thing." --ask "Look at it.")

# 1. A build with two dependencies: one Depends line, the last line, refs on the same line.
STUB_MISSING= run "${build[@]}" --depends 60 --depends 61
check "build with dependencies exits 0" $((rc != 0))
created; check "build opens the issue" $?
[ "$(tail -n 1 "$STUB/body")" = "Depends on #60 #61" ]; check "Depends line is the last line, one line" $?
[ "$(grep -c '^Depends on' "$STUB/body")" -eq 1 ]; check "exactly one Depends line" $?
grep -q -F -x -- '- G2 Permissions' "$STUB/body"; check "goal clause is one list line" $?
[ "$(cat "$STUB/title")" = "Build it" ]; check "title passed through" $?
case $out in *issues/99*) true ;; *) false ;; esac; check "prints the issue URL" $?

# 2. No dependency: no Depends line at all.
run "${build[@]}"
check "no dependency exits 0" $((rc != 0))
! grep -q 'Depends on' "$STUB/body"; check "no Depends line without dependencies" $?

# 3. Section names and order per kind.
headings() { grep '^## ' "$STUB/body" | tr '\n' '|'; }
run "${decide[@]}"
[ "$(headings)" = "## Question|## What we know (with sources)|## Options|## Definition of done|## Goal clause|" ]; check "decide sections" $?
run "${build[@]}"
[ "$(headings)" = "## Why|## Definition of done|## Goal clause|" ]; check "build sections" $?
run "${follow[@]}"
[ "$(headings)" = "## What was seen|## Ask|## Goal clause|" ]; check "followup sections" $?

# 4. A missing required section creates nothing and exits non-zero.
run --repo o/r --kind build --title t --goal "G2 x" --done "d"
[ "$rc" -ne 0 ]; check "build without Why exits non-zero" $?
! created; check "build without Why creates nothing" $?
run --repo o/r --kind decide --title t --goal "G1 x" --question q --known k --done d
[ "$rc" -ne 0 ] && ! created; check "decide without Options creates nothing" $?
run --repo o/r --kind followup --title t --goal "G3 x" --seen s
[ "$rc" -ne 0 ] && ! created; check "followup without Ask creates nothing" $?
run --repo o/r --kind build --title t --why w --done d
[ "$rc" -ne 0 ] && ! created; check "missing goal clause creates nothing" $?
run --kind build --title t --goal "G2 x" --why w --done d
[ "$rc" -ne 0 ] && ! created; check "missing --repo creates nothing" $?
run --repo o/r --kind other --title t --goal "G2 x" --why w --done d
[ "$rc" -ne 0 ] && ! created; check "unknown kind creates nothing" $?

# 5. A section of another kind is refused.
run "${build[@]}" --ask "not a build section"
[ "$rc" -ne 0 ] && ! created; check "section of another kind is refused" $?

# 6. Dependencies: duplicate, not a number, not found.
run "${build[@]}" --depends 60 --depends 60
[ "$rc" -ne 0 ] && ! created; check "duplicate dependency is refused" $?
run "${build[@]}" --depends abc
[ "$rc" -ne 0 ] && ! created; check "non-numeric dependency is refused" $?
STUB_MISSING="7" run "${build[@]}" --depends 7
[ "$rc" -ne 0 ] && ! created; check "dependency that does not exist is refused" $?

# 7. gh fails to create: non-zero.
STUB_CREATE_FAIL=1 run "${build[@]}"
[ "$rc" -ne 0 ]; check "create failure exits non-zero" $?

# 8. The template carries every heading the tool writes.
for h in "Question" "What we know (with sources)" "Options" "Why" "What was seen" "Ask" "Definition of done" "Goal clause"; do
  grep -q -x -- "## $h" "$template"; check "template has '## $h'" $?
done
grep -q -x 'Depends on #N' "$template"; check "template has the Depends on #N line" $?

exit $fail
