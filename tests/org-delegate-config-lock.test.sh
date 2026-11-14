#!/usr/bin/env bash
# Acceptance test for Issue #323 (follows #320/#322): a worker's sandbox leaves a 0-byte read-only .git/config.lock
# (mode 444) in the project clone's shared .git for the whole of every worker command. org-delegate must not need
# that file at all: it writes no git config (no branch.<b>.paddockBase, no upstream from `worktree add`), so a
# delegate succeeds at once while the placeholder is present, and the review gate still finds the base, which is
# recorded in the state folder (<state>/bases/<task id>), not in git config. Needs bash, coreutils and git: hc is a stub.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
delegate=$here/skills/org-delegate/scripts/org-delegate.sh
gate=$here/scripts/second-model-review.sh
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
printf '#!/bin/sh\necho "$*" >> "$STUB_LOG"; echo " succeeded in 1ms:"\n' > "$tmp/bin/codex"
chmod +x "$tmp/bin/hc" "$tmp/bin/codex"
export STUB_LOG=$tmp/calls

mkproj() {
  git init -q -b main "$1" 2>/dev/null || { git init -q "$1"; git -C "$1" checkout -q -b main; }
  git -C "$1" -c user.name=t -c user.email=t@t.invalid commit -q --allow-empty -m init
}
placeholder() { : > "$1/.git/config.lock"; chmod 444 "$1/.git/config.lock"; }
run() { # run <project> <task-id> [extra args]; a short bound: nothing may wait for the placeholder
  local p=$1 id=$2; shift 2
  PADDOCK_GIT_LOCK_WAIT=4 PADDOCK_STATE_DIR=$tmp/state PADDOCK_WORKERS_DIR=$tmp/workers \
    PADDOCK_CORE_SOCKET_DIR=$tmp/sock PATH="$tmp/bin:$PATH" \
    timeout 60 bash "$delegate" --project "$p" --task-id "$id" --task "do it" "$@" >/dev/null 2>&1
}
# the review gate as the worker runs it: from the worktree (with a commit ahead of the base), the state folder the secretary wrote
review() {
  : > "$STUB_LOG"
  (cd "$1" && echo x > f.txt && git add f.txt && git -c user.name=t -c user.email=t@t.invalid commit -q -m work) >/dev/null 2>&1
  (cd "$1" && TMPDIR="$tmp" PADDOCK_STATE_DIR=$tmp/state PATH="$tmp/bin:$PATH" bash "$gate" >/dev/null 2>&1 </dev/null)
}

# 1. Default path: an origin, so the delegate fetches and branches from origin/main (git would record an upstream).
# The placeholder is present throughout: the delegate exits 0 without waiting, and writes nothing to .git/config.
mkproj "$tmp/origin"; git clone -q "$tmp/origin" "$tmp/proj1" 2>/dev/null
placeholder "$tmp/proj1"; before=$(cat "$tmp/proj1/.git/config")
start=$SECONDS; run "$tmp/proj1" t1; rc=$?; took=$((SECONDS - start))
[ "$rc" -eq 0 ]; check "a 0-byte mode-444 config.lock is present: the delegate exits 0 (exit $rc)" $?
[ "$took" -lt 4 ]; check "it did not wait for the placeholder (${took}s, bound 4s)" $?
[ -d "$tmp/workers/t1" ]; check "the worktree exists" $?
[ "$(cat "$tmp/proj1/.git/config")" = "$before" ]; check "the shared .git/config is byte for byte unchanged" $?
[ -z "$(git -C "$tmp/proj1" config --get-regexp '^branch\.' 2>/dev/null | grep -v '^branch\.main\.')" ]
check "no branch.<b>.* config (no paddockBase, no upstream) was written" $?
[ -e "$tmp/proj1/.git/config.lock" ] && [ ! -s "$tmp/proj1/.git/config.lock" ]; check "the placeholder is left as it was" $?
[ "$(cat "$tmp/state/bases/t1" 2>/dev/null)" = origin/main ]; check "the base is recorded in the state folder (bases/t1)" $?
review "$tmp/workers/t1"
grep -q -- '--base origin/main' "$STUB_LOG"; check "the review gate finds the base from the state folder" $?

# 2. --no-fetch --base <local branch>: the same, with the placeholder.
mkproj "$tmp/proj2"; placeholder "$tmp/proj2"
run "$tmp/proj2" t2 --no-fetch --base main; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$tmp/state/bases/t2" 2>/dev/null)" = main ]; check "--no-fetch with a placeholder: exit 0, base main recorded (exit $rc)" $?
review "$tmp/workers/t2"
grep -q -- '--base main' "$STUB_LOG"; check "the review gate reviews against that base" $?

# 3. The base cannot be recorded (the bases folder is a file): the delegate must not exit 0, and leaves no worktree or branch.
mkproj "$tmp/proj3"; mkdir -p "$tmp/state3"; : > "$tmp/state3/bases"
PADDOCK_STATE_DIR=$tmp/state3 PADDOCK_WORKERS_DIR=$tmp/workers PADDOCK_CORE_SOCKET_DIR=$tmp/sock PATH="$tmp/bin:$PATH" \
  timeout 60 bash "$delegate" --project "$tmp/proj3" --task-id t3 --task "do it" --no-fetch --base main >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "a base that cannot be recorded is not hidden (exit $rc)" $?
[ ! -e "$tmp/workers/t3" ] && [ -z "$(git -C "$tmp/proj3" branch --format='%(refname:short)' | grep -v '^main$')" ]
check "no worktree and no branch are left behind" $?

exit "$fail"
