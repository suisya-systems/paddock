#!/usr/bin/env bash
# Static check (Issue #151): the shipped worker settings refuse reads of secret-looking files in
# the worker's own worktree (.env, .env.*, credentials*, *.pem) and keep the usual examples
# (.env.example, .env.*.example) readable. Needs bash and node.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
settings=$here/templates/worker-settings.json
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
js() { node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const d=(s.permissions||{}).deny||[];'"$1" "$settings" "${@:2}"; }

# 1. Read deny rules, relative to the worker's cwd (its worktree). The doc anchors a bare or
#    **/ pattern at the current directory; a /path one would anchor at the settings file's folder.
deny=('Read(.env)' 'Read(.env.*)' 'Read(**/.env)' 'Read(**/.env.*)' 'Read(**/credentials*)' 'Read(**/*.pem)')
carve=('Read(!.env.example)' 'Read(!.env.*.example)' 'Read(!**/.env.example)' 'Read(!**/.env.*.example)')
for r in "${deny[@]}" "${carve[@]}"; do
  js 'process.exit(d.includes(process.argv[2])?0:1)' "$r"; check "permissions.deny has $r" $?
done
# A "!" rule carves out of the rules listed BEFORE it, so every carve-out follows every .env deny.
js 'const p=d.map((r,i)=>[r,i]);const last=Math.max(...p.filter(([r])=>/^Read\((\*\*\/)?\.env/.test(r)).map(([,i])=>i));
    const first=Math.min(...p.filter(([r])=>/^Read\(!/.test(r)).map(([,i])=>i));process.exit(first>last?0:1)'
check "every Read(!...) carve-out comes after every .env deny" $?
js 'process.exit(d.some(r=>/^Read\([^!].*\.example\)$/.test(r))?1:0)'; check "no example name is denied" $?

# 2. No relative sandbox entry: in a --settings file a relative sandbox path resolves against the
#    settings file's folder (the bin folder), not the worktree, so it would guard nothing (Issue #151).
js 'const f=(s.sandbox||{}).filesystem||{};const bad=[].concat(f.denyRead||[],f.allowRead||[]).filter(p=>!/^(\/|~\/)/.test(p));
    if(bad.length)console.log(bad.join(" "));process.exit(bad.length?1:0)'
check "sandbox denyRead/allowRead hold only absolute or ~/ paths" $?

exit $fail
