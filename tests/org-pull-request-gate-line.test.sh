#!/usr/bin/env bash
# Issue #300: org-pull-request reads the task's codex-gate history and, when the last diff round did
# not end in codex_round_passed (or there is none), adds "Second-model review did not run" and that
# record to the PR body itself, so a body file written without it still carries it. Stubbed hc and gh;
# the history is written by the real `org --as codex-gate codex_round result`.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
script=$here/skills/org-pull-request/scripts/org-pull-request.sh
org=$here/scripts/org
stubdir=$tmp/bin; mkdir -p "$stubdir" "$tmp/stub"
printf '%s\n' '#!/bin/sh' 'case $1 in wait) echo "{\"ended\":true,\"exit_code\":0,\"signal\":null}" ;; esac' > "$stubdir/hc"
cat > "$stubdir/gh" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "pr create") while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" "$STUB/prbody"; [ "$1" = --body ] && printf '%s\n' "$2" > "$STUB/prbody"; shift; done
    echo https://github.com/o/r/pull/42 ;;
  "run list") echo 777 ;;
  "pr view") cat "$STUB/head" ;;
esac
STUB
chmod +x "$stubdir/hc" "$stubdir/gh"
git init -q --bare "$tmp/origin.git"; git clone -q "$tmp/origin.git" "$tmp/wt" 2>/dev/null
git -C "$tmp/wt" checkout -q -b feat/x; git -C "$tmp/wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
git -C "$tmp/wt" rev-parse HEAD > "$tmp/stub/head"
printf 'Body text\n' > "$tmp/body.md"
withenv() { env -u PADDOCK_NOW -u PADDOCK_ORG_ID PADDOCK_STATE_DIR="$tmp/st" PADDOCK_CODEX_DIR="$tmp/rounds" "$@"; }
gate() { withenv bash "$org" --as codex-gate codex_round result --task "$@" >/dev/null; } # gate <task> [--design] <line>
pr() { # pr <task>: the body the PR got
  rm -f "$tmp/stub/prbody"
  withenv STUB="$tmp/stub" PADDOCK_RUN_SLEEP=0 PATH="$stubdir:$PATH" \
    bash "$script" --worktree "$tmp/wt" --repo o/r --title t --body-file "$tmp/body.md" --task-id "$1" >/dev/null 2>&1
  cat "$tmp/stub/prbody"
}

gate failed1 'CODEX_GATE: unavailable (codex not found)'
b=$(pr failed1)
grep -q 'Body text' <<<"$b" && grep -q 'Second-model review did not run' <<<"$b" \
  && grep -q 'CODEX_GATE: unavailable (codex not found)' <<<"$b"; check "a failed record: the body keeps its text and says the review did not run, with the gate line" $?

b=$(pr nothing1)
grep -q 'Body text' <<<"$b" && grep -q 'Second-model review did not run' <<<"$b"; check "no record: the body says the review did not run" $?

gate ok1 'CODEX_GATE: passed (succeeded=2 failed=0)'
b=$(pr ok1)
grep -q 'Body text' <<<"$b" && ! grep -q 'did not run' <<<"$b"; check "a passed record: the body is left as written" $?

gate late1 'CODEX_GATE: not-established (empty pass)'
gate late1 'CODEX_GATE: passed (succeeded=2 failed=0)'
b=$(pr late1); ! grep -q 'did not run' <<<"$b"; check "the latest record counts: failed then passed is passed" $?
gate late2 'CODEX_GATE: passed (succeeded=2 failed=0)'
gate late2 'CODEX_GATE: dirty-worktree'
b=$(pr late2); grep -q 'CODEX_GATE: dirty-worktree' <<<"$b" && ! grep -q 'succeeded=2' <<<"$b"; check "passed then failed is failed, and the latest line is quoted" $?

gate des1 --design 'CODEX_GATE: passed (succeeded=1 failed=0)'
b=$(pr des1); grep -q 'did not run' <<<"$b"; check "a passed design review alone is not a passed diff review" $?
exit $fail
