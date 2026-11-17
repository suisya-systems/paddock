#!/usr/bin/env bash
# `org-start.sh --setup-wsl` (decision 0016): on WSL it writes ~/.config/systemd/user/paddock-core.service
# (hc server start with this shell's PATH, Windows folders left out), enables it and turns linger on,
# after showing the file and asking y/N. Idempotent, refuses a file it did not write, refuses inside an
# agent and off WSL. HOME is a temporary folder; systemctl, loginctl and hc are stubs that log their calls.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-start/scripts/org-start.sh
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/home" "$tmp/hcdir" "$tmp/bin" "$tmp/stub" "$tmp/wsl/sys/fs/binfmt_misc" "$tmp/linux"
: > "$tmp/wsl/sys/fs/binfmt_misc/WSLInterop"; echo 'Linux version 6 (gcc)' > "$tmp/linux/version"
printf '#!/bin/sh\necho "hc $*" >> "$STUB/calls"\n' > "$tmp/hcdir/hc"
cat > "$tmp/bin/systemctl" <<'EOF2'
#!/bin/sh
echo "systemctl $*" >> "$STUB/calls"
case "$*" in
  *is-enabled*) [ -f "$STUB/enabled" ] && echo enabled || { echo disabled; exit 1; } ;;
  *enable*) [ -z "${STUB_ENABLE_FAIL:-}" ] || exit 1; : > "$STUB/enabled" ;;
esac
EOF2
cat > "$tmp/bin/loginctl" <<'EOF2'
#!/bin/sh
echo "loginctl $*" >> "$STUB/calls"
case "$1" in
  show-user) [ -f "$STUB/linger" ] && echo yes || echo no ;;
  enable-linger) : > "$STUB/linger" ;;
esac
EOF2
chmod +x "$tmp/hcdir/hc" "$tmp/bin/systemctl" "$tmp/bin/loginctl"
unit=$tmp/home/.config/systemd/user/paddock-core.service

run() { # run <stdin> <args...>; $envx adds environment words, $proc picks the fake /proc
  local in=$1; shift
  printf '%s' "$in" | env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u WSL_DISTRO_NAME -u XDG_CONFIG_HOME ${envx:-} \
      HOME="$tmp/home" STUB="$tmp/stub" PADDOCK_PROC_DIR="${proc:-$tmp/wsl}" \
      PATH="$tmp/hcdir:/mnt/c/Windows:/opt/a b:/opt/50%:$tmp/bin:/usr/bin:/bin:$tmp/hcdir" \
      bash "$script" --setup-wsl "$@" 2>&1
}
reset() { rm -rf "$tmp/home/.config" "$tmp/stub"/*; : > "$tmp/stub/calls"; }

# 1. Not WSL: exit 12, nothing written, no command run.
reset; out=$(proc=$tmp/linux run "y
"); rc=$?
[ "$rc" -eq 12 ] && [ ! -e "$unit" ] && [ ! -s "$tmp/stub/calls" ]; check "not WSL: exit 12, nothing written or run" $?

# 2. Inside an agent: exit 4 before anything, even with --yes.
reset; out=$(envx="CLAUDECODE=1" run "" --yes); rc=$?
[ "$rc" -eq 4 ] && [ ! -e "$unit" ] && [ ! -s "$tmp/stub/calls" ]; check "inside an agent: exit 4, nothing written or run" $?

# 3. No (or no answer): the plan is shown (file, lines, commands), nothing is written or enabled.
reset; out=$(run "n
"); rc=$?
[ "$rc" -eq 11 ] && [ ! -e "$unit" ] && ! grep -qE ' enable |enable-linger' "$tmp/stub/calls" \
  && grep -q "write $unit" <<<"$out" && grep -q "| ExecStart=$tmp/hcdir/hc server start" <<<"$out" \
  && grep -q 'systemctl --user enable paddock-core.service' <<<"$out" && grep -q 'loginctl enable-linger' <<<"$out"
check "answer n: exit 11, the plan names the file, its lines and the commands; nothing written" $?

# 4. Yes: the file is written with a filtered PATH, the service enabled, linger turned on; the check steps are printed.
reset; out=$(run "y
"); rc=$?
path_line=$(grep '^Environment=PATH=' "$unit" 2>/dev/null)
[ "$rc" -eq 0 ] && [ "$path_line" = "Environment=PATH=$tmp/hcdir:$tmp/bin:/usr/bin:/bin" ] \
  && grep -q "^ExecStart=$tmp/hcdir/hc server start$" "$unit" && grep -q '^WantedBy=default.target$' "$unit" \
  && grep -q '^# Written by paddock (org-start.sh --setup-wsl)' "$unit" \
  && grep -q 'systemctl --user enable paddock-core.service' "$tmp/stub/calls" \
  && grep -q 'loginctl enable-linger' "$tmp/stub/calls" && ! grep -q '^hc' "$tmp/stub/calls" \
  && grep -q 'wsl --shutdown' <<<"$out" && grep -q -- '--check' <<<"$out"
check "answer y: unit written (no /mnt, space or % entries, no duplicate), enabled, linger on, no hc call" $?

# 5. Rerun: nothing to change, no question, no write, no enable.
before=$(cat "$unit"); : > "$tmp/stub/calls"
out=$(run ""); rc=$?
[ "$rc" -eq 0 ] && grep -q 'nothing to change' <<<"$out" && ! grep -q 'go ahead' <<<"$out" \
  && [ "$(cat "$unit")" = "$before" ] && ! grep -qE 'enable |daemon-reload|enable-linger' "$tmp/stub/calls"
check "rerun: nothing to change, nothing asked or run" $?

# 6. --yes skips the question; linger already on is left alone.
reset; : > "$tmp/stub/linger"; out=$(run "" --yes); rc=$?
[ "$rc" -eq 0 ] && [ -e "$unit" ] && ! grep -q 'go ahead' <<<"$out" && ! grep -q 'enable-linger' "$tmp/stub/calls"
check "--yes: no question; linger already on is not touched" $?

# 7. A paddock-core.service it did not write is refused and left as it was.
reset; mkdir -p "$(dirname "$unit")"; echo '[Unit]' > "$unit"
out=$(run "" --yes); rc=$?
[ "$rc" -eq 6 ] && [ "$(cat "$unit")" = '[Unit]' ] && ! grep -q ' enable ' "$tmp/stub/calls"
check "foreign file: exit 6, left unchanged" $?

# 8. systemctl fails: exit 6 with the reason.
reset; out=$(envx="STUB_ENABLE_FAIL=1" run "" --yes); rc=$?
[ "$rc" -eq 6 ] && grep -q 'systemctl --user failed' <<<"$out"; check "systemctl fails: exit 6" $?

# 9. Arguments: --setup-wsl with --check is refused; --yes alone is refused.
out=$(env -u CLAUDECODE bash "$script" --setup-wsl --check 2>&1); [ $? -eq 2 ]; check "--setup-wsl --check: exit 2" $?
out=$(env -u CLAUDECODE bash "$script" --yes 2>&1); [ $? -eq 2 ]; check "--yes alone: exit 2" $?

exit $fail
