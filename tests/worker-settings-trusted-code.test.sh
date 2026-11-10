#!/usr/bin/env bash
# Static check (Issue #31, L-N1): the shipped worker settings keep the entries the L-N1 row names:
# an Edit deny and a sandbox denyWrite entry for herdr-core's folder and herdr-app's folder, and
# no sandbox allowWrite entry that covers either (the folder itself, a parent or a child of it).
# Checks file content, not behaviour. Needs bash and node.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
settings=$here/templates/worker-settings.json
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
js() { # js <denyWrite|Edit|allowWriteClear> <path>
  node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const p = process.argv[3], f = s.sandbox.filesystem;
    const m = {
      denyWrite: () => (f.denyWrite || []).includes(p),
      Edit: () => s.permissions.deny.includes("Edit(" + p + "/**)"),
      allowWriteClear: () => !(f.allowWrite || []).some(a => {
        const b = a.replace(/\/$/, "");
        return b === p || p.startsWith(b + "/") || b.startsWith(p + "/");
      }),
    };
    process.exit(m[process.argv[2]]() ? 0 : 1);' "$settings" "$1" "$2"
}
for p in '~/.config/herdr-core' '~/.config/herdr-app'; do
  js denyWrite "$p"; check "sandbox denyWrite has $p" $?
  js Edit "$p"; check "permissions.deny has Edit($p/**)" $?
  js allowWriteClear "$p"; check "sandbox allowWrite does not cover $p" $?
done
[ "$fail" -eq 0 ]
