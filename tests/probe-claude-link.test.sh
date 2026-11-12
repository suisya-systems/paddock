#!/usr/bin/env bash
# Static check for Issue #212: a host probe that starts claude records `readlink ~/.local/bin/claude`
# before it starts and restores the link in its exit trap (scripts/probes/claude-link.sh), and no
# probe gives claude a temporary XDG_DATA_HOME. Nothing is run.
# worker-cache-env.sh is left out: its own fix (#189) owns it.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
lib=$here/scripts/probes/claude-link.sh
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

[ -f "$lib" ]; check "claude-link.sh exists" $?
grep -q 'readlink' "$lib" 2>/dev/null; check "lib records readlink" $?
grep -q 'FAIL' "$lib" 2>/dev/null; check "lib prints FAIL when the link changed" $?
grep -q 'ln -sfn' "$lib" 2>/dev/null; check "lib restores the link" $?

n=0
for f in "$here"/scripts/probes/*.sh "$here"/scripts/probes/*/*.sh; do
  b=${f#"$here"/}
  # prototype-3-setup.sh does not start claude; it only names it in the text it prints
  case "$b" in */claude-link.sh|*/worker-cache-env.sh|*/prototype-3-setup.sh) continue ;; esac
  # a probe starts claude when a non-comment line names claude, org-delegate or the org script
  grep -vE '^[[:space:]]*#' "$f" | grep -qE '\bclaude\b|org-delegate|scripts/org|\$BD/org|bin/org' || continue
  n=$((n + 1))
  grep -q '^\. .*claude-link\.sh' "$f" && grep -q '^claude_link_save' "$f"; check "$b saves the link before it starts claude" $?
  grep -q 'claude_link_restore' "$f"; check "$b restores the link in its exit trap" $?
  grep -qE '(^|[[:space:]])XDG_DATA_HOME=' "$f"; r=$?; [ $r -ne 0 ]; check "$b sets no XDG_DATA_HOME" $?
done
[ "$n" -gt 0 ]; check "found probes that start claude ($n)" $?
exit $fail
