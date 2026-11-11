#!/usr/bin/env bash
# Acceptance test for Issue #253: the review gate (scripts/second-model-review.sh) leaves a durable
# record of its result. After the hook counted a round (codex_round_started), the gate appends
# codex_round_passed or codex_round_failed for the same task, as writer codex-gate, with the round
# and the gate's last line, to the protected count folder and to the history. The Prototype 3
# runbook's 8-review step reads that record, not the worker's done text.
# Needs bash, git, coreutils, sed and awk; the reviewing CLI is replaced by a stub on PATH.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
gate=$here/scripts/second-model-review.sh
script=$here/scripts/org
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

state=$tmp/state; cdir=$tmp/rounds; task=t253
repo=$tmp/workers/$task; mkdir -p "$repo"
(
  cd "$repo" && git init -q -b main . \
    && git config user.email t@example.com && git config user.name t \
    && echo one > a.txt && git add a.txt && git commit -q -m one \
    && git update-ref refs/remotes/origin/main HEAD \
    && echo two >> a.txt && git commit -q -am two
) >/dev/null 2>&1; check "fixture repository is built" $?

stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/codex" <<'EOF2'
#!/bin/sh
case "${STUB_MODE:-ran}" in
  ran)   echo " succeeded in 12ms:"; echo "Findings: none"; exit 0 ;;
  empty) echo "Findings: none"; exit 0 ;;
esac
EOF2
chmod +x "$stubdir/codex"

env_org() { env -u PADDOCK_ORG_ID -u PADDOCK_NOW -u XDG_DATA_HOME PADDOCK_STATE_DIR="$state" PADDOCK_CODEX_DIR="$cdir" "$@"; }
# round <args...>: what the hook does before the gate runs (counts one round for the task)
round() { env_org bash "$script" --as codex-gate codex_round start --task "$task" "$@" >/dev/null 2>&1; }
run() { # run <args...>: the gate in the worker's worktree, as the worker's environment has it
  out=$(cd "$repo" && env_org TMPDIR="$tmp" PATH="$stubdir:$PATH" PADDOCK_ORG="$script" \
    CLAUDE_PROJECT_DIR="$repo" bash "$gate" "$@" 2>&1 </dev/null); rc=$?
  last=$(printf '%s\n' "$out" | tail -n 1)
}
hist() { cat "$state"/events/*/codex-gate.jsonl 2>/dev/null; }
kept() { cat "$cdir"/events/*/codex-gate.jsonl 2>/dev/null; }
line_of() { grep "\"kind\":\"$1\"" | grep "\"task_id\":\"$task\"" | tail -n 1; }

# --- a review that happened: codex_round_passed, with the round and the last line ---
round; STUB_MODE=ran run
[ "$rc" -eq 0 ] && grep -q '^CODEX_GATE: passed' <<<"$last"; check "passed: the gate's last line is still CODEX_GATE: passed" $?
l=$(hist | line_of codex_round_passed)
[ -n "$l" ]; check "passed: codex_round_passed for the task is in the history" $?
grep -q '"from":"codex-gate"' <<<"$l"; check "passed: the record's writer is codex-gate" $?
grep -q 'diff round 1' <<<"$l" && grep -q 'CODEX_GATE: passed' <<<"$l"; check "passed: the record carries the round and the last line" $?
[ -n "$(kept | line_of codex_round_passed)" ]; check "passed: the record is also in the count folder the worker cannot write" $?

# --- a review that did not happen: codex_round_failed ---
round; STUB_MODE=empty run
[ "$rc" -eq 1 ] && grep -q '^CODEX_GATE: not-established' <<<"$last"; check "failed: the gate's last line is still not-established" $?
l=$(hist | line_of codex_round_failed)
grep -q 'diff round 2' <<<"$l" && grep -q 'CODEX_GATE: not-established' <<<"$l"; check "failed: codex_round_failed carries round 2 and the last line" $?
[ "$(hist | grep -c '"kind":"codex_round_passed"')" -eq 1 ]; check "failed: no second codex_round_passed" $?

echo dirty >> "$repo/a.txt"; round; STUB_MODE=ran run
grep -q 'CODEX_GATE: dirty-worktree' <<<"$(hist | line_of codex_round_failed)"; check "dirty-worktree is recorded as codex_round_failed" $?
(cd "$repo" && git checkout -q -- a.txt) >/dev/null 2>&1

# --- the design review records its own round ---
mkdir -p "$repo/.worker-scratch"; printf 'The design.\n' > "$repo/.worker-scratch/design.md"
round --design; STUB_MODE=ran run --design
grep -q 'design round 1' <<<"$(hist | line_of codex_round_passed)"; check "design: codex_round_passed says design round 1" $?

# --- a result is not a round: the cap still counts codex_round_started only ---
[ "$(kept | grep -c '"kind":"codex_round_started"')" -eq 4 ]; check "result records do not add rounds" $?

# --- only codex-gate writes a result, and a worker cannot call it through Bash ---
env_org bash "$script" --as w-$task codex_round result --task "$task" 'CODEX_GATE: passed' >/dev/null 2>&1
[ $? -eq 7 ]; check "a worker id cannot write a result (exit 7)" $?

# --- the runbook's 8-review step reads the record, not the done text ---
p3=$here/scripts/probes/prototype-3.sh
grep -q 'codex_round_passed' "$p3"; check "the runbook's 8-review reads codex_round_passed" $?
! grep -q "first_of \"\$W\" \"\$dq\" | grep -q 'CODEX_GATE: passed'" "$p3"; check "the runbook no longer reads CODEX_GATE: passed from the done text" $?

exit $fail
