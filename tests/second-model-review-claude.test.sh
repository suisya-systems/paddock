#!/usr/bin/env bash
# The review gate (scripts/second-model-review.sh) without codex: Claude reviews, headless, in a fresh
# session with read-only tools, judged by the same rules (a tool call ran, none failed, exit 0), and
# the last line keeps its CODEX_GATE: prefix and names the reviewer. Codex stays first when present;
# neither is unavailable. org-start --check says which reviewer is in use. Stubs only; no model runs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/scripts/org
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

task=t-claude
repo=$tmp/workers/$task; mkdir -p "$repo"
(
  cd "$repo" && git init -q -b main . \
    && git config user.email t@example.com && git config user.name t \
    && echo one > a.txt && git add a.txt && git commit -q -m one \
    && git update-ref refs/remotes/origin/main HEAD \
    && echo two >> a.txt && git commit -q -am two
) >/dev/null 2>&1; check "fixture repository is built" $?

# the gate placed in a bin folder, as org-start does; claude-path names the stub claude
gatedir=$tmp/gatedir; mkdir -p "$gatedir" "$tmp/claude/bin" "$tmp/cx/bin"
cp "$here/scripts/second-model-review.sh" "$gatedir/"
cat > "$tmp/claude/bin/claude" <<'EOF2'
#!/bin/sh
case "$1" in --version) echo "2.9.9 (Claude Code)"; exit 0 ;; esac
printf '%s\n' "$*" >> "$STUB_LOG"
env > "$STUB_ENV"
# what the diff file holds, read where the prompt names it
d=$(printf '%s' "$2" | sed -n 's|.*change in \([^:]*\.diff\):.*|\1|p'); [ -n "$d" ] && cp "$d" "$STUB_DIFF"
init='{"type":"system","subtype":"init","tools":["Glob","Grep","Read"]}'
use='{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"a.txt"}}]}}'
okres='{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"one"}]}}'
badres='{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"denied","is_error":true}]}}'
text='{"type":"assistant","message":{"content":[{"type":"text","text":"say \"type\":\"tool_use\" in prose"}]}}'
fin='{"type":"result","subtype":"success","is_error":false,"result":"## Blocker\nNone.\n\"quoted\" back\\slash caf\u00e9 \u0041","num_turns":2}'
case "${STUB_MODE:-ran}" in
  ran)    printf '%s\n' "$init" "$use" "$okres" "$fin"; exit 0 ;;
  empty)  printf '%s\n' "$init" "$text" "$fin"; exit 0 ;;
  failed) printf '%s\n' "$init" "$use" "$badres" "$fin"; exit 0 ;;
  bad)    printf '%s\n' "$init" "$use" "$okres"; exit 1 ;;
  noresult) printf '%s\n' "$init" "$use" "$okres"; exit 0 ;;
esac
EOF2
chmod +x "$tmp/claude/bin/claude"
printf '#!/bin/sh\ncase "$1" in --version) echo "cx-cli 1.0"; exit 0;; esac\necho "cx $*" >> "$STUB_LOG"\necho " succeeded in 12ms:"; exit 0\n' > "$tmp/cx/bin/codex"
chmod +x "$tmp/cx/bin/codex"
export STUB_LOG=$tmp/calls STUB_ENV=$tmp/env STUB_DIFF=$tmp/diff
state=$tmp/state; cdir=$tmp/rounds
env_org() { env -u PADDOCK_ORG_ID -u PADDOCK_NOW -u XDG_DATA_HOME PADDOCK_STATE_DIR="$state" PADDOCK_CODEX_DIR="$cdir" "$@"; }
round() { env_org bash "$script" --as codex-gate codex_round start --task "$task" "$@" >/dev/null 2>&1; }
# run <PATH> <args...>: the gate as the worker calls it, from a Claude session's environment
run() {
  local p=$1; shift; : > "$STUB_LOG"; rm -f "$STUB_DIFF"
  out=$(cd "$repo" && env_org TMPDIR="$tmp" PATH="$p" PADDOCK_ORG="$script" CLAUDE_PROJECT_DIR="$repo" \
    CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=worker-session CLAUDE_PID=1 bash "$gatedir/second-model-review.sh" "$@" 2>&1 </dev/null); rc=$?
  last=$(printf '%s\n' "$out" | tail -n 1)
}
hist() { cat "$state"/events/*/codex-gate.jsonl 2>/dev/null; }
line_of() { grep "\"kind\":\"$1\"" | grep "\"task_id\":\"$task\"" | tail -n 1; }
sys=/usr/bin:/bin
if PATH=$sys command -v claude >/dev/null 2>&1 || PATH=$sys command -v codex >/dev/null 2>&1; then
  echo "skip a reviewing CLI sits in /usr/bin or /bin; the fallback cases need a PATH without one"; exit "$fail"
fi

# --- codex present: codex runs, claude does not ---
printf '%s\n' "$tmp/claude/bin/claude" > "$gatedir/claude-path"
run "$tmp/cx/bin:$sys"
[ "$rc" -eq 0 ] && grep -q '^cx exec review' "$STUB_LOG" && ! grep -q -- '-p ' "$STUB_LOG"
check "codex present: codex reviews, claude is not called" $?
grep -q '^CODEX_GATE: passed (reviewer=codex ' <<<"$last"; check "codex present: the last line names reviewer=codex" $?

# --- codex absent, claude in claude-path: claude reviews; the round is counted and recorded ---
round; STUB_MODE=ran run "$sys"
[ "$rc" -eq 0 ] && grep -q '^CODEX_GATE: passed (reviewer=claude succeeded=1 failed=0 status=0 claude=' <<<"$last"
check "claude: a review that ran a tool passes, the last line names reviewer=claude" $?
grep -q "$tmp/claude/bin/claude 2.9.9" <<<"$last"; check "claude: the last line carries its path and version" $?
a=$(cat "$STUB_LOG")
case "$a" in -p\ *) true ;; *) false ;; esac && grep -q -- '--tools Read,Grep,Glob ' <<<"$a" && grep -q -- '--permission-mode dontAsk ' <<<"$a" \
  && grep -q -- '--setting-sources  ' <<<"$a" && grep -q -- '--strict-mcp-config' <<<"$a" && grep -q -- '--no-session-persistence' <<<"$a" \
  && ! grep -q -- '--continue\|--resume\|--settings ' <<<"$a"
check "claude: headless, read-only tools only, no settings, no MCP, a new session" $?
! grep -q '^CLAUDECODE=\|^CLAUDE_CODE_SESSION_ID=\|^CLAUDE_PID=\|^CLAUDE_PROJECT_DIR=' "$STUB_ENV" && grep -q '^CLAUDE_CODE_DISABLE_AUTO_MEMORY=1' "$STUB_ENV"
check "claude: the worker's session variables are dropped, auto memory is off" $?
grep -q '^[0-9a-f]* two$' "$STUB_DIFF" && grep -q '^+two$' "$STUB_DIFF"; check "claude: the diff file holds the commits and the diff against the base" $?
printf '%s\n' "$out" | grep -qx '"quoted" back\\slash caf\\u00e9 A' && printf '%s\n' "$out" | grep -qx '## Blocker' \
  && [ "$(printf '%s\n' "$out" | grep -n 'Blocker' | cut -d: -f1)" -lt "$(printf '%s\n' "$out" | grep -n '^CODEX_GATE' | cut -d: -f1)" ]
check "claude: the review text reaches the worker unescaped, before the last line" $?
grep -q 'same-family' <<<"$out"; check "claude: the gate says a same-family review is weaker" $?
l=$(hist | line_of codex_round_passed)
grep -q 'diff round 1' <<<"$l" && grep -q 'reviewer=claude' <<<"$l"; check "claude: codex_round_passed records round 1 and the reviewer" $?
ls "$tmp"/second-review-in.* >/dev/null 2>&1; [ $? -ne 0 ]; check "claude: the diff folder is removed" $?

# --- claude runs that are not a review ---
round; STUB_MODE=empty run "$sys"
[ "$rc" -eq 1 ] && grep -q '^CODEX_GATE: not-established (reviewer=claude succeeded=0 ' <<<"$last"
check "claude: no tool call (an empty pass, even with tool_use quoted in its text) is not established" $?
grep -q 'diff round 2' <<<"$(hist | line_of codex_round_failed)"; check "claude: the empty pass is recorded as codex_round_failed" $?
STUB_MODE=failed run "$sys"
[ "$rc" -eq 1 ] && grep -q '^CODEX_GATE: not-established (reviewer=claude succeeded=1 failed=1 ' <<<"$last"; check "claude: a failed tool call is not established" $?
STUB_MODE=bad run "$sys"
[ "$rc" -eq 1 ] && grep -q '^CODEX_GATE: not-established' <<<"$last"; check "claude: a non-zero exit is not established" $?
STUB_MODE=noresult run "$sys"
[ "$rc" -eq 1 ] && grep -q 'status=1' <<<"$last"; check "claude: no final result line is not established" $?

# --- design mode with claude: the design prompt, no diff file ---
mkdir -p "$repo/.worker-scratch"; printf 'The design.\n' > "$repo/.worker-scratch/design.md"
STUB_MODE=ran run "$sys" --design
[ "$rc" -eq 0 ] && grep -q '^CODEX_GATE: passed (reviewer=claude ' <<<"$last" && grep -q 'design at .worker-scratch/design.md' "$STUB_LOG" && [ ! -e "$STUB_DIFF" ]
check "claude: the design review runs with the design prompt" $?

# --- claude on PATH, no claude-path ---
rm -f "$gatedir/claude-path"
STUB_MODE=ran run "$tmp/claude/bin:$sys"
[ "$rc" -eq 0 ] && grep -q 'reviewer=claude' <<<"$last"; check "claude on PATH without claude-path is used" $?

# --- neither ---
printf '%s\n' "$tmp/gone/claude" > "$gatedir/claude-path"
run "$sys"
[ "$rc" -eq 3 ] && grep -q '^CODEX_GATE: unavailable' <<<"$last" && [ ! -s "$STUB_LOG" ]; check "neither codex nor claude: unavailable (exit 3)" $?

# --- org-start --check names the reviewer in use ---
chk() { env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET \
  -u CLAUDE_CODE_MESSAGING_TOKEN -u APPDATA PATH="$1" HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/xdg" \
  PADDOCK_CORE_CONFIG_DIR="$tmp/core" PADDOCK_APP_MODS_DIR="$tmp/app/mods" PADDOCK_BIN_DIR="$tmp/bin-org" \
  bash "$here/skills/org-start/scripts/org-start.sh" --check 2>&1; }
chk "$tmp/cx/bin:$tmp/claude/bin:$sys" | grep -q "^ok reviewer: codex at $tmp/cx/bin/codex"; check "check: codex found, codex reviews" $?
c=$(chk "$tmp/claude/bin:$sys" | grep '^ok reviewer: ')
grep -q "claude at $tmp/claude/bin/claude" <<<"$c" && grep -q 'same-family' <<<"$c"; check "check: no codex, claude reviews (and it says that is weaker)" $?
chk "$sys" | grep -q '^TODO reviewer: '; check "check: neither: a TODO" $?
exit "$fail"
