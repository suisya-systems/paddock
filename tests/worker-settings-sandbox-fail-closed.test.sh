#!/usr/bin/env bash
# Static check (Issue #164, L-K7): the shipped worker settings make the sandbox fail closed.
# sandbox.failIfUnavailable true: when the sandbox cannot start, Claude Code exits at startup
# instead of running commands unsandboxed (absent means the vendor default, false).
# File content only, not behaviour. Needs bash and node.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
settings=$here/templates/worker-settings.json
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
is() { # is <key under sandbox> <true|false>: strict boolean
  node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    process.exit(s.sandbox && s.sandbox[process.argv[2]] === (process.argv[3] === "true") ? 0 : 1);' \
    "$settings" "$1" "$2"
}
is enabled true; check "sandbox.enabled is true" $?
is failIfUnavailable true; check "sandbox.failIfUnavailable is true" $?
[ "$fail" -eq 0 ]
