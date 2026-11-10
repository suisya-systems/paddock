#!/usr/bin/env bash
# Static check (Issue #39, L-N9): the shipped worker settings keep herdr's state folder
# and herdr-app's folder in the sandbox denyRead and in a Read deny. Needs bash and node.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
settings=$here/templates/worker-settings.json
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
has() { # has <denyRead|Read> <path>: the entry is present in that layer
  node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const [layer, p] = [process.argv[2], process.argv[3]];
    const list = layer === "denyRead" ? s.sandbox.filesystem.denyRead : s.permissions.deny;
    const want = layer === "denyRead" ? p : "Read(" + p + "/**)";
    process.exit(list.includes(want) ? 0 : 1);' "$settings" "$1" "$2"
}
for p in '~/.local/state/herdr-core' '~/.config/herdr-app'; do
  has denyRead "$p"; check "sandbox denyRead has $p" $?
  has Read "$p"; check "permissions.deny has Read($p/**)" $?
done
[ "$fail" -eq 0 ]
