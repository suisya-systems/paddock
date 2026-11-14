#!/usr/bin/env bash
# Acceptance test for Issue #324: a killed worker's leftover 0-byte read-only <git-common-dir>/config.lock
# placeholder is removed when org-down / org-resume end the worker, and only when it is safe. Needs only
# bash, coreutils and git: hc is the stub of tests/hc-stub.sh, the project is a throw-away git repository
# with linked worktrees, and "a running command of a worker" is a background shell whose cwd is the worktree.
. "$(dirname "${BASH_SOURCE[0]}")/hc-stub.sh"
down=$here/skills/org-down/scripts/org-down.sh
resume=$here/skills/org-resume/scripts/org-resume.sh
proj=$tmp/proj; workers=$tmp/workers; common=$proj/.git; lock=$common/config.lock
logf=$tmp/state/removed-locks.log
holders=
trap 'for p in $holders; do kill "$p" 2>/dev/null; done; rm -rf "$tmp"' EXIT

mkproj() { # a clone with linked worktrees of t1 (the worker that is ended), t2 and t3
  rm -rf "$proj" "$workers"; git init -q -b main "$proj" 2>/dev/null || { git init -q "$proj"; git -C "$proj" checkout -q -b main; }
  git -C "$proj" -c user.name=t -c user.email=t@t.invalid commit -q --allow-empty -m init
  mkdir -p "$workers"
  for t in t1 t2 t3; do git -C "$proj" worktree add -q -b "b-$t" "$workers/$t" >/dev/null 2>&1; done
  rm -f "$lock"
}
placeholder() { rm -f "$lock"; : > "$lock"; chmod 444 "$lock"; }   # what Claude Code's sandbox leaves
hold() { # hold <task>: a command of that worker still running (cwd in its worktree) until release
  rel=$tmp/release-$1; rm -f "$rel"
  ( cd "$workers/$1" && exec bash -c 'until [ -f "$1" ]; do sleep 0.1; done' _ "$rel" ) &
  holders="$holders $!"; hpid=$!
}
release() { : > "$tmp/release-$1"; wait "$2" 2>/dev/null; }
doc_for() { # doc_for <task...>: an org-state work list naming these tasks' worktrees
  local w= t; for t in "$@"; do w="$w${w:+,}{\"task_id\":\"$t\",\"title\":\"T\",\"since\":\"2026-11-10T01:00:00Z\",\"worktree\":\"$workers/$t\",\"task\":\"do $t\"}"; done
  printf '{"jsonrpc":"2.0","id":1,"result":{"value":{"work":[%s],"approvals":[]},"version":3}}\n' "$w" > "$tmp/stub/doc"
}
ENVW="PADDOCK_WORKERS_DIR=$workers PADDOCK_LOCK_WAIT=1"
[ "$(id -u)" -ne 0 ]; check "the test runs as a non-root user (root can write a mode 444 file)" $?

# 1. org-down: the placeholder is removed, and recorded.
mkproj; reset; doc_for t1; term w-t1 t1; placeholder
out=$(ENVX="$ENVW" run_script "$down"); rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$lock" ]; check "org-down removes a 0-byte read-only config.lock after the kill ($out)" $?
grep -q "$lock" <<<"$out" && grep -q "$lock" "$logf" 2>/dev/null; check "what was removed is printed and recorded in the state folder" $?
k=$(line '^rm w-t1'); [ -n "$k" ]; check "the terminal was ended (hc rm ran)" $?

# 2. No placeholder: nothing is said, nothing fails.
mkproj; reset; doc_for t1; term w-t1 t1
out=$(ENVX="$ENVW" run_script "$down"); rc=$?
[ "$rc" -eq 0 ] && ! grep -qi 'config.lock' <<<"$out" && [ ! -e "$logf" ]; check "no placeholder: exit 0, no lock message, no record ($out)" $?

# 3. A real git lock is never removed: it has content, or it is writable.
mkproj; reset; doc_for t1; term w-t1 t1; echo x > "$lock"; chmod 444 "$lock"
ENVX="$ENVW" run_script "$down" >/dev/null
[ -s "$lock" ]; check "a lock with content (size > 0) stays" $?
mkproj; reset; doc_for t1; term w-t1 t1; : > "$lock"
ENVX="$ENVW" run_script "$down" >/dev/null
[ -e "$lock" ]; check "a 0-byte lock that is writable stays" $?
mkproj; reset; doc_for t1; term w-t1 t1; mkdir "$lock"
ENVX="$ENVW" run_script "$down" >/dev/null
[ -d "$lock" ]; check "a config.lock that is not a regular file stays" $?

# 4. A command of the killed worker is still running: not removed, said so.
mkproj; reset; doc_for t1; term w-t1 t1; placeholder; hold t1; p=$hpid
out=$(ENVX="$ENVW" run_script "$down"); rc=$?
[ "$rc" -eq 0 ] && [ -e "$lock" ] && grep -qi 'still running' <<<"$out" && grep -q "$lock" <<<"$out"; check "a process still in the killed worker's worktree: lock stays and is reported ($out)" $?
[ ! -e "$logf" ]; check "nothing is recorded as removed in that case" $?
release t1 "$p"
# ... and once it has ended, the next run removes it (the placeholder stays after the orphan ends, as measured).
reset; doc_for t1; term w-t1 t1
out=$(ENVX="$ENVW" run_script "$down"); rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$lock" ]; check "after the worker's command has ended, the lock is removed ($out)" $?

# 5. Another live worker uses the same clone: not removed, reported.
mkproj; reset; doc_for t1; term w-t1 t1; placeholder; hold t3; p=$hpid
out=$(ENVX="$ENVW" run_script "$down"); rc=$?
[ "$rc" -eq 0 ] && [ -e "$lock" ] && grep -qi 'another' <<<"$out" && grep -q "$lock" <<<"$out"; check "another live worker in the same clone: lock stays and is reported ($out)" $?
release t3 "$p"

# 6. org-down ends several workers of one clone: swept once, after all of them are ended.
mkproj; reset; doc_for t1 t2; term w-t1 t1; term w-t2 t2; placeholder
out=$(ENVX="$ENVW" run_script "$down"); rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$lock" ] && [ "$(grep -c "$lock" "$logf")" -eq 1 ]; check "two workers of one clone ended: removed once, recorded once ($out)" $?

# 7. org-resume ends a labelled terminal that has no status, then relaunches: the placeholder goes first.
mkproj; reset; doc_for t1; term w-t1 t1; echo none > "$tmp/stub/state-w-t1"; placeholder
out=$(ENVX="$ENVW" run_script "$resume" --apply); rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$lock" ] && grep -q "$lock" "$logf" 2>/dev/null; check "org-resume --apply removes the leftover placeholder of the terminal it ended ($out)" $?
k=$(line '^kill w-t1'); n=$(line '^run '); [ -n "$k" ] && [ -n "$n" ] && [ "$k" -lt "$n" ]; check "it is removed between the kill and the relaunch order (kill first)" $?
mkproj; reset; doc_for t1; term w-t1 t1; placeholder; hold t1; p=$hpid
out=$(ENVX="$ENVW" run_script "$resume"); rc=$?
[ -e "$lock" ]; check "the org-resume plan (no --apply) removes nothing" $?
release t1 "$p"
exit $fail
