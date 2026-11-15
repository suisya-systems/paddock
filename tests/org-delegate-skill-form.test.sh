#!/usr/bin/env bash
# Decision 0014, wave 2 unit 3: org-delegate and org-clone take the SKILL.md form (when_to_use, description and
# when_to_use under 1,536 characters, body under 12 KB, exit codes in the script's --help and next: lines, not in the
# text), and the template's delegate lines (L18-L22: flags, exits, the uncloned-repository sequence, the stale base)
# live in those skills.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
fm() { awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$1"; }
body() { awk 'NR == 1 && $0 != "---" { print; next } c >= 2 { print } $0 == "---" { c++ }' "$1"; }
tpl=$here/templates/secretary.md

for s in org-delegate org-clone; do
  f=$here/skills/$s/SKILL.md
  fm "$f" | grep -Eq '^when_to_use:[[:space:]]*[^[:space:]]'; check "$s: when_to_use is declared" $?
  [ "$(fm "$f" | grep -E '^(description|when_to_use):' | wc -c)" -lt 1536 ]; check "$s: description + when_to_use are under 1,536 characters" $?
  [ "$(body "$f" | wc -c)" -lt 12288 ]; check "$s: the body is under 12 KB" $?
  ! grep -q '^## Exit codes' "$f"; check "$s: no exit-code table in the text (it is --help and the next: lines)" $?
  bash "$here/skills/$s/scripts/$s.sh" --help 2>&1 | grep -q 'Exit codes'; check "$s: --help lists the exit codes" $?
  bash "$here/skills/$s/scripts/$s.sh" --help 2>&1 | grep -q 'next:'; check "$s: --help names the next: line" $?
done
fm "$here/skills/org-delegate/SKILL.md" | grep -E '^when_to_use:' | grep -qi 'stale'; check "org-delegate: when_to_use names the stale-base request" $?
fm "$here/skills/org-clone/SKILL.md" | grep -E '^when_to_use:' | grep -qE 'projects\.md|OWNER/NAME|not on the machine'; check "org-clone: when_to_use names the unknown-repository situation" $?

bash "$here/skills/org-delegate/scripts/org-delegate.sh" --help 2>&1 | grep -q -- '--repo OWNER/NAME'; check "org-delegate --help documents --repo OWNER/NAME" $?
grep -q -- '--repo' "$here/skills/org-delegate/SKILL.md"; check "org-delegate SKILL.md documents --repo" $?
grep -qi 'stale' "$here/skills/org-delegate/SKILL.md" && grep -q 'git fetch origin' "$here/skills/org-delegate/SKILL.md"; check "org-delegate SKILL.md carries the stale-base procedure (was template L22)" $?
grep -q 'send_message w-<task_id>' "$here/skills/org-delegate/SKILL.md"; check "  and says how to answer the worker" $?
grep -q 'PROMPT=' "$here/skills/org-clone/SKILL.md" && grep -qi 'approval card' "$here/skills/org-clone/SKILL.md"; check "org-clone SKILL.md keeps the trust-card judgment (was template L21)" $?
grep -q 'answer --id' "$here/skills/org-clone/SKILL.md" && grep -q 'RESENT' "$here/skills/org-clone/SKILL.md"; check "  and the yes/no handling (answer, RESENT)" $?
grep -q 'org-delegate --repo\|--repo OWNER/NAME' "$here/skills/org-clone/SKILL.md"; check "org-clone SKILL.md points to org-delegate --repo" $?

# The template no longer holds that procedure.
! grep -q 'skills/org-delegate/scripts/org-delegate.sh' "$tpl"; check "template: no org-delegate script path" $?
! grep -q 'skills/org-clone/scripts/org-clone.sh' "$tpl"; check "template: no org-clone script path" $?
! grep -qE 'Exit 10: the worker started|Exit 12: the start record|Exit 5 with a terminal' "$tpl"; check "template: no org-delegate exit-code lines" $?
! grep -q 'hc run --bg --outlive-parent' "$tpl"; check "template: no hc run recipe for workers" $?
! grep -qi 'base is stale' "$tpl"; check "template: the stale-base procedure left (it is in the skill)" $?
grep -q 'paddock:org-delegate' "$tpl"; check "template: still names the skill paddock:org-delegate" $?
grep -q 'Give each task one worker' "$tpl" && grep -q 'task_id. is short' "$tpl"; check "template: the scoping line (L17) and the task_id line (L20) stay" $?
exit $fail
