#!/usr/bin/env bash
# Static check for decision 0014 probes H4 and H5: scripts/probes/plugin-dir-skills.sh starts a
# secretary-like template with --plugin-dir, measures skill discovery, a live edit, a new skill and
# allowed-tools, and must leave the checkout and the host as it found them. Nothing is run.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
probe=$here/scripts/probes/plugin-dir-skills.sh
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
code() { grep -vE '^[[:space:]]*#' "$probe"; }

[ -f "$probe" ]; check "scripts/probes/plugin-dir-skills.sh exists" $?
[ -f "$probe" ] || { echo "(no probe: the rest is skipped)"; exit 1; }

sh -n "$probe"; check "the probe parses (sh -n)" $?
grep -q '^\. .*claude-link\.sh' "$probe" && grep -q '^claude_link_save' "$probe" && grep -q 'claude_link_restore' "$probe"; check "the claude link is saved and restored" $?
code | grep -q -- '--plugin-dir'; check "the template launch passes --plugin-dir" $?
code | grep -q '\.claude-plugin/plugin\.json'; check "plugin.json is written by the probe, in its own folder" $?
code | grep -q 'mktemp -d "\$HOME/\|ROOT="\$HOME/'; check "the working folders live under HOME (folder trust)" $?
! code | grep -Eq '(^|[[:space:]])(export[[:space:]]+)?XDG_DATA_HOME='; check "the probe never sets XDG_DATA_HOME" $?
! code | grep -Eq '(>|>>|cp[^|]*|mv[^|]*|sed -i[^|]*)[[:space:]"]*(\$SELF/\.\./\.\.|\$REPO)/(skills|\.claude-plugin)'; check "the checkout's skills and plugin.json are never written" $?
grep -q 'trap .* EXIT' "$probe"; check "an exit trap cleans up" $?
code | grep -q '^allowed-tools: Bash(\|allowed-tools: Bash('; check "the probe skill declares allowed-tools (H5)" $?
code | grep -q 'when_to_use'; check "the probe skill declares when_to_use (situation match)" $?
for r in H4-dialog H4-list H4-invoke H4-edit-live H4-new-skill H5-allowed-tools H5-control; do
  code | grep -q "RESULT $r"; check "prints RESULT $r" $?
done
exit $fail
