#!/usr/bin/env bash
# Issue #409: the curator's first run in knowledge/ stops at Claude Code's folder-trust dialog and
# its first message is not sent. org-curate start answers the dialog through
# org-escalation prompt --curator (screen read, down, enter on "Yes, I trust this folder") and sends
# the first message as hc would have: the curator template body, a blank line, the brief.
# Stubbed hc; no core.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
oc=$here/skills/org-curate/scripts/org-curate.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

mkdir -p "$tmp/bin" "$tmp/s" "$tmp/sock"
cat > "$tmp/bin/hc" <<'S'
#!/bin/sh
echo "$*" >> "$STUB/calls"
cmd=$1; shift
case "$cmd" in
  run) echo none > "$STUB/state"; cp "$STUB/screen.start" "$STUB/screen"
       if [ -e "$STUB/trusted" ]; then echo idle > "$STUB/state"; echo '{"first_message":{"sent":true}}'
       else echo '{"first_message":{"sent":false,"started":false}}'; fi ;;
  get) if [ "$(cat "$STUB/state")" = none ]; then printf '{\n  "name": "curator",\n  "status": null\n}\n'
       else printf '{\n  "name": "curator",\n  "status": {"state":"%s"}\n}\n' "$(cat "$STUB/state")"; fi ;;
  read) cat "$STUB/screen" ;;
  keys) case $2 in
          down) cp "$STUB/screen.down" "$STUB/screen" ;;
          enter) grep -q '^ ❯ Yes' "$STUB/screen" && echo idle > "$STUB/state" ;;
        esac ;;
  send) printf '%s' "$2" > "$STUB/sent-text" ;;
esac
exit 0
S
chmod +x "$tmp/bin/hc"
export STUB=$tmp/s
printf '%s\n' '────────' ' Quick safety check: Is this a project you created or one you trust?' \
  ' ❯ No, exit' '   Yes, I trust this folder' ' Enter to confirm · Esc to cancel' > "$STUB/screen.start"
sed 's/^ ❯ No, exit$/   No, exit/; s/^   Yes, I trust/ ❯ Yes, I trust/' "$STUB/screen.start" > "$STUB/screen.down"

start() {
  rm -f "$STUB/calls" "$STUB/sent-text"
  out=$(env -u CLAUDECODE -u HC_TERMINAL_SOCKET PATH="$tmp/bin:$PATH" PADDOCK_STATE_DIR="$tmp/state" \
    PADDOCK_CORE_SOCKET_DIR="$tmp/sock" PADDOCK_PROMPT_TRIES=3 bash "$oc" start 2>&1); rc=$?
}

# 1. The dialog: answered with "Yes, I trust this folder", then the first message is sent.
start
[ "$rc" -eq 0 ]; check "start exits 0 after the dialog ($out)" $?
grep -qx 'keys curator down' "$STUB/calls" && grep -qx 'keys curator enter' "$STUB/calls"; check "the dialog is answered on the curator terminal" $?
first="$(awk 'n >= 2 { print; next } /^---$/ { n++ }' "$here/templates/curator.md")

Your org-curate script is $oc: run it as bash $oc candidates and bash $oc finish."
[ "$(cat "$STUB/sent-text" 2>/dev/null)" = "$first" ]; check "the first message (template body, blank line, brief) is sent" $?
grep -q 'folder-trust dialog; answered it' <<<"$out"; check "start says it answered the dialog" $?

# 2. An already trusted folder: no key is pressed, nothing is sent again.
: > "$STUB/trusted"; start; rm -f "$STUB/trusted"
[ "$rc" -eq 0 ] && ! grep -q '^keys' "$STUB/calls" && [ ! -e "$STUB/sent-text" ]; check "sent true: no key, no resend" $?

# 3. A screen that is not the dialog: nothing pressed, nothing sent, exit 10.
printf '%s\n' ' Something else' ' ❯ 1. Yes' '   2. No' > "$STUB/screen.start"
start
[ "$rc" -eq 10 ] && ! grep -q '^keys' "$STUB/calls" && [ ! -e "$STUB/sent-text" ]; check "another screen: exit 10, nothing pressed or sent ($rc)" $?
grep -q "hc read curator" <<<"$out"; check "the stop names hc read curator" $?

exit $fail
