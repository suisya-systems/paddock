#!/usr/bin/env bash
# org-down ends the watcher, and only a
# terminal carrying the label paddock_role=watcher (decision 0008; org-start's side is in org-start.test.sh).
. "$(dirname "${BASH_SOURCE[0]}")/hc-stub.sh"
# Wrap the shared stub: the terminal "watcher" carries a role label (STUB_WATCHER_LABEL, default yes).
mv "$stubdir/hc" "$stubdir/hc.real"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
if [ "$1" = get ] && [ "${*##* }" = watcher ] && [ -f "$STUB/term-watcher" ]; then
  echo "$*" >> "$STUB/calls"
  l='{}'; [ -n "${STUB_WATCHER_OTHER:-}" ] || l='{"paddock_role":"watcher"}'
  printf '{\n  "name": "watcher",\n  "state": "live",\n  "labels": %s,\n  "status": {"state":"working"}\n}\n' "$l"; exit 0
fi
exec "$(dirname "$0")/hc.real" "$@"
EOF2
chmod +x "$stubdir/hc"
down=$here/skills/org-down/scripts/org-down.sh

reset; term watcher; term w-t1 t1
run_script "$down" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && grep -q '^kill watcher' "$calls" && grep -q '^rm watcher' "$calls"; check "org-down ends the watcher (with its label), without --secretary" $?
[ ! -f "$tmp/stub/term-watcher" ]; check "the watcher terminal is gone" $?
reset; term watcher; ENVX=STUB_WATCHER_OTHER=1 run_script "$down" >/dev/null
! grep -Eq '^(kill|rm) watcher' "$calls" && [ -f "$tmp/stub/term-watcher" ]; check "a terminal named watcher without the role label is never touched" $?
reset; term boss; ENVX=PADDOCK_WATCHER_NAME=other run_script "$down" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ! grep -q '^kill watcher' "$calls"; check "no watcher terminal: org-down still succeeds" $?

exit "$fail"
