#!/usr/bin/env bash
# Acceptance test for Issue #368 (follow-up of #362): a delegate on a fresh clone stops at the folder-trust dialog
# (org-delegate exit 10: nothing sent, no work entry). After the person's yes on the trust card, the single
# `org-escalation answer --id <id> --text yes` (no --then-send) presses the dialog, resends the first message org-delegate
# built (worker template body, id lines, task) and writes the work entry (--title). On no nothing is sent and no entry is
# written; when the resend fails the terminal stays, a card says so, and org-delegate/scripts/resend.sh finishes it later.
# Stubbed hc and git; no core.
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

# 1. Yes with a title: one answer sends the task and writes the work entry.
fresh
envrun "$delegate" --project "$proj" --task-id t1 --title "Trust resend" --task "Do alpha." >/dev/null; rc=$?
[ "$rc" -eq 10 ]; check "the delegate stops at the trust dialog with exit 10 ($rc)" $?
! grep -q '"task_id": *"t1"' <<<"$(grep -v approvals <<<"$(doc)")" && ! grep -q '^send' "$STUB/calls"; check "before the answer: nothing sent, no work entry" $?
id=$(card t1); [ -n "$id" ]; check "the trust card is recorded" $?
: > "$STUB/calls"
envrun "$escalation" answer --id "$id" --text yes >/dev/null; rc=$?
[ "$rc" -eq 0 ]; check "answer yes (no --then-send) exits 0 ($rc)" $?
[ "$(grep -c '^keys w-t1 enter' "$STUB/calls")" = 1 ]; check "the dialog is pressed once" $?
[ "$(cat "$STUB/sent-text" 2>/dev/null)" = "$(expected t1 'Do alpha.')" ]; check "the first message is the template body, the id lines and the task" $?
d=$(doc)
grep -q '"task_id": *"t1"' <<<"$d" && grep -q '"title": *"Trust resend"' <<<"$d" && grep -q '"since": *"2026-11-10T01:02:03Z"' <<<"$d" \
  && grep -q "\"worktree\": *\"$tmp/workers/t1\"" <<<"$d" && grep -q '"task": *"Do alpha."' <<<"$d"; check "the work entry (task_id, title, since, worktree, task) is written" $?
[ -z "$(envrun "$escalation" list)" ]; check "the card is gone" $?
[ ! -e "$marker" ]; check "the marker is cleared" $?
! grep -q '^kill\|^rm ' "$STUB/calls"; check "no terminal was killed" $?
cleanup t1

# 2. Yes without a title: the message is sent, org-state gets no work entry.
fresh
envrun "$delegate" --project "$proj" --task-id t2 --task "Do beta." >/dev/null
id=$(card t2); envrun "$escalation" answer --id "$id" --text yes >/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$STUB/sent-text" 2>/dev/null)" = "$(expected t2 'Do beta.')" ] && ! grep -q '"task_id": *"t2"' <<<"$(doc)"; check "no --title: sent, and no work entry ($rc)" $?
cleanup t2

# 3. No: esc, nothing sent, no entry, the terminal stays, the marker stays.
fresh
envrun "$delegate" --project "$proj" --task-id t3 --title "Declined" --task "Do gamma." >/dev/null
id=$(card t3); : > "$STUB/calls"
envrun "$escalation" answer --id "$id" --text no >/dev/null; rc=$?
[ "$rc" -eq 0 ] && grep -q '^keys w-t3 esc' "$STUB/calls" && ! grep -q '^send' "$STUB/calls" && ! grep -q '"task_id": *"t3"' <<<"$(doc)" \
  && [ -e "$STUB/term-w-t3" ] && ! grep -q '^kill\|^rm ' "$STUB/calls" && [ -e "$marker" ]; check "no: esc only; nothing sent, no entry, terminal and marker kept ($rc)" $?
[ ! -e "$tmp/state/resend/t3" ]; check "no: the saved first message is dropped" $?
cleanup t3

# 4. The resend fails (the worker never reports a status): terminal kept, a card says so, resend.sh finishes it later.
fresh; : > "$STUB/noidle"
envrun "$delegate" --project "$proj" --task-id t4 --title "Late" --task "Do delta." >/dev/null
id=$(card t4); : > "$STUB/calls"
envrun "$escalation" answer --id "$id" --text yes >/dev/null; rc=$?
[ "$rc" -eq 12 ]; check "a failed resend exits 12 ($rc)" $?
[ -e "$STUB/term-w-t4" ] && ! grep -q '^kill\|^rm ' "$STUB/calls" && ! grep -q '"task_id": *"t4"' <<<"$(doc | sed 's/"approvals".*//')"; check "failed resend: terminal kept, no work entry yet" $?
n=$(envrun "$escalation" list | grep -c 't4'); [ "$n" -eq 1 ]; check "failed resend: one card tells the person ($n)" $?
envrun "$escalation" list | grep -qi 'first message'; check "the card says the first message was not sent" $?
echo idle > "$STUB/state"; : > "$STUB/calls"
envrun "$resend" t4 >/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$STUB/sent-text" 2>/dev/null)" = "$(expected t4 'Do delta.')" ] && grep -q '"task_id": *"t4"' <<<"$(doc)"; check "resend.sh later sends the message and writes the entry ($rc)" $?
envrun "$resend" t4 >/dev/null; rc=$?
[ "$rc" -ne 0 ] && [ "$(grep -c '^send' "$STUB/calls")" = 1 ]; check "resend.sh twice sends nothing more ($rc)" $?
cleanup t4
exit $fail
