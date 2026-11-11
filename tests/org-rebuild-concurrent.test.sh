#!/usr/bin/env bash
# Regression test for Issue #77: close and delegate running at the same time must leave a history
# that `org rebuild` replays into the document the live system has. The org-state write and its
# history line share one lock, so the replay order is the write order. Real org-delegate,
# org-close and scripts/org with a stub hc; the same shape as tests/org-rebuild.test.sh.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
org=$here/scripts/org
delegate=$here/skills/org-delegate/scripts/org-delegate.sh
close=$here/skills/org-close/scripts/org-close.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
cmd=$1; shift
name=; label=; prev=
for a in "$@"; do
  case "$prev" in --name) name=$a ;; --label) label=${a#task_id=} ;; esac
  case "$a" in --*) ;; *) [ "$cmd" = run ] || name=$a ;; esac
  prev=$a
done
case "$cmd" in
  get) [ -f "$STUB/term-$name" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       printf '{\n  "name": "%s",\n  "state": "live",\n  "labels": {"task_id":"%s"},\n  "status": null\n}\n' "$name" "$(cat "$STUB/term-$name")"; exit 0 ;;
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
    # a slow core widens the window between the document write and anything after it
    case "$method" in
      doc.get) printf '{"jsonrpc":"2.0","id":1,"result":{"value":%s,"version":%s}}\n' "$(cat "$STUB/docval" 2>/dev/null || echo null)" "$(ver)" ;;
      doc.set) v=$(printf '%s' "$req" | sed 's/.*"version":\([0-9]*\)}}$/\1/')
               [ "$v" = "$(ver)" ] || { echo '{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"conflict"}}'; exit 0; }
               printf '%s' "$req" | sed 's/.*"value":\(.*\),"version":[0-9]*}}$/\1/' > "$STUB/docval.new" && mv -f "$STUB/docval.new" "$STUB/docval"
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
mkdir -p "$STUB"
add() { bash "$delegate" --project "$proj" --task-id "$1" --title "T $1" --task "do $1" >/dev/null 2>&1; }

# Four tasks that are done; then close them while four new ones are delegated, in two rounds.
for r in a b; do
  for i in 1 2 3 4; do add $r$i; bash "$org" --as w-$r$i report done --task $r$i "finished" >/dev/null; done
  pids=
  for i in 1 2 3 4; do bash "$close" --task $r$i >/dev/null 2>&1 & pids="$pids $!"; done
  for i in 1 2 3 4; do add n$r$i & pids="$pids $!"; done
  wait $pids
done
live=$(cat "$STUB/docval")
for i in 1 2 3 4; do echo "$live" | grep -q "\"task_id\":\"na$i\"" && echo "$live" | grep -q "\"task_id\":\"nb$i\""; done
check "the live document holds the eight delegated tasks" $?
! echo "$live" | grep -q '"task_id":"[ab][1-4]"'; check "the live document holds none of the closed tasks" $?

out=$(bash "$org" --as secretary rebuild --print 2>&1)
[ "$out" = "$live" ]; check "rebuild gives the document the live system has" $?
exit $fail
