#!/usr/bin/env bash
# Regression test for Issue #263: git 2.43 fails with "failed to read .git/worktrees/<n>/commondir"
# when `git worktree add` runs in one repository at the same time as another one (the second reads the
# new entry before git has written it). Seen on CI as org-delegate exit 6 when several delegates ran at
# once. A git wrapper on PATH records overlapping `worktree add` runs (and stretches each one, so the
# overlap is certain); delegates started together must not overlap, and must all succeed.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
delegate=$here/skills/org-delegate/scripts/org-delegate.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
real_git=$(command -v git)

mkdir -p "$tmp/bin" "$tmp/inflight" "$tmp/stub"
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
cat > "$tmp/bin/git" <<EOF2
#!/bin/sh
case "\$*" in
  *" worktree add "*)
    : > "$tmp/inflight/\$\$"
    [ "\$(ls "$tmp/inflight" | wc -l)" -le 1 ] || : > "$tmp/overlap"
    sleep 0.3
    "$real_git" "\$@"; r=\$?
    rm -f "$tmp/inflight/\$\$"
    exit \$r ;;
esac
exec "$real_git" "\$@"
EOF2
chmod +x "$tmp/bin/hc" "$tmp/bin/git"

proj=$tmp/project
git init -q -b main "$proj" 2>/dev/null || { git init -q "$proj"; git -C "$proj" checkout -q -b main; }
git -C "$proj" -c user.name=t -c user.email=t@t.invalid commit -q --allow-empty -m init
export PADDOCK_STATE_DIR=$tmp/state PADDOCK_WORKERS_DIR=$tmp/workers PADDOCK_CORE_SOCKET_DIR=$tmp/sock \
       PATH="$tmp/bin:$PATH"
unset PADDOCK_ORG_ID PADDOCK_SECRETARY_NAME

pids=
for i in 1 2 3 4 5 6; do
  bash "$delegate" --project "$proj" --task-id t$i --task "do $i" >/dev/null 2>"$tmp/err-$i" & pids="$pids $!"
done
bad=0; for p in $pids; do wait "$p" || bad=$((bad + 1)); done
[ ! -e "$tmp/overlap" ]; check "no two git worktree add runs overlap" $?
[ "$bad" -eq 0 ]; check "all six delegates succeed ($bad failed)" $?
exit $fail
