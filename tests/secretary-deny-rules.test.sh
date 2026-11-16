#!/usr/bin/env bash
# Claude Code warns "Deny rule Write(./X) never matches - use Edit(./X)": a file rule that denies
# writing is spelled Edit(path); a Write(path) file rule never matches. So the secretary's settings
# must deny Edit(./AGENTS.md) and Edit(./CLAUDE.md), and carry no Write(<path>) file rule.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
s=$here/templates/secretary-settings.json
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

deny=$(awk '/"deny"/ { d = 1 } d && /\]/ { exit } d' "$s")
for r in 'Edit(./AGENTS.md)' 'Edit(./CLAUDE.md)'; do
  grep -qF "\"$r\"" <<<"$deny"; check "secretary-settings.json denies $r" $?
done
! grep -qE '"Write\([^)]' <<<"$deny"; check "secretary-settings.json has no Write(<path>) file rule (it never matches)" $?

exit $fail
