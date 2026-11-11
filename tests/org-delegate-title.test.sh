#!/usr/bin/env bash
# Acceptance test for org-delegate --title (Issue #182): after the launch the work entry
# (task_id, title, since, worktree, task) is in org-state, and a task text with braces,
# brackets and quotes survives org-suspend then org-resume. Needs only bash, coreutils and
# git: hc is a stub on PATH (a stateful org-state document, terminals with labels).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
delegate=$here/skills/org-delegate/scripts/org-delegate.sh
suspend=$here/skills/org-suspend/scripts/org-suspend.sh
resume=$here/skills/org-resume/scripts/org-resume.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
# State in $STUB: docval/docver (org-state), term-<name> (the task_id label), calls.
echo "$*" >> "$STUB/calls"
cmd=$1; shift
case "$cmd" in
  ls) first=1; printf '['
      for f in "$STUB"/term-*; do [ -e "$f" ] || continue
        [ -n "$first" ] || printf ','; first=; printf '{"name":"%s"}' "${f##*/term-}"; done
      printf ']\n'; exit 0 ;;
  get) name=; for a in "$@"; do case "$a" in --*) ;; *) name=$a ;; esac; done
       [ -f "$STUB/term-$name" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       printf '{\n  "name": "%s",\n  "state": "live",\n  "labels": {"task_id":"%s"},\n  "status": {"app":"claude-code","state":"idle"}\n}\n' "$name" "$(cat "$STUB/term-$name")"; exit 0 ;;
  file) shift; path=; for a in "$@"; do case "$a" in --*) ;; *) path=$a ;; esac; done
        mkdir -p "$(dirname "$path")" && cat > "$path"; echo '{"written":true}'; exit 0 ;;
  connect) req=$(cat)
        v=$(cat "$STUB/docval" 2>/dev/null || echo null); n=$(cat "$STUB/docver" 2>/dev/null || echo 0)
        case "$req" in
          *'"doc.set"'*) printf '%s' "$req" | sed 's/.*"value": *\(.*\), *"version": *[0-9]*}}$/\1/' > "$STUB/docval"
                         echo $((n + 1)) > "$STUB/docver"; printf "%s\n" "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"version\":$((n + 1))}}" ;;
          *) printf "%s\n" "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"value\":$v,\"version\":$n}}" ;;
        esac; exit 0 ;;
  run) name=; lab=; prev=; last=
       for a in "$@"; do case "$prev" in --name) name=$a ;; --label) lab=${a#task_id=} ;; esac; prev=$a; last=$a; done
       printf '%s' "$last" > "$STUB/last-run-text"
       printf '%s' "$lab" > "$STUB/term-$name"
       echo '{"first_message":{"sent":true,"started":true,"turn":0}}'; exit 0 ;;
  kill) exit 0 ;;
  rm) shift 0; for a in "$@"; do rm -f "$STUB/term-$a"; done; exit 0 ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"

proj=$tmp/project
git init -q -b main "$proj" 2>/dev/null || { git init -q "$proj"; git -C "$proj" checkout -q -b main; }
git -C "$proj" -c user.name=t -c user.email=t@t.invalid commit -q --allow-empty -m init
workers=$tmp/workers
mkdir -p "$tmp/stub"; : > "$tmp/stub/calls"
run() { # run <script> <args...>
  local s=$1; shift
  env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET \
      -u CLAUDE_CODE_MESSAGING_TOKEN -u PADDOCK_ORG_ID -u HC_TERMINAL_SOCKET \
      PADDOCK_CORE_SOCKET_DIR="$tmp/run/herdr-core" STUB="$tmp/stub" PATH="$stubdir:$PATH" PADDOCK_WORKERS_DIR="$workers" \
      PADDOCK_STATE_DIR="$tmp/state" PADDOCK_NOW=2026-11-10T01:02:03Z PADDOCK_HC_HOLD=0 PADDOCK_READY_TRIES=1 \
      bash "$s" "$@" 2>&1
}
doc() { cat "$tmp/stub/docval" 2>/dev/null; }

# Without --title nothing is written to org-state.
out=$(run "$delegate" --project "$proj" --task-id t0 --task "Plain task."); rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$tmp/stub/docval" ]; check "no --title: the worker starts and org-state is not touched ($rc)" $?

# With --title: the entry is there, all five fields.
task1='Add {"k": [1, 2]} to the config, then handle a } , { case. Path C:\tmp\x. Keep going.'
out=$(run "$delegate" --project "$proj" --task-id t1 --title "Config {braces}" --task "$task1"); rc=$?
[ "$rc" -eq 0 ]; check "--title: org-delegate exits 0 ($rc)" $?
d=$(doc)
grep -q '"task_id": *"t1"' <<<"$d" && grep -q '"title": *"Config {braces}"' <<<"$d" \
  && grep -q '"since": *"2026-11-10T01:02:03Z"' <<<"$d" && grep -q "\"worktree\": *\"$workers/t1\"" <<<"$d" \
  && grep -q '"task": *"' <<<"$d"; check "org-state holds task_id, title, since, worktree and task" $?
grep -q '"work": *\[' <<<"$d"; check "the entry is in the work array" $?

# A second delegation adds to the list and keeps the first entry.
run "$delegate" --project "$proj" --task-id t2 --title "Second" --task "Do beta." >/dev/null; rc=$?
d=$(doc)
[ "$rc" -eq 0 ] && grep -q '"task_id": *"t1"' <<<"$d" && grep -q '"task_id": *"t2"' <<<"$d"; check "a second --title run keeps the first entry and adds its own ($rc)" $?

# Suspend, lose t1's terminal, resume: the task text comes back exactly.
out=$(run "$suspend"); rc=$?
[ "$rc" -eq 0 ]; check "org-suspend reads the entry with braces in its task ($rc)" $?
rm -f "$tmp/stub/term-w-t1"
out=$(run "$resume" --apply); rc=$?
[ "$rc" -eq 0 ] && grep -q 'resumed' <<<"$out"; check "org-resume --apply relaunches t1 ($rc)" $?
[ "$(cat "$tmp/stub/last-run-text")" = "$task1" ]; check "the relaunch carries the task text unchanged" $?

# Same without a suspend record (resume from the work list).
rm -f "$tmp/state/suspend.record" "$tmp/stub/term-w-t1"
out=$(run "$resume" --apply); rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$tmp/stub/last-run-text")" = "$task1" ]; check "from the work list alone, the task text is also unchanged ($rc)" $?

[ "$fail" -eq 0 ]
