#!/usr/bin/env bash
# Acceptance test for Issue #474: current Claude Code reports a blocked status (kind permission, msg
# "trust this folder") while its folder-trust dialog is up, and may keep reporting it for a while after
# Enter. org-start, secretary-handover, resend.sh and org-escalation --then-send must treat it as "not
# started": nothing is sent until it is gone, one message after that, and a timeout keeps what was saved.
# hc is a stub: no core runs. Needs only bash, coreutils and git.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# Stub hc. $STUB/term-<name>: the terminal exists. $STUB/trust holds how many more `get --json` calls
# after Enter still answer the blocked trust status; before Enter every call does. $STUB/entered: Enter
# was pressed on "Yes". No $STUB/trust: the status is idle. $STUB/msg replaces the trust msg.
# `send` records the text in $STUB/sent, and in $STUB/early too when the trust status was still up.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/hc" <<'S'
#!/bin/sh
echo "$*" >> "$STUB/calls"
cmd=$1; shift
case "$cmd" in
  ls) echo '[]' ;;
  get) json=; name=; for a in "$@"; do case "$a" in --json) json=1 ;; --*) ;; *) name=$a ;; esac; done
       [ -f "$STUB/term-$name" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       st='{"app":"claude-code","state":"idle"}'
       if [ "$name" != watcher ] && [ -f "$STUB/trust" ]; then
         n=$(cat "$STUB/trust")
         if [ ! -e "$STUB/entered" ] || [ "$n" -gt 0 ]; then
           st="{\"app\":\"claude-code\",\"kind\":\"permission\",\"msg\":\"$(cat "$STUB/msg" 2>/dev/null || echo 'trust this folder')\",\"state\":\"blocked\"}"
           [ -z "$json" ] || [ ! -e "$STUB/entered" ] || echo $((n - 1)) > "$STUB/trust"
         else command rm -f "$STUB/trust"; fi
       fi
       printf '{"name":"%s","state":"live","status":%s}\n' "$name" "$st" ;;
  run) name=; prev=; for a in "$@"; do case "$prev" in --name) name=$a ;; esac; prev=$a; done
       : > "$STUB/term-$name"
       [ "$name" = watcher ] || [ ! -f "$STUB/trust.next" ] || mv "$STUB/trust.next" "$STUB/trust" # armed for the new terminal
       if [ "$name" != watcher ] && [ -f "$STUB/trust" ]; then cp "$STUB/dialog" "$STUB/screen"; echo '{"first_message":{"sent":false,"started":false}}'
       else echo '{"first_message":{"sent":true,"started":true}}'; fi ;;
  read) cat "$STUB/screen" ;;
  keys) case $2 in
          down) cp "$STUB/dialog.yes" "$STUB/screen" ;;
          enter) if grep -q '❯.*Yes, I trust' "$STUB/screen"; then : > "$STUB/entered"; printf 'out\n❯ \n' > "$STUB/screen"; fi ;;
        esac ;;
  send) printf '%s\n<<END>>\n' "$2" >> "$STUB/sent"; [ ! -f "$STUB/trust" ] || [ "$(cat "$STUB/trust")" -le 0 ] || : > "$STUB/early" ;;
  rm) command rm -f "$STUB/term-$1" ;;
  connect) cat >/dev/null; echo '{"jsonrpc":"2.0","id":1,"result":{"value":{"written_at":"2026-11-10T01:00:00Z"},"version":3}}' ;;
esac
exit 0
S
chmod +x "$tmp/bin/hc"
printf '#!/bin/sh\n' > "$tmp/bin/claude"; chmod +x "$tmp/bin/claude"

export STUB=$tmp/stub PADDOCK_STATE_DIR=$tmp/state PADDOCK_BIN_DIR=$tmp/bin-org
export PADDOCK_ORG_CONFIG_FILE=$tmp/cfg/org-config.md PADDOCK_PROJECTS_FILE=$tmp/cfg/projects.md
fresh() { # fresh [blocked lookups after Enter]: no terminal; with a number, the trust dialog is up
  rm -rf "$STUB" "$PADDOCK_STATE_DIR/resend"; mkdir -p "$STUB"; : > "$STUB/calls"
  printf '%s\n' ' Quick safety check: Is this a project you created or one you trust?' ' ❯ No, exit' '   Yes, I trust this folder' > "$STUB/dialog"
  printf '%s\n' ' Quick safety check: Is this a project you created or one you trust?' '   No, exit' ' ❯ Yes, I trust this folder' > "$STUB/dialog.yes"
  cp "$STUB/dialog" "$STUB/screen"
  [ $# -eq 0 ] || echo "$1" > "$STUB/trust"
}
run() { # run <script> [args...]
  env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET \
      -u CLAUDE_CODE_MESSAGING_TOKEN -u PADDOCK_ORG_ID -u PADDOCK_SECRETARY_NAME -u HC_TERMINAL_SOCKET -u HC_TERMINAL_ID \
      PATH="$tmp/bin:$PATH" PADDOCK_CORE_CONFIG_DIR="$here/tests/fixtures/core-notes-off" \
      PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" PADDOCK_APP_MODS_DIR="$tmp/app/mods" PADDOCK_APP_LAYOUTS_DIR="$tmp/app/layouts" \
      PADDOCK_CORE_SOCKET_DIR="$tmp/run/herdr-core" PADDOCK_WORKERS_DIR="$tmp/workers" \
      PADDOCK_READY_TRIES="${tries:-8}" PADDOCK_PROMPT_TRIES="${tries:-8}" bash "$here/$1" "${@:2}" > "$STUB/out" 2>&1
}
sends() { grep -c '^<<END>>$' "$STUB/sent" 2>/dev/null || true; }
once_after() { [ "$(sends)" = 1 ] && [ ! -e "$STUB/early" ] && [ ! -e "$STUB/trust" ]; } # one send, after the status cleared
none_sent() { ! grep -q '^send ' "$STUB/calls"; }
start=skills/org-start/scripts/org-start.sh
handover=skills/secretary-handover/scripts/secretary-handover.sh
resend=skills/org-delegate/scripts/resend.sh
escalation=skills/org-escalation/scripts/org-escalation.sh

# org-start, a secretary it just started.
fresh 3; run $start; rc=$?
[ "$rc" -eq 0 ] && grep -q '^keys secretary enter' "$STUB/calls" && grep -q 'org-start: ready' "$STUB/out"; check "org-start: blocked trust status goes to the trust path, then ready ($rc)" $?
once_after; check "org-start: the first message is sent once, after the status cleared" $?
fresh 999; tries=3 run $start; rc=$?
[ "$rc" -eq 7 ] && none_sent && ! grep -q 'org-start: ready' "$STUB/out"; check "org-start: still blocked at the deadline: exit 7, nothing sent ($rc)" $?
# an existing secretary at the dialog is not answered; a tool prompt is not the trust dialog.
fresh 999; : > "$STUB/term-secretary"; tries=2 run $start; rc=$?
[ "$rc" -eq 7 ] && none_sent && ! grep -q '^keys ' "$STUB/calls"; check "org-start: an existing secretary at the dialog: exit 7, no keys ($rc)" $?
fresh 999; : > "$STUB/term-secretary"; echo 'Bash: ls' > "$STUB/msg"; run $start; rc=$?
[ "$rc" -eq 0 ] && ! grep -q '^keys ' "$STUB/calls"; check "org-start: a blocked tool prompt still counts as started, no keys ($rc)" $?

# secretary-handover: the old secretary is idle, the new one stops at the dialog.
sdir=$PADDOCK_STATE_DIR/secretary; marker=$PADDOCK_STATE_DIR/watcher/renew-secretary
prep() { mkdir -p "$sdir" "$PADDOCK_BIN_DIR" "${marker%/*}"; : > "$sdir/AGENTS.md"; : > "$sdir/CLAUDE.md"; echo "$here" > "$PADDOCK_BIN_DIR/paddock-home"; echo req > "$marker"; }
old() { # old <blocked lookups>: an idle old secretary; the dialog comes with the next `run`
  fresh; prep; : > "$STUB/term-secretary"; printf 'out\n❯ \n' > "$STUB/screen"; echo "$1" > "$STUB/trust.next"
}
old 3; run $handover; rc=$?
[ "$rc" -eq 0 ] && once_after; check "handover: waits out the blocked status, then sends once ($rc)" $?
old 999; tries=3 run $handover; rc=$?
[ "$rc" -eq 10 ] && none_sent && [ -f "$marker" ]; check "handover: still blocked: exit 10, nothing sent, the request kept ($rc)" $?

# resend.sh after Enter was pressed.
saved=$PADDOCK_STATE_DIR/resend/t1
parked() { fresh "$1"; : > "$STUB/entered"; : > "$STUB/term-w-t1"; mkdir -p "$saved"; echo 'Do alpha.' > "$saved/message"; }
parked 3; run $resend t1; rc=$?
[ "$rc" -eq 0 ] && once_after && [ ! -e "$saved/message" ]; check "resend: waits out the blocked status, then sends once ($rc)" $?
parked 999; echo 'saved entry' > "$saved/entry"; tries=3 run $resend t1; rc=$?
[ "$rc" -eq 12 ] && none_sent && [ "$(cat "$saved/message")" = 'Do alpha.' ] && [ "$(cat "$saved/entry")" = 'saved entry' ]
check "resend: still blocked: exit 12, nothing sent, message and entry kept ($rc)" $?

# org-escalation prompt --then-send: answers the dialog, then sends.
dialog() { fresh "$1"; : > "$STUB/term-w-t1"; }
dialog 3; run $escalation prompt --task t1 --then-send 'Do beta.'; rc=$?
[ "$rc" -eq 0 ] && once_after; check "then-send: waits out the blocked status, then sends once ($rc)" $?
dialog 999; tries=3 run $escalation prompt --task t1 --then-send 'Do beta.'; rc=$?
[ "$rc" -eq 12 ] && grep -q '^keys w-t1 enter' "$STUB/calls" && none_sent; check "then-send: still blocked: exit 12, nothing sent ($rc)" $?

exit $fail
