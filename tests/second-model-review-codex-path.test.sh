#!/usr/bin/env bash
# Issue #298: the worker's review gate runs from the core's minimal PATH, which may lack the folder
# codex lives in (a Node version manager's). org-start records codex's absolute path beside the gate
# (codex-path, like claude-path, Issue #268) and the gate falls back to it. Stubs only; no core runs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# --- org-start records where codex is ---
mkdir -p "$tmp/bin" "$tmp/home/.local/bin" "$tmp/nvm/bin" "$tmp/core" "$tmp/stub"
cat > "$tmp/bin/hc" <<'EOF2'
#!/bin/sh
case "$1" in
  get) [ -f "$STUB/secretary" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       echo '{"name":"secretary","state":"live","status":{"app":"claude-code","state":"idle"}}' ;;
  run) : > "$STUB/secretary"; echo '{"name":"secretary"}' ;;
  *) echo ok ;;
esac
exit 0
EOF2
chmod +x "$tmp/bin/hc"
printf '#!/bin/sh\nexit 0\n' > "$tmp/home/.local/bin/claude"; chmod +x "$tmp/home/.local/bin/claude"
# codex lives only in a version manager folder, like the real one.
cat > "$tmp/nvm/bin/codex" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
echo " succeeded in 12ms:"; echo "Findings: none"; exit 0
EOF2
chmod +x "$tmp/nvm/bin/codex"
printf 'notes = false\n' > "$tmp/core/config.toml"
start() { # start <PATH for org-start>
  env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u APPDATA \
      STUB="$tmp/stub" PATH="$1" HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/xdg" \
      PADDOCK_CORE_CONFIG_DIR="$tmp/core" PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" \
      PADDOCK_APP_MODS_DIR="$tmp/app/mods" PADDOCK_APP_LAYOUTS_DIR="$tmp/app/layouts" \
      PADDOCK_BIN_DIR="$tmp/bin-org" PADDOCK_READY_TRIES=2 bash "$here/skills/org-start/scripts/org-start.sh" 2>&1
}
out=$(start "$tmp/nvm/bin:$tmp/home/.local/bin:$tmp/bin:/usr/bin:/bin"); rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$tmp/bin-org/codex-path" 2>/dev/null)" = "$tmp/nvm/bin/codex" ]
check "org-start records codex's absolute path in codex-path" $?
rm -f "$tmp/bin-org/codex-path"
out=$(start "$tmp/home/.local/bin:$tmp/bin:/usr/bin:/bin"); rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$tmp/bin-org/codex-path" ]
check "org-start without codex still succeeds and leaves no codex-path" $?

# --- the gate finds that codex when PATH lacks it ---
repo=$tmp/repo; mkdir -p "$repo"
(
  cd "$repo" && git init -q -b main . \
    && git config user.email t@example.com && git config user.name t \
    && echo one > a.txt && git add a.txt && git commit -q -m one \
    && git update-ref refs/remotes/origin/main HEAD \
    && echo two >> a.txt && git commit -q -am two
) >/dev/null 2>&1
export STUB_LOG=$tmp/calls
gatedir=$tmp/gatedir; mkdir -p "$gatedir"; cp "$here/scripts/second-model-review.sh" "$gatedir/"
run() { : > "$STUB_LOG"; out=$(cd "$repo" && TMPDIR="$tmp" PATH=/usr/bin:/bin bash "$gatedir/second-model-review.sh" 2>&1 </dev/null); rc=$?; last=$(printf '%s\n' "$out" | tail -n 1); }
command -v codex >/dev/null 2>&1 && PATH=/usr/bin:/bin command -v codex >/dev/null 2>&1 && { echo "skip codex on the system PATH"; exit "$fail"; }

run
[ "$rc" -eq 3 ] && grep -q '^CODEX_GATE: unavailable' <<<"$last"; check "no codex on PATH and no codex-path: unavailable" $?
printf '%s\n' "$tmp/nvm/bin/codex" > "$gatedir/codex-path"
run
[ "$rc" -eq 0 ] && grep -q '^CODEX_GATE: passed' <<<"$last" && grep -q -- '--base origin/main' "$STUB_LOG"
check "codex off PATH but recorded in codex-path: the gate runs that codex" $?
printf '%s\n' "$tmp/gone/codex" > "$gatedir/codex-path"
run
[ "$rc" -eq 3 ] && grep -q '^CODEX_GATE: unavailable' <<<"$last"; check "a stale codex-path: unavailable" $?
exit "$fail"
