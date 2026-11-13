#!/usr/bin/env bash
# Issue #263: a worktree lock left by a dead org-delegate (its pid is gone) is broken, not waited on forever.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
delegate=$here/skills/org-delegate/scripts/org-delegate.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
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
proj=$tmp/project
git init -q -b main "$proj" 2>/dev/null || { git init -q "$proj"; git -C "$proj" checkout -q -b main; }
git -C "$proj" -c user.name=t -c user.email=t@t.invalid commit -q --allow-empty -m init
sh -c 'echo $$' > "$tmp/deadpid"; mkdir "$proj/.git/paddock-worktree.lock"; cp "$tmp/deadpid" "$proj/.git/paddock-worktree.lock/pid"
PADDOCK_STATE_DIR=$tmp/state PADDOCK_WORKERS_DIR=$tmp/workers PADDOCK_CORE_SOCKET_DIR=$tmp/sock PATH="$tmp/bin:$PATH" \
  timeout 30 bash "$delegate" --project "$proj" --task-id t1 --task "do 1" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$proj/.git/paddock-worktree.lock" ]; then echo "ok   a lock of a dead pid is broken (exit $rc)"; exit 0; fi
echo "FAIL a lock of a dead pid is broken (exit $rc)"; exit 1
