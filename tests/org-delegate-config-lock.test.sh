#!/usr/bin/env bash
# Acceptance test for Issue #320: a worker's sandbox leaves a 0-byte read-only .git/config.lock (mode 444) in the
# project clone's shared .git. org-delegate must wait for it (bounded), never hide a failed paddockBase write,
# and leave no branch behind when the worktree add fails. Needs only bash, coreutils and git: hc is a stub on PATH.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
delegate=$here/skills/org-delegate/scripts/org-delegate.sh
tmp=$(mktemp -d)
trap 'chmod 644 "$tmp"/proj*/.git/config.lock 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

mkdir -p "$tmp/bin"
cat > "$tmp/bin/hc" <<'EOF2'
#!/bin/sh
case $1 in
  get) echo '{"error":{"kind":"not_found"}}'; exit 1 ;;
  file) shift; for a in "$@"; do case "$a" in --*) ;; *) path=$a ;; esac; done
        mkdir -p "$(dirname "$path")" && cat > "$path"; echo '{"written":true}' ;;
  run) echo '{"first_message":{"sent":true,"started":true,"turn":0}}' ;;
esac
exit 0
EOF2
chmod +x "$tmp/bin/hc"

mkproj() {
  git init -q -b main "$1" 2>/dev/null || { git init -q "$1"; git -C "$1" checkout -q -b main; }
  git -C "$1" -c user.name=t -c user.email=t@t.invalid commit -q --allow-empty -m init
}
placeholder() { : > "$1/.git/config.lock"; chmod 444 "$1/.git/config.lock"; }
run() { # run <project> <task-id> [extra args]; PADDOCK_GIT_LOCK_WAIT bounds the wait (seconds)
  local p=$1 id=$2; shift 2
  PADDOCK_GIT_LOCK_WAIT=${WAIT:-4} PADDOCK_STATE_DIR=$tmp/state PADDOCK_WORKERS_DIR=$tmp/workers \
    PADDOCK_CORE_SOCKET_DIR=$tmp/sock PATH="$tmp/bin:$PATH" \
    timeout 60 bash "$delegate" --project "$p" --task-id "$id" --task "do it" --base main "$@" >/dev/null 2>&1
}

# 1. A live worker's placeholder disappears after 2 s: the delegate waits and succeeds, paddockBase is written.
mkproj "$tmp/proj1"; placeholder "$tmp/proj1"
( n=0; until [ "$n" -ge 20 ]; do n=$((n + 1)); sleep 0.1 2>/dev/null || sleep 1; done; rm -f "$tmp/proj1/.git/config.lock" ) &
WAIT=30 run "$tmp/proj1" t1 --no-fetch; rc=$?; wait
[ "$rc" -eq 0 ]; check "a placeholder that goes away: the delegate waits and exits 0 (exit $rc)" $?
[ "$(git -C "$tmp/proj1" config --get-regexp '^branch\..*\.paddockbase$' | awk '{print $2}')" = main ]
check "paddockBase is written after the wait" $?

# 2. A stranded placeholder (never goes away): bounded wait, exit 6, no branch and no worktree left behind.
# With an origin the delegate fetches and branches from origin/main, so git sets an upstream: the add needs the config lock.
mkproj "$tmp/origin"; git clone -q "$tmp/origin" "$tmp/proj2" 2>/dev/null
placeholder "$tmp/proj2"
run "$tmp/proj2" t2; rc=$?
[ "$rc" -eq 6 ]; check "a stranded placeholder: exit 6 within the bound (exit $rc)" $?
[ -z "$(git -C "$tmp/proj2" branch --format='%(refname:short)' | grep -v '^main$')" ]
check "no branch is left behind" $?
[ ! -e "$tmp/workers/t2" ]; check "no worktree folder is left behind" $?

# 3. Only the paddockBase write fails (a git wrapper refuses it): the delegate must not exit 0.
real=$(command -v git); mkdir -p "$tmp/gbin"
printf '#!/bin/sh\ncase "$*" in *paddockBase*) exit 1 ;; esac\nexec %s "$@"\n' "$real" > "$tmp/gbin/git"; chmod +x "$tmp/gbin/git"
mkproj "$tmp/proj3"
PATH="$tmp/gbin:$PATH" run "$tmp/proj3" t3 --no-fetch; rc=$?
[ "$rc" -ne 0 ]; check "a failed paddockBase write is not hidden (exit $rc)" $?

exit "$fail"
