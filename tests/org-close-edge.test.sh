#!/usr/bin/env bash
# Edge cases for skills/org-close/scripts/org-close.sh (Issue #184, Codex review). Needs only bash,
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
# A done from an earlier, dropped delegation of the same id does not close the new worker.
reset; delegate t1; worker_report t1
PADDOCK_NOW=2026-11-10T00:00:00Z bash "$org" --as w-t1 report done --task t1 "old" >/dev/null
rm -f "$PADDOCK_STATE_DIR"/events/*/w-t1.jsonl
PADDOCK_NOW=2026-11-10T00:00:00Z bash "$org" --as w-t1 report done --task t1 "old" >/dev/null
PADDOCK_NOW=2026-11-10T05:00:00Z bash "$org" --as secretary report start --task t1 "again" >/dev/null
close --task t1 >/dev/null; rc=$?
[ "$rc" -ne 0 ] && ! ended; check "a done older than the latest start ends nothing" $?

# Spaces between work entries do not make a neighbour disappear; retry after the terminal is gone.
reset; delegate t1; worker_report t1
printf '%s\n' '{"work":[{"task_id":"t1","title":"Alpha"}, {"task_id":"t2","title":"Beta"}],"approvals":[]}' > "$STUB/docval"
rm -f "$STUB/term-w-t1"
close --task t1 >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ! doc | grep -q Alpha && doc | grep -q Beta; check "whitespace between entries; a gone terminal still lets the entry go" $?

exit $fail
