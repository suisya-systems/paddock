#!/usr/bin/env bash
# Acceptance test for Issue #165: a project can turn on the strong read block for secret-looking files in a
# worker's worktree (projects.md column secret-block, or org-delegate --secret-block), name its own patterns,
# and keep example files readable by the Read tool. Off by default (L-K1). Needs bash, coreutils, git and node; hc is a stub.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
delegate=$here/skills/org-delegate/scripts/org-delegate.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
cmd=$1; shift
case "$cmd" in
  ls) echo '[]' ;;
  get) echo '{"error":{"kind":"not_found"}}'; exit 1 ;;
  file) shift; path=; for a in "$@"; do case "$a" in --*) ;; *) path=$a ;; esac; done
        mkdir -p "$(dirname "$path")" && cat > "$path"; echo '{"written":true}' ;;
  run) echo '{"first_message":{"sent":true,"started":true,"turn":0}}' ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"

g() { git -c user.name=t -c user.email=t@t.invalid "$@"; }
g init -q -b main "$tmp/proj" 2>/dev/null || g init -q "$tmp/proj"
g -C "$tmp/proj" checkout -q -B main
g -C "$tmp/proj" commit -q --allow-empty -m init

cat > "$tmp/projects.md" <<EOF2
# Projects

| name | path | secret-block |
| --- | --- | --- |
| plain | $tmp/proj |  |
| strict | $tmp/proj | on |
| custom | $tmp/proj | secrets.json, *.key |
| bad | $tmp/proj | a"b |
EOF2

run() { # run <task-id> [args]
  id=$1; shift
  env -u PADDOCK_ORG_ID -u HC_TERMINAL_SOCKET PADDOCK_CORE_SOCKET_DIR="$tmp/run/herdr-core" PATH="$stubdir:$PATH" \
    PADDOCK_PROJECTS_FILE="$tmp/projects.md" PADDOCK_WORKERS_DIR="$tmp/workers" PADDOCK_STATE_DIR="$tmp/state" \
    PADDOCK_NOW=2026-11-11T01:02:03Z bash "$delegate" --task-id "$id" --task t "$@" 2>&1
}
# js <id> <expression over s, the parsed settings file and wt, the worktree>: exit 0 when it is true.
js() {
  node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")),wt=process.argv[2];
    const d=(s.permissions||{}).deny||[],dr=s.sandbox.filesystem.denyRead||[],ar=s.sandbox.filesystem.allowRead||[];
    process.exit(eval(process.argv[3])?0:1)' "$tmp/workers/$1/.claude/settings.local.json" "$tmp/workers/$1" "$2"
}

out=$(run p1 --project plain); rc=$?
[ "$rc" -eq 0 ] && js p1 'd.length===0 && !dr.some(x=>x.includes("env")) && ar.length===0'; check "no secret-block: no Read deny, no denyRead, no allowRead ($out)" $?

out=$(run s1 --project strict); rc=$?
[ "$rc" -eq 0 ] && js s1 'd.includes("Read(**/.env)") && d.includes("Read(**/.env.*)") && d.includes("Read(**/credentials*)") && d.includes("Read(**/*.pem)")'; check "on: Read deny rules for the default patterns ($out)" $?
js s1 'dr.includes(wt+"/.env") && dr.includes(wt+"/**/.env.*") && dr.includes(wt+"/**/credentials*") && dr.includes(wt+"/**/*.pem")'; check "on: sandbox denyRead holds the absolute worktree paths" $?
js s1 'dr.some(x=>x.includes("herdr-core"))'; check "on: the socket folder deny is kept" $?
js s1 'd.includes("Read(!**/*.example)") && ar.length===0'; check "on: the Read tool opens example files; no allowRead (measured: it does not open them to programs)" $?

out=$(run c1 --project custom); rc=$?
[ "$rc" -eq 0 ] && js c1 'd.includes("Read(**/secrets.json)") && d.includes("Read(**/*.key)") && !d.includes("Read(**/.env)") && dr.includes(wt+"/**/*.key")'; check "own patterns replace the defaults ($out)" $?

out=$(run f1 --project plain --secret-block on); rc=$?
[ "$rc" -eq 0 ] && js f1 'd.includes("Read(**/.env)")'; check "--secret-block on turns it on for a project without the column ($out)" $?

out=$(run f2 --project strict --secret-block off); rc=$?
[ "$rc" -eq 0 ] && js f2 'd.length===0'; check "--secret-block off wins over the row ($out)" $?

out=$(run f3 --project "$tmp/proj" --secret-block 'x.pem,y.key'); rc=$?
[ "$rc" -eq 0 ] && js f3 'd.includes("Read(**/x.pem)") && d.includes("Read(**/y.key)")'; check "--secret-block takes patterns for a project given by path ($out)" $?

out=$(run b1 --project bad); rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$tmp/workers/b1" ]; check "a pattern with a quote exits 2 and creates nothing ($out)" $?

grep -q 'secret-block' "$here/skills/org-delegate/SKILL.md"; check "SKILL.md documents secret-block" $?
grep -q 'secret-block' "$here/docs/design/predecessor-inventory.md"; check "the inventory records what a project loses (secret-block)" $?

[ "$fail" -eq 0 ]
