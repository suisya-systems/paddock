#!/usr/bin/env bash
# Acceptance test (Issue #219): the premise reminder. A UserPromptSubmit hook (one grep -E) prints one
# "verify before agreeing" line when the prompt carries a number with a unit, a setting name or a claim
# about behaviour; a plain prompt prints nothing; an unreadable payload prints nothing and exits 0.
# org-start places the hook and the secretary's settings; the secretary template passes them to claude.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
hook=$here/scripts/hooks/premise-reminder.sh
settings=$here/templates/secretary-settings.json
sec=$here/templates/secretary.md
start=$here/skills/org-start/scripts/org-start.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

fire() { printf '{"hook_event_name":"UserPromptSubmit","prompt":"%s"}' "$1" | sh "$hook" 2>/dev/null; }

[ -f "$hook" ]; check "the hook script exists" $?
out=$(fire "the timeout is 30 seconds, right?"); rc=$?
[ "$rc" -eq 0 ] && [ "$(wc -l <<<"$out")" -eq 1 ] && grep -qi 'verify' <<<"$out"; check "a number with a unit prints one verify line, exit 0" $?
out=$(fire "set MAX_RETRIES to 3"); [ -n "$out" ]; check "a setting name prints the line" $?
out=$(fire "it always retries by default, doesn't it?"); [ -n "$out" ]; check "a claim about behaviour prints the line" $?
out=$(fire "please open an issue for the next task"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ]; check "a plain prompt prints nothing" $?
out=$(printf 'not json at all \377\n' | sh "$hook" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ]; check "an unreadable payload prints nothing and exits 0" $?
out=$(sh "$hook" </dev/null 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ]; check "an empty payload prints nothing and exits 0" $?
out=$(printf '{"cwd":"/x/30s-dir","prompt":"hello"}' | sh "$hook" 2>/dev/null)
[ -z "$out" ]; check "only the prompt is matched, not other payload fields" $?
grep -q "grep -E" "$hook" 2>/dev/null && ! grep -qw jq "$hook"; check "the hook uses grep -E and no jq" $?

# The secretary's settings carry the hook; the template passes them to claude.
node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const h=s.hooks.UserPromptSubmit[0].hooks[0];process.exit(h.type==="command"&&/premise-reminder\.sh/.test(h.command)?0:1)' "$settings" 2>/dev/null; check "secretary-settings.json parses and runs the hook on UserPromptSubmit" $?
# Issue #260: its PreToolUse hook refuses keys and a forced send in any flag position.
pre=$(node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(s.hooks.PreToolUse[0].hooks[0].command)' "$settings" 2>/dev/null)
for c in 'hc send -f w-t1 yes' 'hc send --force w-t1 yes' 'hc send w-t1 -f yes' 'hc send w-t1 yes --force'; do
  printf '{"tool_input":{"command":"%s"}}' "$c" | sh -c "$pre" >/dev/null 2>&1; [ $? -eq 2 ]; check "the PreToolUse hook refuses: $c" $?
done
printf '{"tool_input":{"command":"%s"}}' 'hc send w-t1 -fine' | sh -c "$pre" >/dev/null 2>&1; check "the PreToolUse hook lets a word starting with -f through" $?
grep -q -- '--settings .*secretary-settings\.json' "$sec"; check "the secretary template passes --settings secretary-settings.json" $?

# org-start places both in the bin folder.
hcstub=$tmp/hcbin; mkdir -p "$hcstub" "$tmp/stub"
cat > "$hcstub/hc" <<'EOF3'
#!/bin/sh
case "$1" in
  get) [ -f "$STUB/secretary" ] || exit 1
       echo '{"name":"secretary","status":{"app":"claude-code","state":"idle"}}' ;;
  run) : > "$STUB/secretary" ;;
esac
exit 0
EOF3
chmod +x "$hcstub/hc"
env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
    STUB="$tmp/stub" PATH="$hcstub:$PATH" XDG_CONFIG_HOME="$tmp/xdg" PADDOCK_CORE_CONFIG_DIR="$here/tests/fixtures/core-notes-off" PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" \
    PADDOCK_APP_MODS_DIR="$tmp/app/mods" PADDOCK_BIN_DIR="$tmp/bin-org" PADDOCK_READY_TRIES=2 bash "$start" >/dev/null 2>&1
cmp -s "$hook" "$tmp/bin-org/premise-reminder.sh" && cmp -s "$settings" "$tmp/bin-org/secretary-settings.json"; check "org-start places the hook and the secretary settings in the bin folder" $?

exit "$fail"
