#!/usr/bin/env bash
# Regression (Issue #219): only the prompt string is matched, whatever field follows it; escaped quotes stay inside.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
hook=$here/scripts/hooks/premise-reminder.sh
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
out=$(printf '{"prompt":"hello","hook_event_name":"UserPromptSubmit"}' | sh "$hook"); [ -z "$out" ]; check "a plain prompt followed by metadata prints nothing" $?
out=$(printf '{"prompt":"say \\"hi\\" for 30 seconds","cwd":"/x"}' | sh "$hook"); [ -n "$out" ]; check "an escaped quote does not cut the prompt" $?
exit "$fail"
