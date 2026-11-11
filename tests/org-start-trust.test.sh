#!/usr/bin/env bash
# Acceptance test for Issue #244: org-start answers Claude Code's folder-trust dialog on the
# secretary it just started (read, down, read again, enter only with the cursor on "Yes, I trust
# this folder"), waits for the status again and sends the first message that was not delivered:
# the template body, plus the launch task (the conversation-language line) when there is one.
# hc is a stub: no core runs. Needs only bash and coreutils.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-start/scripts/org-start.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# Stub hc. $STUB/secretary exists once `run` ran; $STUB/status once the secretary reports one.
# $STUB/screen is what `hc read` prints. STUB_DIALOG=1: `run` puts the trust dialog on the screen
# (cursor on "No, exit") and no status. STUB_CURSOR_STUCK=1: `keys down` does not move the cursor.
# `keys enter` with the cursor on "Yes" clears the dialog and gives the status.
# STUB_SILENT=1: `run` gives a screen without the dialog and never a status.
# `send <name> <text>` appends <text> and a separator line to $STUB/sent.
stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/calls"
no='No, exit'; yes='Yes, I trust this folder'
dialog() { # dialog <cursor-on-yes 0|1>
  printf ' Accessing workspace:\n\n /home/p/paddock-p3\n\n Quick safety check: Is this a project you created or one you trust?\n\n'
  if [ "$1" = 1 ]; then printf '   1. %s\n ❯ 2. %s\n' "$no" "$yes"; else printf ' ❯ 1. %s\n   2. %s\n' "$no" "$yes"; fi
  printf '\n Enter to confirm · Esc to cancel\n'
}
case "$1" in
  ls) echo ok; exit 0 ;;
  get) [ -f "$STUB/secretary" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       if [ -f "$STUB/status" ]; then echo '{"name":"secretary","state":"live","status":{"app":"claude-code","state":"idle"}}'
       else echo '{"name":"secretary","state":"live","status":null}'; fi; exit 0 ;;
  run) : > "$STUB/secretary"
       if [ -n "${STUB_DIALOG:-}" ]; then dialog 0 > "$STUB/screen"
       elif [ -n "${STUB_SILENT:-}" ]; then printf ' Welcome to Claude Code\n' > "$STUB/screen"
       else : > "$STUB/status"; printf ' > \n' > "$STUB/screen"; fi
       echo '{"name":"secretary"}'; exit 0 ;;
  read) cat "$STUB/screen"; exit 0 ;;
  keys) shift 2
        for k in "$@"; do
          case "$k" in
            down) [ -n "${STUB_CURSOR_STUCK:-}" ] || ! grep -q 'Quick safety check' "$STUB/screen" || dialog 1 > "$STUB/screen" ;;
            enter) if grep -q '❯ 2. Yes, I trust this folder' "$STUB/screen"; then printf ' > \n' > "$STUB/screen"; : > "$STUB/status"
                   elif grep -q '❯ 1. No, exit' "$STUB/screen"; then : > "$STUB/exited"; fi ;;
          esac
        done; exit 0 ;;
  send) printf '%s\n<<END>>\n' "$3" >> "$STUB/sent"; exit 0 ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"

export PADDOCK_STATE_DIR=$tmp/state PADDOCK_ORG_CONFIG_FILE=$tmp/cfg/org-config.md PADDOCK_PROJECTS_FILE=$tmp/cfg/projects.md
lang() { bash "$here/scripts/org" --as secretary config set conversation_language "$1" >/dev/null; }
start() { # start <env...>: a fresh stub state, then org-start
  rm -rf "$tmp/stub"; mkdir -p "$tmp/stub"; : > "$tmp/stub/calls"
  env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
      STUB="$tmp/stub" PATH="$stubdir:$PATH" \
      PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" PADDOCK_APP_MODS_DIR="$tmp/app/mods" \
      PADDOCK_APP_LAYOUTS_DIR="$tmp/app/layouts" PADDOCK_BIN_DIR="$tmp/bin-org" \
      PADDOCK_READY_TRIES=3 "$@" bash "$script" 2>&1
}
calls=$tmp/stub/calls
line() { grep -n -x -- "$1" "$calls" | head -n 1 | cut -d: -f1; } # first line number of an exact call
sent=$tmp/stub/sent
first=$(awk 'n >= 2 { print; exit } /^---$/ { n++ }' "$here/templates/secretary.md") # first line of the body
sends() { grep -c '^<<END>>$' "$sent" 2>/dev/null || echo 0; }
msg() { sed '/^<<END>>$/q' "$sent" 2>/dev/null | sed '$d'; } # the first message sent

# 1. The dialog on a new secretary: answered with a check of the cursor, then body and task are sent.
lang ja
out=$(start STUB_DIALOG=1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'org-start: ready' <<<"$out"; check "dialog: answered, the secretary reports a status, exit 0" $?
d=$(line 'keys secretary down'); e=$(line 'keys secretary enter')
[ -n "$d" ] && [ -n "$e" ] && [ "$d" -lt "$e" ]; check "dialog: down is pressed before enter" $?
r1=$(grep -n -x 'read secretary' "$calls" | head -n 1 | cut -d: -f1)
r2=$(awk -v d="${d:-0}" '$0 == "read secretary" && NR > d { print NR; exit }' "$calls")
[ -n "$r1" ] && [ -n "$r2" ] && [ "$r1" -lt "$d" ] && [ "$r2" -lt "$e" ]; check "dialog: the screen is read before down and again before enter" $?
! grep -Eq '^keys secretary .*(down|enter) ' "$calls" && ! grep -q '^keys secretary down enter' "$calls"; check "dialog: keys are pressed one at a time" $?
[ ! -e "$tmp/stub/exited" ]; check "dialog: \"No, exit\" was never confirmed" $?
s=$(grep -n '^send secretary ' "$calls" | head -n 1 | cut -d: -f1)
[ -n "$s" ] && [ "$s" -gt "$e" ] && [ "$(sends)" -eq 1 ]; check "dialog: one message is sent, after the dialog is answered" $?
[ -n "$first" ] && [ "$(msg | head -n 1)" = "$first" ]; check "dialog: the message starts with the template body" $?
[ "$(msg | tail -n 1)" = 'Conversation language: ja' ]; check "dialog: the message ends with the launch task" $?

# 2. The dialog without a conversation language: answered, the body alone is sent.
lang auto
out=$(start STUB_DIALOG=1); rc=$?
[ "$rc" -eq 0 ] && [ "$(sends)" -eq 1 ] && [ "$(msg | head -n 1)" = "$first" ] && ! msg | grep -q '^Conversation language:'
check "dialog, language auto: exit 0, the body is sent without a language line" $?

# 3. The cursor does not move: stop with exit 7, never press enter.
lang ja
out=$(start STUB_DIALOG=1 STUB_CURSOR_STUCK=1); rc=$?
[ "$rc" -eq 7 ] && ! grep -q 'enter' "$calls" && ! grep -q '^send ' "$calls"; check "cursor stuck: exit 7, no enter, no send" $?
[ ! -e "$tmp/stub/exited" ]; check "cursor stuck: \"No, exit\" was never confirmed" $?

# 4. No status and no dialog on the screen: the current exit 7, no keys.
out=$(start STUB_SILENT=1); rc=$?
[ "$rc" -eq 7 ] && ! grep -q '^keys ' "$calls" && ! grep -q '^send ' "$calls"; check "no dialog, no status: exit 7, no keys" $?

# 5. A secretary that reports a status at once: no read, no keys, no send (the task went with run).
out=$(start); rc=$?
[ "$rc" -eq 0 ] && ! grep -Eq '^(keys|send) ' "$calls"; check "status at once: exit 0, no keys, no send" $?
grep "^run " "$calls" | grep -q 'Conversation language: ja$'; check "status at once: the task goes with run" $?

exit "$fail"
