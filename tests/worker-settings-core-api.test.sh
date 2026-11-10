#!/usr/bin/env bash
# Static check (Issue #32, L-N2): the shipped worker settings keep the entries the L-N2 row
# names: the Bash deny for the core command, sandbox on, and the core's state folder in the
# sandbox denyRead and denyWrite and in the Read and Edit denies. File content only, not
# behaviour. The core's socket folder is not named in the settings (see the L-N2 row), so it
# is not checked here. Needs bash and node.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
settings=$here/templates/worker-settings.json
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
has() { # has <path-in-json> <entry>: the array at that path holds the entry
  node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const list = process.argv[2].split(".").reduce((o, k) => o && o[k], s);
    process.exit(Array.isArray(list) && list.includes(process.argv[3]) ? 0 : 1);' "$settings" "$1" "$2"
}
node -e 'process.exit(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).sandbox.enabled === true ? 0 : 1)' "$settings"
check "sandbox.enabled is true" $?
has permissions.deny 'Bash(hc:*)'; check "permissions.deny has Bash(hc:*)" $?
p='~/.local/state/herdr-core'
has sandbox.filesystem.denyRead "$p"; check "sandbox denyRead has $p" $?
has sandbox.filesystem.denyWrite "$p"; check "sandbox denyWrite has $p" $?
has permissions.deny "Read($p/**)"; check "permissions.deny has Read($p/**)" $?
has permissions.deny "Edit($p/**)"; check "permissions.deny has Edit($p/**)" $?
[ "$fail" -eq 0 ]
