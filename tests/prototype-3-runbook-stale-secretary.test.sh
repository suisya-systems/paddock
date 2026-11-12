#!/usr/bin/env bash
# A terminal that holds the name secretary (a plain shell left from an earlier attempt, Issue #287)
# blocks `prepare`. The refusal names the terminal, what runs in it, and the commands that remove
# it, and it comes before the checks of the checkout and the fixture. No core runs here.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here" || exit 1
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
S=scripts/probes/prototype-3.sh
tmp=$(mktemp -d) || exit 1; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/pgrep"
cat > "$tmp/bin/hc" <<'EOF2'
#!/bin/sh
case "$1" in
  ls) exit 0 ;;
  get) printf '{"name":"secretary","status":{"app":"shell","state":"idle"}}\n'; exit 0 ;;
esac
exit 1
EOF2
chmod +x "$tmp/bin/hc" "$tmp/bin/pgrep"
env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET \
  -u CLAUDE_CODE_MESSAGING_TOKEN -u XDG_DATA_HOME PATH="$tmp/bin:$PATH" XDG_STATE_HOME="$tmp" \
  sh "$S" prepare --project . --repo a/b </dev/null > "$tmp/o" 2>&1; rc=$?
[ "$rc" -eq 6 ]; check "a terminal named secretary: prepare exits 6" $?
grep -q 'terminal named secretary' "$tmp/o" && grep -q 'shell' "$tmp/o"; check "the refusal says what runs in that terminal" $?
grep -q 'hc kill secretary' "$tmp/o" && grep -q 'hc rm secretary' "$tmp/o"; check "the refusal gives the commands that remove it" $?
exit "$fail"
