#!/usr/bin/env bash
# Acceptance test for Issue #300: when the second-model review did not end CODEX_GATE: passed,
# the pull request and the secretary's report say so, with the gate's last line.
# The worker carries that line in its report; the secretary puts it in the PR body and its own report.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

rules=$here/templates/worker-rules.md
sec=$here/templates/secretary.md
skill=$here/skills/org-pull-request/SKILL.md

grep -E 'last line' "$rules" | grep -qE 'verbatim|exact'; check "worker rules: the gate's last line goes into the report verbatim" $?
grep -qE 'CODEX_GATE: passed' "$sec"; check "secretary template names CODEX_GATE: passed" $?
sline=$(grep -E 'did not run' "$sec")
grep -qE 'pull request|PR body' <<<"$sline" && grep -qE 'report' <<<"$sline"; check "secretary template: a review that did not run is said in the PR and in the report" $?
grep -qE 'did not run' "$skill"; check "org-pull-request skill: the body says the review did not run" $?
exit $fail
