#!/usr/bin/env bash
# Regression cases for org-delegate found by the Codex diff review (separate from
# tests/org-delegate.test.sh, which is the declared acceptance test). hc is a stub.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-delegate/scripts/org-delegate.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/calls"
case "$1" in
  ls) echo '[]' ;;
  get) echo '{"error":{"kind":"not_found"}}'; exit 1 ;;
  file) cat >/dev/null ;;
  run) echo '{"first_message":{"sent":true,"started":true,"turn":0}}' ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"
mkdir -p "$tmp/stub"; : > "$tmp/stub/calls"
proj=$tmp/project
git init -q -b main "$proj" 2>/dev/null || { git init -q "$proj"; git -C "$proj" checkout -q -b main; }
git -C "$proj" -c user.name=t -c user.email=t@t.invalid commit -q --allow-empty -m init

# A relative workers folder would be resolved against the project by git, and against the
# caller's folder by everything else: it is refused before anything is created.
mkdir -p "$tmp/cwd"
out=$(cd "$tmp/cwd" && env STUB="$tmp/stub" PATH="$stubdir:$PATH" PADDOCK_WORKERS_DIR=workers \
  PADDOCK_STATE_DIR="$tmp/state" bash "$script" --project "$proj" --task-id t1 --task t 2>&1); rc=$?
[ "$rc" -eq 2 ] && grep -q 'absolute' <<<"$out" && [ ! -e "$tmp/cwd/workers" ] && [ ! -e "$proj/workers" ] \
  && ! grep -Eq '^(run|file) ' "$tmp/stub/calls" && [ -z "$(git -C "$proj" worktree list | sed 1d)" ]
check "a relative PADDOCK_WORKERS_DIR exits 2 and creates nothing" $?

# A path with a newline (or other control character) would make the settings JSON invalid.
for bad in $'/tmp/out\n' $'/tmp/a\nb' $'/tmp/a\tb'; do
  out=$(env STUB="$tmp/stub" PATH="$stubdir:$PATH" PADDOCK_WORKERS_DIR="$tmp/workers" PADDOCK_STATE_DIR="$tmp/state" \
    bash "$script" --project "$proj" --task-id t1 --task t --allow-write "$bad" 2>&1); rc=$?
  [ "$rc" -eq 2 ] && grep -q 'control character' <<<"$out" && [ ! -e "$tmp/workers" ]
  check "--allow-write with a control character exits 2, nothing created: $(printf '%q' "$bad")" $?
done

# The secretary template describes the recovery paths of the exit codes it can get.
t=$here/templates/secretary.md
grep -q 'Exit 12: the start record could not be written and nothing was started' "$t"; check "secretary template: exit 12 means nothing was started" $?
! grep -q 'Exit 12: the worker runs' "$t"; check "secretary template no longer calls exit 12 a running worker" $?
grep -q 'hc get w-<task_id>' "$t"; check "secretary template: exit 5 with names says to check the terminal" $?

exit $fail
