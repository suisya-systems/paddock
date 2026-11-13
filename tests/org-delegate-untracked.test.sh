#!/usr/bin/env bash
# Issue #299: what org-delegate places in a worktree (.claude/settings.local.json) is ignored by version
# control, so a worker that stages everything does not commit it. hc is a stub on PATH.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-delegate/scripts/org-delegate.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# A user's global ignore file (Claude Code adds settings.local.json to it) must not hide the result.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME=$tmp/xdg
stubdir=$tmp/bin; mkdir -p "$stubdir" "$tmp/stub"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
cmd=$1; shift
case "$cmd" in
  get) echo '{"error":{"kind":"not_found"}}'; exit 1 ;;
  ls) echo '[]' ;;
  file) shift; path=; for a in "$@"; do case "$a" in --*) ;; *) path=$a ;; esac; done
        mkdir -p "$(dirname "$path")" && cat > "$path"; echo '{"written":true}' ;;
  run) echo '{"first_message":{"sent":true,"started":true,"turn":0}}' ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"
proj=$tmp/project
git init -q -b main "$proj" 2>/dev/null || { git init -q "$proj"; git -C "$proj" checkout -q -b main; }
git -C "$proj" -c user.name=t -c user.email=t@t.invalid commit -q --allow-empty -m init

out=$(env -u PADDOCK_ORG_ID -u HC_TERMINAL_SOCKET PADDOCK_CORE_SOCKET_DIR="$tmp/run/herdr-core" STUB="$tmp/stub" \
  PATH="$stubdir:$PATH" PADDOCK_WORKERS_DIR="$tmp/workers" PADDOCK_STATE_DIR="$tmp/state" \
  bash "$script" --project "$proj" --task-id t1 --task t 2>&1); rc=$?
[ "$rc" -eq 0 ]; check "delegation exits 0 ($out)" $?
wt=$tmp/workers/t1
[ -f "$wt/.claude/settings.local.json" ]; check "the settings file is placed" $?
[ -z "$(git -C "$wt" status --porcelain --untracked-files=all)" ]; check "a fresh worktree has no untracked file" $?
git -C "$wt" check-ignore -q .claude/settings.local.json; check "the settings file is ignored by version control" $?
exit $fail
