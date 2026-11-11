#!/usr/bin/env bash
# Acceptance test for the review by a second model (Issue #177, inventory L-K10, GT-2): a worker
# asks for a design review or a diff review through scripts/second-model-review.sh, the gate that
# PADDOCK_CODEX_GATE names (the round counter and its hook, Issue #225, count each call). The gate
# prints a last line CODEX_GATE: passed | not-established | unavailable | dirty-worktree and refuses
# an "empty pass" (a review that ran no command, or looked at nothing). org-start places the gate
# where workers cannot write it, the worker template names it, the worker rules say when to ask.
# Needs bash, git and coreutils; the reviewing CLI is replaced by a stub on PATH.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
gate=$here/scripts/second-model-review.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

[ -f "$gate" ]; check "the gate script exists" $?
bash -n "$gate" 2>/dev/null; check "the gate script parses" $?

# --- a fixture: a repository whose origin/main is one commit behind HEAD ---
repo=$tmp/repo; mkdir -p "$repo"
(
  cd "$repo" && git init -q -b main . \
    && git config user.email t@example.com && git config user.name t \
    && echo one > a.txt && git add a.txt && git commit -q -m one \
    && git update-ref refs/remotes/origin/main HEAD \
    && echo two >> a.txt && git commit -q -am two
) >/dev/null 2>&1; check "fixture repository is built" $?

# --- the stub reviewer: STUB_MODE picks what it prints; every call is logged ---
stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/codex" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
case "${STUB_MODE:-ran}" in
  ran)    echo "exec"; echo "git diff in /w"; echo " succeeded in 12ms:"; echo "Findings: none"; exit 0 ;;
  empty)  echo "Findings: none"; exit 0 ;;
  failed) echo " succeeded in 3ms:"; echo " failed in 4ms:"; exit 0 ;;
  bad)    echo " succeeded in 3ms:"; exit 5 ;;
esac
EOF2
chmod +x "$stubdir/codex"
export STUB_LOG=$tmp/calls
nocodex=$tmp/empty; mkdir -p "$nocodex"

run() { # run <args...>: in the fixture, stub first on PATH; sets out, rc, last
  : > "$STUB_LOG"
  out=$(cd "$repo" && TMPDIR="$tmp" PATH="$stubdir:$PATH" bash "$gate" "$@" 2>&1 </dev/null); rc=$?
  last=$(printf '%s\n' "$out" | tail -n 1)
}
calls() { grep -c . "$STUB_LOG"; }

# --- diff review ---
STUB_MODE=ran run
[ "$rc" -eq 0 ] && grep -q '^CODEX_GATE: passed' <<<"$last"; check "diff: a review that ran commands passes (exit 0, last line passed)" $?
grep -q 'Findings: none' <<<"$out"; check "diff: the verdict and findings reach the worker" $?
grep -q -- '--base origin/main' "$STUB_LOG"; check "diff: the review is of HEAD against origin/main" $?
grep -q 'read-only' "$STUB_LOG"; check "diff: the reviewer's own sandbox stays read-only" $?
STUB_MODE=empty run
[ "$rc" -eq 1 ] && grep -q '^CODEX_GATE: not-established' <<<"$last"; check "diff: an empty pass (no command ran) is not established (exit 1)" $?
STUB_MODE=failed run
[ "$rc" -eq 1 ] && grep -q '^CODEX_GATE: not-established' <<<"$last"; check "diff: a failed command is not established" $?
STUB_MODE=bad run
[ "$rc" -eq 1 ] && grep -q '^CODEX_GATE: not-established' <<<"$last"; check "diff: a reviewer exit status other than 0 is not established" $?

# --- a review of nothing is refused before the reviewer is called ---
(cd "$repo" && git update-ref refs/remotes/origin/main HEAD) >/dev/null 2>&1
STUB_MODE=ran run
[ "$rc" -eq 1 ] && grep -q '^CODEX_GATE: not-established' <<<"$last" && [ "$(calls)" -eq 0 ]; check "diff: no commit ahead of origin/main is not established, reviewer not called" $?
(cd "$repo" && git update-ref refs/remotes/origin/main HEAD~1) >/dev/null 2>&1
(cd "$repo" && git update-ref -d refs/remotes/origin/main) >/dev/null 2>&1
STUB_MODE=ran run
[ "$rc" -eq 1 ] && grep -q '^CODEX_GATE: not-established' <<<"$last" && [ "$(calls)" -eq 0 ]; check "diff: no origin/main to compare with is not established, reviewer not called" $?
(cd "$repo" && git update-ref refs/remotes/origin/main HEAD~1) >/dev/null 2>&1

# --- uncommitted changes to tracked files: the reviewer would read a stale diff ---
echo dirty >> "$repo/a.txt"
STUB_MODE=ran run
[ "$rc" -eq 4 ] && grep -q '^CODEX_GATE: dirty-worktree' <<<"$last" && [ "$(calls)" -eq 0 ]; check "diff: a tracked change is dirty-worktree (exit 4), reviewer not called" $?
(cd "$repo" && git checkout -q -- a.txt) >/dev/null 2>&1; : > "$repo/untracked.txt"
STUB_MODE=ran run
[ "$rc" -eq 0 ]; check "diff: an untracked file does not block the review" $?
rm -f "$repo/untracked.txt"

# --- no reviewing CLI ---
nopath=$nocodex:/usr/bin:/bin
if PATH="$nopath" command -v codex >/dev/null 2>&1; then
  echo "skip no-CLI case: a real reviewer sits in /usr/bin or /bin"
else
  out=$(cd "$repo" && PATH="$nopath" bash "$gate" 2>&1 </dev/null); rc=$?
  last=$(printf '%s\n' "$out" | tail -n 1)
  [ "$rc" -eq 3 ] && grep -q '^CODEX_GATE: unavailable' <<<"$last"; check "no reviewing CLI is unavailable (exit 3)" $?
fi

# --- design review: reads .worker-scratch/design.md, its own prompt, no diff needed ---
STUB_MODE=ran run --design
[ "$rc" -eq 2 ] && [ "$(calls)" -eq 0 ]; check "design: no design file is a usage error (exit 2), reviewer not called" $?
mkdir -p "$repo/.worker-scratch"; : > "$repo/.worker-scratch/design.md"
STUB_MODE=ran run --design
[ "$rc" -eq 2 ] && [ "$(calls)" -eq 0 ]; check "design: an empty design file is a review of nothing (exit 2)" $?
printf 'The design: add a gate.\n' > "$repo/.worker-scratch/design.md"
echo dirty >> "$repo/a.txt"
STUB_MODE=ran run --design
[ "$rc" -eq 0 ] && grep -q '^CODEX_GATE: passed' <<<"$last"; check "design: passes with a design file, also with a dirty tree" $?
grep -q 'design.md' "$STUB_LOG"; check "design: the prompt names the design file" $?
(cd "$repo" && git checkout -q -- a.txt) >/dev/null 2>&1
STUB_MODE=empty run --design
[ "$rc" -eq 1 ] && grep -q '^CODEX_GATE: not-established' <<<"$last"; check "design: an empty pass is not established" $?

# --- the gate takes no other argument: the hook counts only the two exact calls ---
STUB_MODE=ran run origin/main
[ "$rc" -eq 2 ] && [ "$(calls)" -eq 0 ]; check "an argument other than --design is a usage error" $?
STUB_MODE=ran run --design other.md
[ "$rc" -eq 2 ] && [ "$(calls)" -eq 0 ]; check "--design takes no file name" $?

# --- delivery: placed by org-start, named by the worker template, asked for by the rules ---
grep -q 'scripts/second-model-review.sh' "$here/skills/org-start/scripts/org-start.sh"; check "org-start places the gate beside the org script" $?
grep -q 'PADDOCK_CODEX_GATE="\$bd/second-model-review.sh"' "$here/templates/worker.md"; check "the worker template sets PADDOCK_CODEX_GATE to the placed gate" $?
grep -q 'bash "\$PADDOCK_CODEX_GATE"' "$here/templates/worker-rules.md" \
  && grep -q 'bash "\$PADDOCK_CODEX_GATE" --design' "$here/templates/worker-rules.md"; check "the worker rules give both gate calls" $?
grep -q 'CODEX_GATE: passed' "$here/templates/worker-rules.md" \
  && grep -q 'CODEX_ROUND_DENIED' "$here/templates/worker-rules.md"; check "the worker rules say how to read the last line and the round refusal" $?
grep -qi 'second model' "$here/README.md" && grep -q 'second-model-review.sh' "$here/README.md"; check "README states the review as something paddock offers" $?
[ -f "$here/scripts/probes/second-model-review-reach.sh" ] && sh -n "$here/scripts/probes/second-model-review-reach.sh" 2>/dev/null; check "a host probe for the sandbox reach exists and parses" $?

exit $fail
