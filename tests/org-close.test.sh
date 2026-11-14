#!/usr/bin/env bash
# Acceptance test for skills/org-close/scripts/org-close.sh (Issue #184). Needs only bash,
# coreutils and git: hc is a stub on PATH, so no core runs. The project is a real throwaway git
# repository; scripts/org and org-delegate are the real ones, writing under a throwaway state dir.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-close/scripts/org-close.sh
delegate=$here/skills/org-delegate/scripts/org-delegate.sh
org=$here/scripts/org
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

[ -f "$script" ]; check "script exists" $?
[ -f "$here/skills/org-close/SKILL.md" ]; check "SKILL.md exists" $?
bash -n "$script" 2>/dev/null; check "script parses" $?

# Stub hc. "term-<name>" in $STUB exists while a terminal of that name exists and holds its
# task_id label. Documents: docval-org-state / docver-org-state. Every call goes to $STUB/calls.
stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/calls"
cmd=$1; shift
name=; label=; prev=
for a in "$@"; do
  case "$prev" in --name) name=$a ;; --label) label=${a#task_id=} ;; esac
  case "$a" in --*) ;; *) [ "$cmd" = run ] || name=$a ;; esac
  prev=$a
done
case "$cmd" in
  ls) echo '[]'; exit 0 ;;
  get) [ -f "$STUB/term-$name" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       lab=$(cat "$STUB/term-$name"); l='{}'; [ -z "$lab" ] || l="{\"task_id\":\"$lab\"}"
       printf '{\n  "name": "%s",\n  "state": "live",\n  "labels": %s,\n  "status": null\n}\n' "$name" "$l"; exit 0 ;;
  kill) [ -f "$STUB/term-$name" ] || exit 1; echo '{"killed":true}'; exit 0 ;;
  rm) rm -f "$STUB/term-$name"; echo '{"removed":true}'; exit 0 ;;
  file) shift; path=; for a in "$@"; do case "$a" in --*) ;; *) path=$a ;; esac; done
        mkdir -p "$(dirname "$path")" && cat > "$path"; echo '{"written":true}'; exit 0 ;;
  run) printf '%s' "$label" > "$STUB/term-$name"
       echo '{"first_message":{"sent":true,"started":true,"turn":0}}'; exit 0 ;;
  connect)
    read -r req
    method=$(printf '%s' "$req" | sed 's/.*"method":"\([^"]*\)".*/\1/')
    ver() { cat "$STUB/docver" 2>/dev/null || echo 0; }
    case "$method" in
      doc.get) printf '{"jsonrpc":"2.0","id":1,"result":{"value":%s,"version":%s}}\n' "$(cat "$STUB/docval" 2>/dev/null || echo null)" "$(ver)" ;;
      doc.set) v=$(printf '%s' "$req" | sed 's/.*"version":\([0-9]*\)}}$/\1/')
               printf '%s' "$req" | sed 's/.*"value":\(.*\),"version":[0-9]*}}$/\1/' > "$STUB/docval"
               echo $(( v + 1 )) > "$STUB/docver"
               printf '{"jsonrpc":"2.0","id":1,"result":{"version":%s}}\n' "$(ver)" ;;
    esac
    exit 0 ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"

proj=$tmp/project
git init -q -b main "$proj" 2>/dev/null || { git init -q "$proj"; git -C "$proj" checkout -q -b main; }
git -C "$proj" -c user.name=t -c user.email=t@t.invalid commit -q --allow-empty -m init
workers=$tmp/workers
export STUB=$tmp/stub PADDOCK_STATE_DIR=$tmp/state PADDOCK_HC_HOLD=0 PADDOCK_WORKERS_DIR=$workers \
       PADDOCK_CORE_SOCKET_DIR=$tmp/sock PATH="$stubdir:$PATH"
unset PADDOCK_ORG_ID PADDOCK_SECRETARY_NAME
calls=$STUB/calls

reset() {
  rm -rf "$STUB" "$workers" "$PADDOCK_STATE_DIR"; mkdir -p "$STUB"; : > "$calls"
  git -C "$proj" worktree prune
  git -C "$proj" for-each-ref --format='%(refname:short)' refs/heads | grep -Ev '^main$' \
    | while read -r b; do git -C "$proj" branch -q -D "$b"; done
  cat > "$STUB/docval" <<'EOF3'
{"work":[{"task_id":"t1","title":"Alpha","since":"2026-11-10T01:00:00Z"},{"task_id":"t2","title":"Beta","since":"2026-11-10T02:00:00Z"}],"approvals":[{"id":"t1-x","task_id":"t1","question":"ok?","asked_at":"2026-11-10T01:00:00Z","answer_in":"secretary"}]}
EOF3
  return 0
}
delegate() { bash "$delegate" --project "$proj" --task-id "$1" --task "do $1" >/dev/null 2>&1; }
worker_report() { bash "$org" --as "w-$1" report done --task "$1" "${@:2}" "finished $1" >/dev/null; }
close() { bash "$script" "$@" 2>&1; }
ended() { grep -Eq '^(kill|rm) ' "$calls"; }
doc() { cat "$STUB/docval"; }

# A done sent to someone else ends nothing.
reset; delegate t1
bash "$org" --as w-t1 report done --task t1 --to other "finished" >/dev/null
out=$(close --task t1); rc=$?
[ "$rc" -ne 0 ] && ! ended && [ -f "$STUB/term-w-t1" ]; check "a done sent to someone else ends nothing ($out)" $?

# No done at all: same.
reset; delegate t1
close --task t1 >/dev/null; rc=$?
[ "$rc" -ne 0 ] && ! ended; check "no done record ends nothing" $?

# A done from another worker for the same task id does not count.
reset; delegate t1
bash "$org" --as w-t2 report done --task t1 "not the worker" >/dev/null
close --task t1 >/dev/null; rc=$?
[ "$rc" -ne 0 ] && ! ended; check "a done written by another id ends nothing" $?

# The terminal must carry the task label.
reset; delegate t1; worker_report t1; printf '' > "$STUB/term-w-t1"
close --task t1 >/dev/null; rc=$?
[ "$rc" -ne 0 ] && ! ended && [ -f "$STUB/term-w-t1" ]; check "a terminal without the task_id label is not ended" $?
reset; delegate t1; worker_report t1; printf 't2' > "$STUB/term-w-t1"
close --task t1 >/dev/null; rc=$?
[ "$rc" -ne 0 ] && ! ended; check "a terminal with another task_id label is not ended" $?

# Happy path: done to the secretary, labelled terminal.
reset; delegate t1; worker_report t1
out=$(close --task t1); rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$STUB/term-w-t1" ]; check "done to the secretary: terminal killed and removed ($out)" $?
k=$(grep -n '^kill ' "$calls" | head -1 | cut -d: -f1); r=$(grep -n '^rm ' "$calls" | head -1 | cut -d: -f1)
[ -n "$k" ] && [ -n "$r" ] && [ "$k" -lt "$r" ]; check "kill comes before rm" $?
! doc | grep -q '"title":"Alpha"' && doc | grep -q '"title":"Beta"'; check "only the work entry of the task is removed" $?
doc | grep -q '"id":"t1-x"'; check "approvals of the task are left alone" $?
[ -d "$workers/t1" ] && git -C "$proj" rev-parse --verify -q work/t1 >/dev/null; check "worktree and branch stay after a plain close" $?

# --drop ends a worker with no report and removes worktree, branch and work entry.
reset; delegate t1
out=$(close --task t1 --drop); rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$STUB/term-w-t1" ] && [ ! -e "$workers/t1" ]; check "--drop removes terminal and worktree ($out)" $?
! git -C "$proj" rev-parse --verify -q work/t1 >/dev/null; check "--drop removes the unused branch" $?
! doc | grep -q '"title":"Alpha"'; check "--drop removes the work entry" $?
delegate t1; rc=$?
[ -f "$STUB/term-w-t1" ] && [ -d "$workers/t1" ]; check "after --drop the same task id delegates again" $?

# --drop of a launch that left no terminal still cleans up.
reset; delegate t1; rm -f "$STUB/term-w-t1"
close --task t1 --drop >/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$workers/t1" ] && ! git -C "$proj" rev-parse --verify -q work/t1 >/dev/null; check "--drop with no terminal removes worktree and branch" $?

# --drop keeps a branch that has a commit beyond its base.
reset; delegate t1
git -C "$workers/t1" -c user.name=t -c user.email=t@t.invalid commit -q --allow-empty -m work
close --task t1 --drop >/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$workers/t1" ] && git -C "$proj" rev-parse --verify -q work/t1 >/dev/null; check "--drop keeps a branch with a commit beyond its base" $?

# --drop never touches a terminal that carries another task's label.
reset; delegate t1; printf 't2' > "$STUB/term-w-t1"
close --task t1 --drop >/dev/null; rc=$?
[ "$rc" -ne 0 ] && ! ended && [ -d "$workers/t1" ]; check "--drop refuses a terminal labelled for another task" $?

# Arguments.
reset
close >/dev/null; [ $? -eq 2 ]; check "no --task exits 2" $?
close --task 'Bad Id' >/dev/null; [ $? -eq 2 ]; check "bad task id exits 2" $?
close --task t1 --nope >/dev/null; [ $? -eq 2 ]; check "unknown argument exits 2" $?
bash "$script" --help 2>&1 | grep -qi usage; check "--help prints usage" $?

# Issue #324: the killed worker's leftover 0-byte read-only config.lock placeholder is removed, only when safe.
lock=$proj/.git/config.lock
placeholder() { rm -f "$lock"; : > "$lock"; chmod 444 "$lock"; }
export PADDOCK_LOCK_WAIT=1
rm -f "$lock"; reset; delegate t1; worker_report t1; placeholder
out=$(close --task t1); rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$lock" ] && grep -q "$lock" <<<"$out" && grep -q "$lock" "$PADDOCK_STATE_DIR/removed-locks.log"; check "close removes the leftover placeholder and records it ($out)" $?
rm -f "$lock"; reset; delegate t1; worker_report t1; placeholder
( cd "$workers/t1" && exec bash -c 'until [ -f "$1" ]; do sleep 0.1; done' _ "$tmp/rel" ) & hp=$!
out=$(close --task t1); rc=$?
[ "$rc" -eq 0 ] && [ -e "$lock" ] && grep -qi 'still running' <<<"$out"; check "a process still in the worker's worktree: lock stays and is reported ($out)" $?
: > "$tmp/rel"; wait "$hp" 2>/dev/null
rm -f "$lock"; reset; delegate t1; worker_report t1; echo x > "$proj/.git/config.lock"; chmod 444 "$lock"
close --task t1 >/dev/null
[ -s "$lock" ]; check "a lock with content stays" $?
rm -f "$lock"
exit $fail
