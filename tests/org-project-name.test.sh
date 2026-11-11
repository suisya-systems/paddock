#!/usr/bin/env bash
# Acceptance test for Issue #186: org-delegate and org-pull-request accept --project <name> and read
# the path and the base branch from projects.md. Needs only bash, coreutils and git (hc and gh are stubs).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
delegate=$here/skills/org-delegate/scripts/org-delegate.sh
pr=$here/skills/org-pull-request/scripts/org-pull-request.sh
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
  wait) echo '{"ended":true,"exit_code":0}' ;;
  connect) cat >/dev/null; echo '{"jsonrpc":"2.0","id":1,"result":{"value":null,"version":0}}' ;;
esac
exit 0
EOF2
cat > "$stubdir/gh" <<'EOF2'
#!/bin/sh
echo "gh $*" >> "$STUB_CALLS"
case "$1 $2" in
  "pr create") echo "https://github.com/o/r/pull/42" ;;
  "run list") echo 777 ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc" "$stubdir/gh"

g() { git -c user.name=t -c user.email=t@t.invalid "$@"; }
# proj has main and dev, one different commit each.
g init -q -b main "$tmp/proj" 2>/dev/null || g init -q "$tmp/proj"
g -C "$tmp/proj" checkout -q -B main
g -C "$tmp/proj" commit -q --allow-empty -m on-main
g -C "$tmp/proj" checkout -q -b dev
g -C "$tmp/proj" commit -q --allow-empty -m on-dev
g -C "$tmp/proj" checkout -q main
devsha=$(g -C "$tmp/proj" rev-parse dev)
mainsha=$(g -C "$tmp/proj" rev-parse main)
[ "$devsha" != "$mainsha" ]; check "setup: dev and main differ" $?

# The projects table: the header names the columns; other columns are ignored.
cat > "$tmp/projects.md" <<EOF2
# Projects

| name | path | description | base |
| --- | --- | --- | --- |
| app | $tmp/proj | the app | dev |
| plain | $tmp/proj | no base given |  |
EOF2

run() { # run <task-id> [args]  (the caller passes --project)
  id=$1; shift
  env -u PADDOCK_ORG_ID -u HC_TERMINAL_SOCKET PADDOCK_CORE_SOCKET_DIR="$tmp/run/herdr-core" PATH="$stubdir:$PATH" \
    PADDOCK_PROJECTS_FILE="$tmp/projects.md" PADDOCK_WORKERS_DIR="$tmp/workers" PADDOCK_STATE_DIR="$tmp/state" \
    PADDOCK_NOW=2026-11-11T01:02:03Z bash "$delegate" --task-id "$id" --task t "$@" 2>&1
}

out=$(run n1 --project app); rc=$?
[ "$rc" -eq 0 ] && [ "$(g -C "$tmp/workers/n1" rev-parse HEAD)" = "$devsha" ]; check "--project app branches from the row's base dev ($out)" $?

out=$(run n2 --project app --base main); rc=$?
[ "$rc" -eq 0 ] && [ "$(g -C "$tmp/workers/n2" rev-parse HEAD)" = "$mainsha" ]; check "an explicit --base wins over the row's base" $?

out=$(run n3 --project plain); rc=$?
[ "$rc" -eq 0 ] && [ "$(g -C "$tmp/workers/n3" rev-parse HEAD)" = "$mainsha" ]; check "a row with an empty base uses main" $?

out=$(run n4 --project nosuch); rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$tmp/workers/n4" ]; check "an unknown name exits 2 and creates nothing ($out)" $?

out=$(run n5 --project "$tmp/proj"); rc=$?
[ "$rc" -eq 0 ] && [ "$(g -C "$tmp/workers/n5" rev-parse HEAD)" = "$mainsha" ]; check "a path still works as before" $?

# org-pull-request: --project app makes the PR's base dev.
g init -q --bare "$tmp/origin.git"
g clone -q "$tmp/origin.git" "$tmp/wt" 2>/dev/null
g -C "$tmp/wt" checkout -q -b feat/x
g -C "$tmp/wt" commit -q --allow-empty -m one
calls=$tmp/calls; : > "$calls"
prrun() {
  env -u PADDOCK_NOW STUB_CALLS="$calls" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_RUN_SLEEP=0 PADDOCK_RUN_TRIES=3 \
    PADDOCK_PROJECTS_FILE="$tmp/projects.md" PATH="$stubdir:$PATH" \
    bash "$pr" --worktree "$tmp/wt" --repo o/r --title T --body B "$@" 2>&1
}
out=$(prrun --project app); rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr create .*--base dev ' "$calls"; check "org-pull-request --project app opens the PR against dev ($out)" $?

: > "$calls"; out=$(prrun --project app --base main); rc=$?
grep -q 'pr create .*--base main ' "$calls"; check "org-pull-request: an explicit --base wins" $?

out=$(prrun --project nosuch); rc=$?
[ "$rc" -eq 2 ]; check "org-pull-request: an unknown name exits 2" $?

[ "$fail" -eq 0 ]
