#!/usr/bin/env bash
# Acceptance test for scripts/acceptance-check.sh, the CI job that replaces the
# predecessor's acceptance gate (Issue #115, Q11 decided (d)). Needs bash and git only:
# each case builds a scratch repository with a base, a test commit and a fix.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
script=$here/scripts/acceptance-check.sh
n=0

# new_repo: a base commit with code (lib.sh answers 1), a workflow and a test helper.
new_repo() {
  n=$((n + 1)); r=$tmp/r$n; mkdir -p "$r"
  git -C "$r" init -q -b main
  mkdir -p "$r/.github/workflows" "$r/tests"
  echo 'answer() { echo 1; }' > "$r/lib.sh"
  echo 'name: CI' > "$r/.github/workflows/ci.yml"
  echo '# helper' > "$r/tests/hc-stub.sh"
  g add -A; g commit -q -m base
  base=$(git -C "$r" rev-parse HEAD)
  g checkout -q -b feat/x
}
g() { git -C "$r" -c user.name=t -c user.email=t@t "$@"; }
# add_test <path>: a test that passes only once lib.sh answers 2
add_test() { mkdir -p "$r/$(dirname "$1")"; printf '%s\n' '. ./lib.sh' '[ "$(answer)" = 2 ]' > "$r/$1"; }
fix() { echo 'answer() { echo 2; }' > "$r/lib.sh"; g commit -q -am fix; }
# test_commit <trailer-paths...>: commit what is staged with one trailer line per path
test_commit() {
  msg="test: declare"$'\n\n'
  for p in "$@"; do msg+="Acceptance-Test: $p"$'\n'; done
  msg+="Co-Authored-By: t <t@t>"
  g commit -q -m "$msg"
}
run() { out=$(cd "$r" && bash "$script" "$base" "$(git -C "$r" rev-parse HEAD)" 2>&1); rc=$?; }
last() { printf '%s\n' "$out" | tail -1; }

[ -f "$script" ]; check "scripts/acceptance-check.sh exists" $?
(cd "$tmp" && bash "$script" >/dev/null 2>&1); rc=$?
[ "$rc" -eq 2 ]; check "no arguments exits 2" $?

new_repo; add_test tests/new.test.sh; g add tests/new.test.sh; test_commit tests/new.test.sh; fix; run
[ "$rc" -eq 0 ] && [ "$(last)" = "ACCEPTANCE: pass" ]; check "declared test fails at the test commit and passes at head: pass ($out)" $?

new_repo; fix; run
[ "$rc" -eq 0 ] && [ "$(last)" = "ACCEPTANCE: none" ]; check "no Acceptance-Test trailer: exit 0, ACCEPTANCE: none ($out)" $?

new_repo; add_test tests/new.test.sh; g add tests/new.test.sh
g commit -q -m "test: declare"$'\n\n'"Acceptance-Test: tests/new.test.sh"$'\n\n'"Co-Authored-By: t <t@t>"; fix; run
[ "$rc" -eq 0 ] && [ "$(last)" = "ACCEPTANCE: none" ]; check "a declaration split from the trailer block by a blank line is not a trailer: none" $?

new_repo; echo 'answer() { echo 2; }' > "$r/lib.sh"; g commit -q -am early
base=$(git -C "$r" rev-parse HEAD)
add_test tests/new.test.sh; g add tests/new.test.sh; test_commit tests/new.test.sh; g commit -q --allow-empty -m noop; run
[ "$rc" -eq 1 ] && [ "$(last)" = "ACCEPTANCE: fail" ]; check "declared test already passes at the test commit: fail" $?

new_repo; add_test tests/new.test.sh; g add tests/new.test.sh; test_commit tests/new.test.sh; g commit -q --allow-empty -m nofix; run
[ "$rc" -eq 1 ] && [ "$(last)" = "ACCEPTANCE: fail" ]; check "declared test still fails at head: fail" $?

new_repo; add_test tests/new.test.sh; g add tests/new.test.sh; test_commit tests/new.test.sh; fix
echo 'true' > "$r/tests/new.test.sh"; g commit -q -am weaken; run
[ "$rc" -eq 1 ] && grep -q 'tests/new.test.sh' <<<"$out"; check "declared test changed after the test commit: fail, names the file" $?

new_repo; add_test tests/new.test.sh; g add tests/new.test.sh; test_commit tests/new.test.sh; fix
echo 'name: other' > "$r/.github/workflows/ci.yml"; g commit -q -am ci; run
[ "$rc" -eq 1 ] && grep -q '.github/workflows/ci.yml' <<<"$out"; check "workflow changed after the test commit: fail" $?

new_repo; add_test tests/new.test.sh; g add tests/new.test.sh; test_commit tests/new.test.sh; fix
echo '# changed' > "$r/tests/hc-stub.sh"; g commit -q -am helper; run
[ "$rc" -eq 1 ] && grep -q 'tests/hc-stub.sh' <<<"$out"; check "test helper (tests/ file that is not a *.test.sh) changed after the test commit: fail" $?

new_repo; add_test tests/new.test.sh; echo 'answer() { echo 2; }' > "$r/lib.sh"; g add tests/new.test.sh lib.sh
test_commit tests/new.test.sh; run
[ "$rc" -eq 1 ] && grep -q 'lib.sh' <<<"$out"; check "test commit also changes code: fail, names the file" $?

new_repo; g commit -q --allow-empty -m first; add_test tests/new.test.sh; g add tests/new.test.sh; test_commit tests/new.test.sh; fix; run
[ "$rc" -eq 1 ]; check "declaration on a commit that is not the first: fail" $?

new_repo; add_test tests/new.test.sh; g add tests/new.test.sh; test_commit tests/new.test.sh tests/missing.test.sh; fix; run
[ "$rc" -eq 1 ] && grep -q 'tests/missing.test.sh' <<<"$out"; check "declared path that does not exist: fail" $?

new_repo; add_test tests/acc/a.test.sh; add_test tests/acc/b.test.sh; echo 'fixture' > "$r/tests/acc/data.txt"
g add tests/acc; test_commit tests/acc; fix; run
[ "$rc" -eq 0 ] && [ "$(last)" = "ACCEPTANCE: pass" ]; check "declared directory: every *.test.sh in it runs, other files are fixtures ($out)" $?

new_repo; echo 'fixture' > "$r/tests/data.txt"; g add tests/data.txt; test_commit tests/data.txt; fix; run
[ "$rc" -eq 1 ]; check "declaration with no *.test.sh to run: fail" $?

new_repo; add_test tests/new.test.sh; g add tests/new.test.sh; test_commit tests/new.test.sh; fix
add_test tests/later.test.sh; g add tests/later.test.sh; g commit -q -m "more tests"; run
[ "$rc" -eq 0 ]; check "a new *.test.sh added after the test commit is allowed" $?

# Renames count as both paths (Codex review).
new_repo; add_test tests/new.test.sh; g add tests/new.test.sh; test_commit tests/new.test.sh; fix
g mv tests/hc-stub.sh helper.sh; g commit -q -m "move helper"; run
[ "$rc" -eq 1 ] && grep -q "tests/hc-stub.sh changed after" <<<"$out"; check "a test helper renamed out of tests/ after the test commit: fail" $?
new_repo; add_test tests/new.test.sh; mkdir -p "$r/tests/new"; g mv lib.sh tests/new/lib.sh; g add tests/new.test.sh
test_commit tests/new.test.sh tests/new; run
[ "$rc" -eq 1 ] && grep -q "test commit changes lib.sh" <<<"$out"; check "code renamed into a declared path in the test commit: fail" $?

# Base merged into the branch (no force push: the branch takes main by a merge).
main_commit() { g checkout -q main; echo "$2" > "$r/$1"; g add "$1"; g commit -q -m "main: $1"; base=$(git -C "$r" rev-parse HEAD); g checkout -q feat/x; }
new_repo; add_test tests/new.test.sh; g add tests/new.test.sh; test_commit tests/new.test.sh; fix
main_commit other.txt x; main_commit .github/workflows/ci.yml "name: CI2"; main_commit tests/hc-stub.sh "# helper 2"
g merge -q --no-ff -m "merge main" main; run
[ "$rc" -eq 0 ] && [ "$(last)" = "ACCEPTANCE: pass" ]; check "main merged after the test commit, bringing workflow and helper changes from main: pass ($out)" $?
new_repo; main_commit other.txt x; g merge -q --no-ff -m "merge main" main
add_test tests/new.test.sh; g add tests/new.test.sh; test_commit tests/new.test.sh; fix; run
[ "$rc" -eq 1 ]; check "a merge before the test commit (join commit first): fail" $?
new_repo; add_test tests/new.test.sh; g add tests/new.test.sh; test_commit tests/new.test.sh; fix
main_commit other.txt x; g merge -q --no-ff --no-commit main; echo "# own" > "$r/tests/hc-stub.sh"; g add tests/hc-stub.sh; g commit -q -m "merge main"; run
[ "$rc" -eq 1 ] && grep -q tests/hc-stub.sh <<<"$out"; check "a merge that changes a protected path beyond what main brought: fail" $?

new_repo; add_test tests/new.test.sh; g add tests/new.test.sh; test_commit tests/new.test.sh; fix
g checkout -q -b side; echo true > "$r/tests/new.test.sh"; g commit -q -am weaken; g checkout -q feat/x
g merge -q --no-ff -m "merge side" side; run
[ "$rc" -eq 1 ] && grep -q "not in the base" <<<"$out"; check "a merge of a branch that is not the base after the test commit: fail" $?

wf=$here/.github/workflows/ci.yml
grep -q '^  acceptance:' "$wf" && grep -q 'scripts/acceptance-check.sh' "$wf" && grep -q 'fetch-depth: 0' "$wf"
check "CI has an acceptance job that runs scripts/acceptance-check.sh on full history" $?
exit $fail
