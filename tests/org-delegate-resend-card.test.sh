#!/usr/bin/env bash
# Follow-up of Issue #368 (not the declared test): the card raised when a resend fails is answerable. Yes tries again
# (resend.sh through org-escalation answer), no drops the saved message. Stubbed hc and git; no core.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
delegate=$here/skills/org-delegate/scripts/org-delegate.sh
escalation=$here/skills/org-escalation/scripts/org-escalation.sh
resend=$here/skills/org-delegate/scripts/resend.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
g() { git -c user.name=t -c user.email=t@t.invalid "$@"; }

mkdir -p "$tmp/bin" "$tmp/s" "$tmp/workers"
cat > "$tmp/bin/hc" <<'S'
#!/bin/sh
# State in $STUB: screen, screen.down, state (none|idle), noidle (the terminal never reports a status), calls, sent-text.
echo "$*" >> "$STUB/calls"
cmd=$1; shift
case "$cmd" in
  ls) echo '[]'; exit 0 ;;
  get) name=; for a in "$@"; do case "$a" in --*) ;; *) name=$a ;; esac; done
       [ -f "$STUB/term-$name" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       if [ "$(cat "$STUB/state")" = none ]; then printf '{\n  "name": "%s",\n  "status": null\n}\n' "$name"
       else printf '{\n  "name": "%s",\n  "status": {"app":"claude-code","state":"%s"}\n}\n' "$name" "$(cat "$STUB/state")"; fi
       exit 0 ;;
  file) shift; path=; for a in "$@"; do case "$a" in --*) ;; *) path=$a ;; esac; done
        mkdir -p "$(dirname "$path")" && cat > "$path"; echo '{"written":true}'; exit 0 ;;
  run) name=; prev=
       for a in "$@"; do case "$prev" in --name) name=$a ;; esac; prev=$a; done
       : > "$STUB/term-$name"; echo none > "$STUB/state"; cp "$STUB/screen.start" "$STUB/screen"
       echo '{"first_message":{"sent":false,"started":false}}'; exit 0 ;;
  read) cat "$STUB/screen" ;;
  keys) shift
        case $1 in
          down) cp "$STUB/screen.down" "$STUB/screen" ;;
          enter) if grep -q '^ ❯ Yes' "$STUB/screen" && [ ! -e "$STUB/noidle" ]; then echo idle > "$STUB/state"; fi ;;
        esac ;;
  send) printf '%s' "$2" > "$STUB/sent-text" ;;
  connect)
    read -r req
    method=$(printf '%s' "$req" | sed 's/.*"method":"\([^"]*\)".*/\1/')
    name=$(printf '%s' "$req" | sed 's/.*"name":"\([^"]*\)".*/\1/')
    ver=$(cat "$STUB/docver-$name" 2>/dev/null || echo 0)
    case "$method" in
      doc.get) printf '{"jsonrpc":"2.0","id":1,"result":{"value":%s,"version":%s}}\n' "$(cat "$STUB/docval-$name" 2>/dev/null || echo null)" "$ver" ;;
      doc.set)
        v=$(printf '%s' "$req" | sed 's/.*"version":\([0-9]*\)}}$/\1/')
        printf '%s' "$req" | sed 's/.*"value":\(.*\),"version":[0-9]*}}$/\1/' > "$STUB/docval-$name"
        echo $(( v + 1 )) > "$STUB/docver-$name"
        printf '{"jsonrpc":"2.0","id":1,"result":{"version":%s}}\n' "$(( v + 1 ))" ;;
    esac ;;
esac
exit 0
S
chmod +x "$tmp/bin/hc"
export STUB=$tmp/s
printf '%s\n' '────────' ' Quick safety check: Is this a project you created or one you trust?' \
  ' ❯ No, exit' '   Yes, I trust this folder' ' Enter to confirm · Esc to cancel' > "$STUB/screen.start"
sed 's/^ ❯ No, exit$/   No, exit/; s/^   Yes, I trust/ ❯ Yes, I trust/' "$STUB/screen.start" > "$STUB/screen.down"

proj=$tmp/project
g init -q -b main "$proj" 2>/dev/null || { g init -q "$proj"; g -C "$proj" checkout -q -b main; }
g -C "$proj" commit -q --allow-empty -m init
marker=$proj/.git/paddock-trust-pending

envrun() { # envrun <script> <args...>
  local s=$1; shift
  env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET \
      -u CLAUDE_CODE_MESSAGING_TOKEN -u PADDOCK_ORG_ID -u PADDOCK_SECRETARY_NAME -u HC_TERMINAL_SOCKET \
      PADDOCK_CORE_SOCKET_DIR="$tmp/run/herdr-core" PATH="$tmp/bin:$PATH" PADDOCK_WORKERS_DIR="$tmp/workers" \
      PADDOCK_STATE_DIR="$tmp/state" PADDOCK_NOW=2026-11-10T01:02:03Z PADDOCK_HC_HOLD=0 PADDOCK_READY_TRIES=1 PADDOCK_PROMPT_TRIES=3 \
      bash "$s" "$@" 2>"$STUB/err"
}
fresh() { # fresh: org-state empty, marker present, no terminal, no calls
  command rm -f "$STUB"/term-* "$STUB/noidle" "$STUB/sent-text"; command rm -f "$STUB"/docver-*; : > "$STUB/calls"
  printf '{"work":[],"approvals":[]}\n' > "$STUB/docval-org-state"
  : > "$marker"
}
cleanup() { # cleanup <id>: forget the worktree and branch of a finished case
  g -C "$proj" worktree remove --force "$tmp/workers/$1" >/dev/null 2>&1; g -C "$proj" branch -q -D "work/$1" >/dev/null 2>&1
  command rm -rf "$tmp/state/resend"
}
doc() { cat "$STUB/docval-org-state"; }
card() { # card <task>: run prompt, then ask; prints the approval id
  local out; out=$(envrun "$escalation" prompt --task "$1")
  envrun "$escalation" ask --task "$1" --question "Trust the folder of o/r?" --prompt "${out#PROMPT=}" | sed -n 's/^APPROVAL_ID=//p'
}
expected() { # expected <id> <task>: the first message org-delegate sends
  printf '%s\n\n%s' "$(awk 'n >= 2 { print; next } /^---$/ { n++ }' "$here/templates/worker.md")" "Your org id is w-$1. Your task id is $1.

$2"
}

# A failed resend leaves a card; yes on it sends the message and writes the entry once the worker reports a status.
fresh; : > "$STUB/noidle"
envrun "$delegate" --project "$proj" --task-id t5 --title "Retry" --task "Do eps." >/dev/null
id=$(card t5); envrun "$escalation" answer --id "$id" --text yes >/dev/null
cid=$(envrun "$escalation" list | awk -F'\t' '$2=="t5"{print $1}'); [ -n "$cid" ]; check "the resend card exists" $?
echo idle > "$STUB/state"; : > "$STUB/calls"
envrun "$escalation" answer --id "$cid" --text yes >/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$STUB/sent-text" 2>/dev/null)" = "$(expected t5 'Do eps.')" ] && grep -q '"task_id":"t5","title"' "$STUB/docval-org-state" \
  && [ -z "$(envrun "$escalation" list)" ] && ! grep -q 'Answer to your question' "$STUB/calls"; check "yes on the card: sent, entry written, card gone, no mail to the worker ($rc)" $?
cleanup t5

# No on the card drops the saved message; the terminal stays.
fresh; : > "$STUB/noidle"
envrun "$delegate" --project "$proj" --task-id t6 --title "Drop" --task "Do zeta." >/dev/null
id=$(card t6); envrun "$escalation" answer --id "$id" --text yes >/dev/null
cid=$(envrun "$escalation" list | awk -F'\t' '$2=="t6"{print $1}'); : > "$STUB/calls"
envrun "$escalation" answer --id "$cid" --text no >/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$tmp/state/resend/t6" ] && [ -z "$(envrun "$escalation" list)" ] && ! grep -q '^send\|^kill\|^rm ' "$STUB/calls" && [ -e "$STUB/term-w-t6" ]; check "no on the card: message dropped, card gone, terminal kept ($rc)" $?
cleanup t6
exit $fail
