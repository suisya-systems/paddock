#!/usr/bin/env bash
# Issue #129: org-start refuses a PADDOCK_BIN_DIR that resolves to the templates folder through
# a not-yet-existing ".." component (its stale cleanup would delete the role files it just placed).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
printf '#!/bin/sh\ncase "$1" in get) exit 1 ;; esac\nexit 0\n' > "$tmp/bin/hc"; chmod +x "$tmp/bin/hc"
env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
    -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN PATH="$tmp/bin:$PATH" \
    PADDOCK_CORE_TEMPLATES_DIR="$tmp/p/templates" PADDOCK_APP_MODS_DIR="$tmp/mods" \
    PADDOCK_BIN_DIR="$tmp/p/new/../templates" PADDOCK_READY_TRIES=1 \
    bash "$here/skills/org-start/scripts/org-start.sh" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$tmp/p/templates/worker-rules.md" ]; then echo "ok   PADDOCK_BIN_DIR with new/../templates refused (exit 2)"; exit 0; fi
echo "FAIL PADDOCK_BIN_DIR with new/../templates refused (exit 2, got $rc)"; exit 1
