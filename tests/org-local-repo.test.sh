#!/usr/bin/env bash
# Acceptance test for decision 0010 (Issue #359): a request that names no repository runs in a local
# repository. local-repo.sh makes it, org-delegate runs in it as today, merge-local.sh closes it with
# no PR (ff-only into main). Needs bash, coreutils and git; hc is a stub on PATH, no core runs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mk=$here/skills/org-delegate/scripts/local-repo.sh
merge=$here/skills/org-close/scripts/merge-local.sh
delegate=$here/skills/org-delegate/scripts/org-delegate.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

[ -f "$mk" ]; check "local-repo.sh exists" $?
[ -f "$merge" ]; check "merge-local.sh exists" $?
bash -n "$mk" 2>/dev/null && bash -n "$merge" 2>/dev/null; check "scripts parse" $?
bash "$mk" --help >/dev/null 2>&1 && bash "$merge" --help >/dev/null 2>&1; check "--help exits 0" $?

local_dir=$tmp/local
export PADDOCK_LOCAL_DIR=$local_dir PADDOCK_WORKERS_DIR=$tmp/workers PADDOCK_STATE_DIR=$tmp/state \
       PADDOCK_CORE_SOCKET_DIR=$tmp/sock HOME=$tmp/home
mkdir -p "$HOME"
unset PADDOCK_ORG_ID PADDOCK_SECRETARY_NAME GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null   # a machine with no user.name / user.email

# Create: one repository per task id, main branch, one empty commit, no origin.
out=$(bash "$mk" --task-id r1 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "$local_dir/r1" ]; check "creates \$PADDOCK_LOCAL_DIR/<id> and prints its path ($out)" $?
repo=$local_dir/r1
[ "$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)" = main ]; check "branch is main" $?
[ "$(git -C "$repo" rev-list --count HEAD 2>/dev/null)" = 1 ] && [ -z "$(git -C "$repo" show --format= --name-only HEAD)" ]; check "one empty commit" $?
[ -d "$repo/.git" ] && [ -z "$(git -C "$repo" remote)" ]; check "no remote" $?
[ -d "$repo/.git" ] && ! bash "$mk" --task-id r1 >/dev/null 2>&1; check "an existing repository is refused" $?
bash "$mk" --task-id 'Bad Id' >/dev/null 2>&1; [ $? -eq 2 ] && [ -f "$mk" ]; check "a bad task id exits 2" $?
rel=$(PADDOCK_LOCAL_DIR=relative bash "$mk" --task-id r9 2>&1); [ $? -eq 2 ] && [ -f "$mk" ]; check "a relative PADDOCK_LOCAL_DIR exits 2" $?
HOME=$tmp/home2 PADDOCK_LOCAL_DIR= bash "$mk" --task-id r2 >/dev/null 2>&1
[ -d "$tmp/home2/paddock-local/r2/.git" ]; check "default folder is ~/paddock-local" $?

# Delegate as today: stub hc, real org-delegate against the new repository.
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
chmod +x "$stubdir/hc"; export PATH="$stubdir:$PATH"
bash "$delegate" --project "$repo" --task-id r1 --task "write a note" >"$tmp/d.out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ -d "$PADDOCK_WORKERS_DIR/r1" ] && [ "$(cat "$PADDOCK_STATE_DIR/bases/r1")" = main ]; check "org-delegate runs in it with no origin, base main recorded" $?

# Close with no PR: the worker commits on its branch; merge-local fast-forwards main.
wt=$PADDOCK_WORKERS_DIR/r1
echo hello > "$wt/note.txt"; git -C "$wt" add note.txt
git -C "$wt" -c user.name=w -c user.email=w@w.invalid commit -q -m "note"
out=$(bash "$merge" --task r1 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -f "$repo/note.txt" ] && [ "$(git -C "$repo" rev-parse main)" = "$(git -C "$wt" rev-parse HEAD)" ]; check "merge-local fast-forwards main to the worker branch ($out)" $?

# Refusals: uncommitted work, a diverged branch, a repository outside the local folder.
bash "$mk" --task-id r3 >/dev/null; bash "$delegate" --project "$local_dir/r3" --task-id r3 --task t >/dev/null 2>&1
echo x > "$PADDOCK_WORKERS_DIR/r3/a.txt"; git -C "$PADDOCK_WORKERS_DIR/r3" add a.txt
[ -f "$merge" ] && ! bash "$merge" --task r3 >/dev/null 2>&1 && [ ! -f "$local_dir/r3/a.txt" ]; check "uncommitted work in the worktree is refused" $?
git -C "$PADDOCK_WORKERS_DIR/r3" -c user.name=w -c user.email=w@w.invalid commit -q -m a
git -C "$local_dir/r3" -c user.name=o -c user.email=o@o.invalid commit -q --allow-empty -m diverge
[ -f "$merge" ] && ! bash "$merge" --task r3 >/dev/null 2>&1 && [ ! -f "$local_dir/r3/a.txt" ]; check "a branch that is not ahead of main alone (diverged) is refused, no merge commit" $?

outside=$tmp/outside; git init -q -b main "$outside"
git -C "$outside" -c user.name=t -c user.email=t@t.invalid commit -q --allow-empty -m init
bash "$delegate" --project "$outside" --task-id r4 --task t >/dev/null 2>&1
git -C "$PADDOCK_WORKERS_DIR/r4" -c user.name=w -c user.email=w@w.invalid commit -q --allow-empty -m w
[ -f "$merge" ] && ! bash "$merge" --task r4 >/dev/null 2>&1 && [ "$(git -C "$outside" rev-list --count main)" = 1 ]; check "a project outside \$PADDOCK_LOCAL_DIR is never merged" $?

[ "$fail" -eq 0 ] && echo "all passed"
exit "$fail"
