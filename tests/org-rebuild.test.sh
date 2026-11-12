#!/usr/bin/env bash
# Acceptance test for `org rebuild` (Issue #77): one command reads the history files and rewrites
# org-state; run on a copy of a day's history it gives the document the live system had. The day is
# made by the real org-delegate, org-escalation, org-close and scripts/org, with a stub hc.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
org=$here/scripts/org
delegate=$here/skills/org-delegate/scripts/org-delegate.sh
esc=$here/skills/org-escalation/scripts/org-escalation.sh
close=$here/skills/org-close/scripts/org-close.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

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
  get) [ -f "$STUB/term-$name" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       lab=$(cat "$STUB/term-$name")
       printf '{\n  "name": "%s",\n  "state": "live",\n  "labels": {"task_id":"%s"},\n  "status": null\n}\n' "$name" "$lab"; exit 0 ;;
  kill) echo '{"killed":true}'; exit 0 ;;
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
export STUB=$tmp/stub PADDOCK_STATE_DIR=$tmp/state PADDOCK_HC_HOLD=0 PADDOCK_WORKERS_DIR=$tmp/workers \
       PADDOCK_CORE_SOCKET_DIR=$tmp/sock PATH="$stubdir:$PATH"
unset PADDOCK_ORG_ID PADDOCK_SECRETARY_NAME
mkdir -p "$STUB"; : > "$STUB/calls"
sec() { bash "$org" --as secretary "$@"; }

# A day: three tasks (one title with brackets, braces, quotes), two questions, one answered, one task done and closed.
export PADDOCK_NOW=2026-11-10T01:00:00Z
bash "$delegate" --project "$proj" --task-id t1 --title "Alpha" --task "do t1" >/dev/null 2>&1
export PADDOCK_NOW=2026-11-10T02:00:00Z
bash "$delegate" --project "$proj" --task-id t2 --title 'Beta [x] {y} "q" \z' --task 'do t2: a "quote", a ] and a }' >/dev/null 2>&1
bash "$delegate" --project "$proj" --task-id t3 --title "Gamma" --task "do t3" >/dev/null 2>&1
export PADDOCK_NOW=2026-11-10T03:00:00Z
bash "$esc" ask --task t1 --question 'Run "npm publish"?' >/dev/null 2>&1
export PADDOCK_NOW=2026-11-10T04:00:00Z
bash "$esc" ask --task t2 --question 'Allow it?' >/dev/null 2>&1
export PADDOCK_NOW=2026-11-10T05:00:00Z
bash "$esc" answer --id t1-20261110T030000Z --text yes >/dev/null 2>&1
bash "$org" --as w-t3 report done --task t3 "finished" >/dev/null
bash "$close" --task t3 >/dev/null 2>&1
live=$(cat "$STUB/docval")
echo "$live" | grep -q '"task_id":"t1"' && echo "$live" | grep -q '"task_id":"t2"' && ! echo "$live" | grep -q '"task_id":"t3"' \
  && echo "$live" | grep -q 't2-20261110T040000Z' && ! echo "$live" | grep -q 't1-20261110T030000Z'
check "the day left two tasks and one question in org-state" $?

# The copy of the day's history, and a core that lost the document.
copy=$tmp/copy; cp -R "$PADDOCK_STATE_DIR" "$copy"
rm -f "$STUB/docval" "$STUB/docver"; : > "$STUB/calls"

PADDOCK_STATE_DIR=$copy sec rebuild >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; check "rebuild exits 0" $?
[ "$(cat "$STUB/docval" 2>/dev/null)" = "$live" ]; check "org-state is the document the live system had" $?

# --print shows the value and writes nothing.
rm -f "$STUB/docval" "$STUB/docver"
out=$(PADDOCK_STATE_DIR=$copy sec rebuild --print 2>&1)
[ "$out" = "$live" ] && [ ! -f "$STUB/docval" ]; check "--print prints the same document and writes nothing" $?

# Same result when run again over the same files, onto a document that is there already.
PADDOCK_STATE_DIR=$copy sec rebuild >/dev/null 2>&1
PADDOCK_STATE_DIR=$copy sec rebuild >/dev/null 2>&1
[ "$(cat "$STUB/docval")" = "$live" ]; check "running it twice gives the same document" $?

# Only the secretary writes the document.
PADDOCK_STATE_DIR=$copy bash "$org" --as w-t1 rebuild >/dev/null 2>&1; [ $? -eq 7 ]; check "a worker id exits 7" $?
PADDOCK_STATE_DIR=$copy sec rebuild --nope >/dev/null 2>&1; [ $? -eq 2 ]; check "unknown argument exits 2" $?

# No history at all: an empty document, not a failure.
out=$(PADDOCK_STATE_DIR=$tmp/none sec rebuild --print 2>&1)
[ "$out" = '{"work":[],"approvals":[]}' ]; check "no history gives empty work and approvals" $?
exit $fail
