#!/usr/bin/env bash
# Acceptance test for skills/org-start/scripts/org-start.sh. Needs only bash and
# coreutils: hc and herdr-app are replaced by stubs on PATH, so no core runs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-start/scripts/org-start.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

[ -f "$script" ]; check "script exists" $?
[ -f "$here/skills/org-start/SKILL.md" ]; check "SKILL.md exists" $?
bash -n "$script" 2>/dev/null; check "script parses" $?

# Stub hc. State lives in $STUB: a file "secretary" exists once `run` ran.
# Every call is appended to $STUB/calls. STUB_CORE_DOWN=1 makes `ls` fail.
stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/calls"
case "$1" in
  ls) [ -z "${STUB_CORE_DOWN:-}" ] || { echo '{"error":{"kind":"unavailable"}}'; exit 1; }
      echo "ok"; exit 0 ;;
  get) [ -f "$STUB/secretary" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       echo '{"name":"secretary","state":"live","status":{"app":"claude-code","state":"idle"}}'; exit 0 ;;
  run) : > "$STUB/secretary"; echo '{"name":"secretary"}'; exit 0 ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"

run() { # run <extra env...> -- ; uses fresh dirs under $tmp/w unless reused
  env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
      STUB="$tmp/stub" PATH="$stubdir:$PATH" \
      PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" \
      PADDOCK_APP_MODS_DIR="$tmp/app/mods" \
      PADDOCK_READY_TRIES=2 "$@" bash "$script" 2>&1
}
mkdir -p "$tmp/stub"

# Argument handling.
out=$(bash "$script" --help 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -qi 'usage' <<<"$out"; check "--help exits 0 with usage" $?
bash "$script" --no-such-flag >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; check "unknown argument exits 2" $?

# Refusal: hc missing.
out=$(env PATH="$tmp/empty" "$(command -v bash)" "$script" 2>&1); rc=$?
[ "$rc" -eq 3 ]; check "no hc on PATH exits 3" $?

# Refusal: running inside an agent. hc must not be called at all.
: > "$tmp/stub/calls"
out=$(run CLAUDE_CODE_CHILD_SESSION=1); rc=$?
[ "$rc" -eq 4 ] && [ ! -s "$tmp/stub/calls" ]; check "agent environment exits 4 without calling hc" $?
out=$(run CLAUDECODE=1); rc=$?
[ "$rc" -eq 4 ]; check "CLAUDECODE alone also refuses" $?

# Refusal: core unreachable. Nothing is started.
: > "$tmp/stub/calls"
out=$(run STUB_CORE_DOWN=1); rc=$?
[ "$rc" -eq 5 ] && ! grep -q '^run' "$tmp/stub/calls"; check "core unreachable exits 5, starts nothing" $?

# First run.
: > "$tmp/stub/calls"
out=$(run); rc=$?
[ "$rc" -eq 0 ]; check "first run exits 0 ($out)" $?
[ "$(grep -c '^run ' "$tmp/stub/calls")" -eq 1 ] \
  && grep -qx 'run --bg --keep --name secretary secretary' "$tmp/stub/calls"; check "starts the secretary once with --keep" $?
cmp -s "$here/templates/secretary.md" "$tmp/core/templates/secretary.md"; check "template placed in core templates folder" $?
cmp -s "$here/mods/org-agents/main.js" "$tmp/app/mods/org-agents/main.js" \
  && cmp -s "$here/mods/org-agents/mod.json" "$tmp/app/mods/org-agents/mod.json"; check "mod files placed" $?
! grep -Eq '^server (stop|restart)' "$tmp/stub/calls"; check "never stops or restarts the core" $?

# Name override: the terminal gets the given name; the template stays "secretary".
: > "$tmp/stub/calls"; rm -f "$tmp/stub/secretary"
out=$(run PADDOCK_SECRETARY_NAME=probe-sec); rc=$?
[ "$rc" -eq 0 ] && grep -qx 'run --bg --keep --name probe-sec secretary' "$tmp/stub/calls" \
  && grep -qx 'get probe-sec' "$tmp/stub/calls"; check "PADDOCK_SECRETARY_NAME names the terminal" $?
rm -f "$tmp/stub/secretary"; run >/dev/null # back to the first-run state for the next checks

# Second run: idempotent.
: > "$tmp/stub/calls"
out=$(run); rc=$?
[ "$rc" -eq 0 ]; check "second run exits 0" $?
! grep -q '^run ' "$tmp/stub/calls"; check "second run starts no second secretary" $?
[ "$(find "$tmp/app/mods" -mindepth 1 | wc -l)" -eq 3 ]; check "second run does not duplicate mods" $?

exit $fail
