#!/usr/bin/env bash
# Decision 0014 wave 2 unit 7: org-start, org-down, org-suspend and org-resume are run by the person
# from a login shell, so the model never chooses them (disable-model-invocation), and each has a
# when_to_use and a body under the 12 KB cap (so the 5,000-token re-attachment holds all of it).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
fm() { awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$1"; }
for s in org-start org-down org-suspend org-resume; do
  f=$here/skills/$s/SKILL.md
  fm "$f" | grep -Eq "^name:[[:space:]]*$s[[:space:]]*$"; check "$s: name equals the folder" $?
  fm "$f" | grep -Eq '^disable-model-invocation:[[:space:]]*true[[:space:]]*$'; check "$s: disable-model-invocation: true" $?
  fm "$f" | grep -Eq '^when_to_use:[[:space:]]*[^[:space:]]'; check "$s: when_to_use is present" $?
  n=$(fm "$f" | grep -E '^(description|when_to_use):' | wc -c); [ "$n" -lt 1536 ]; check "$s: description + when_to_use under 1,536 characters ($n)" $?
  b=$(awk 'c >= 2 { print } $0 == "---" { c++ }' "$f" | wc -c); [ "$b" -lt 12288 ]; check "$s: body under 12 KB ($b)" $?
done
exit $fail
