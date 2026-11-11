#!/usr/bin/env bash
# Acceptance test for the Codex round counter (Issue #225, decision 0005, inventory GT-2, HK-14,
# L-K10): `org --as codex-gate codex_round start` records each review round as codex_round_started,
# refuses past the allowance (3 diff rounds, 1 design review) with codex_round_denied, and the
# secretary raises the allowance with `codex_round allow`. The gate hook (`codex_round hook`, a
# PreToolUse hook in templates/worker-settings.json) counts each gate call and refuses every other
# Bash command that names codex. The count lives in a folder the worker settings deny writing.
# Needs bash, coreutils, sed, awk and node (payloads and settings).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/scripts/org
settings=$here/templates/worker-settings.json
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

state=$tmp/state; cdir=$tmp/rounds; gate=$tmp/bin/codex-review-gate.sh
month=$(date -u +%Y-%m)
org() { # org <args...>; extra env via ORGENV (space separated)
  env -u PADDOCK_ORG_ID -u PADDOCK_NOW -u PADDOCK_SECRETARY_NAME -u CLAUDE_PROJECT_DIR \
      PADDOCK_STATE_DIR="$state" PADDOCK_CODEX_DIR="$cdir" PADDOCK_CODEX_GATE="$gate" \
      ${ORGENV:-} bash "$script" "$@"
}
rc() { "$@" >/dev/null 2>&1; echo $?; }
counted() { # counted <kind> <task>: lines of that kind for the task in the protected folder
  cat "$cdir"/events/*/codex-gate.jsonl 2>/dev/null | grep "\"kind\":\"$1\"" | grep -c "\"task_id\":\"$2\""
}

# --- the subcommand: rounds, the cap, the refusal record ---
for i in 1 2 3; do
  [ "$(rc org --as codex-gate codex_round start --task t1)" -eq 0 ]; check "diff round $i of 3 is let through" $?
done
[ "$(rc org --as codex-gate codex_round start --task t1)" -eq 11 ]; check "the fourth diff round is refused (exit 11)" $?
[ "$(counted codex_round_started t1)" -eq 3 ]; check "three codex_round_started lines are counted" $?
[ "$(counted codex_round_denied t1)" -eq 1 ]; check "the refusal is recorded as codex_round_denied" $?
grep -q '"from":"codex-gate","kind":"codex_round_denied","to":"secretary","task_id":"t1"' \
  "$state/events/$month/codex-gate.jsonl" 2>/dev/null; check "the refusal is in the history log as writer codex-gate, to the secretary" $?
grep -q '"from":"codex-gate","kind":"codex_round_started","to":"","task_id":"t1"' \
  "$state/events/$month/codex-gate.jsonl" 2>/dev/null; check "each round is in the history log as writer codex-gate" $?
out=$(org --as secretary check_messages 2>&1)
grep -q 'codex_round_denied' <<<"$out" && grep -q 't1' <<<"$out"; check "the secretary reads the refusal with check_messages" $?
[ "$(rc org --as codex-gate codex_round start --task t1)" -eq 11 ]; check "a fifth call is refused too" $?

# --- the secretary raises the allowance for one task ---
[ "$(rc org --as w-t1 codex_round allow --task t1 --rounds 9)" -eq 7 ]; check "a worker id cannot raise the allowance (exit 7)" $?
[ "$(rc org --as secretary codex_round allow --task t1 --rounds 4)" -eq 0 ]; check "the secretary raises t1's allowance to 4" $?
[ "$(rc org --as codex-gate codex_round start --task t1)" -eq 0 ]; check "a raised allowance lets the fourth diff round through" $?
[ "$(rc org --as codex-gate codex_round start --task t1)" -eq 11 ]; check "the fifth diff round is refused at allowance 4" $?
[ "$(rc org --as codex-gate codex_round start --task t9)" -eq 0 ]; check "another task keeps its own count" $?
[ "$(rc org --as secretary codex_round allow --task t1 --rounds x)" -eq 2 ]; check "allow needs a whole number (exit 2)" $?
[ "$(rc org --as w-t1 codex_round start --task t1)" -eq 7 ]; check "only codex-gate records a round (exit 7)" $?

# --- design review: its own allowance of 1, apart from the diff rounds ---
[ "$(rc org --as codex-gate codex_round start --task t2 --design)" -eq 0 ]; check "the first design review is let through" $?
[ "$(rc org --as codex-gate codex_round start --task t2 --design)" -eq 11 ]; check "a second design review is refused" $?
[ "$(rc org --as codex-gate codex_round start --task t2)" -eq 0 ]; check "the design review does not use a diff round" $?
[ "$(rc org --as secretary codex_round allow --task t2 --rounds 2 --design)" -eq 0 ] \
  && [ "$(rc org --as codex-gate codex_round start --task t2 --design)" -eq 0 ]; check "the secretary can raise the design allowance" $?

# --- parallel calls cannot pass the cap together ---
pids=; for i in 1 2 3 4 5 6; do ( org --as codex-gate codex_round start --task t3 >/dev/null 2>&1; echo $? > "$tmp/par$i" ) & pids="$pids $!"; done
wait $pids
[ "$(cat "$tmp"/par* | grep -cx 0)" -eq 3 ]; check "six parallel rounds: exactly three are let through" $?

# --- the count's default place is under the folder the worker settings deny writing ---
home=$tmp/home; mkdir -p "$home"
env -u PADDOCK_CODEX_DIR -u XDG_DATA_HOME HOME="$home" PADDOCK_STATE_DIR="$state" \
  bash "$script" --as codex-gate codex_round start --task t4 >/dev/null 2>&1
ls "$home"/.local/share/paddock/*/events/*/codex-gate.jsonl >/dev/null 2>&1; check "the count is kept under ~/.local/share/paddock by default" $?
node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const ok = s.sandbox.filesystem.denyWrite.includes("~/.local/share/paddock")
    && s.permissions.deny.includes("Edit(~/.local/share/paddock/**)")
    && !(s.sandbox.filesystem.allowWrite || []).some(p => p.startsWith("~/.local/share"));
  process.exit(ok ? 0 : 1);' "$settings"; check "worker settings deny writing that folder (sandbox and Edit)" $?

# --- the gate hook ---
payload() { # payload <tool_name> <tool_input JSON>
  node -e 'process.stdout.write(JSON.stringify({session_id:"s",cwd:"/w/x",hook_event_name:"PreToolUse",
    tool_name:process.argv[1],tool_input:JSON.parse(process.argv[2])}))' "$1" "$2" 2>/dev/null
}
bashp() { node -e 'process.stdout.write(JSON.stringify({command:process.argv[1],description:"run it"}))' "$1"; }
hook() { # hook <tool_name> <tool_input JSON>; prints the exit status, stderr to $tmp/herr
  payload "$1" "$2" | ORGENV="CLAUDE_PROJECT_DIR=/w/workers/t5 ${HOOKENV:-}" org --as codex-gate codex_round hook \
    >/dev/null 2>"$tmp/herr"; echo $?
}
call="bash \"$gate\""
for i in 1 2 3; do
  [ "$(hook Bash "$(bashp "$call")")" -eq 0 ]; check "hook: gate call $i is let through" $?
done
[ "$(hook Bash "$(bashp "$call")")" -eq 2 ] && grep -q CODEX_ROUND_DENIED "$tmp/herr"; check "hook: the fourth gate call is refused with CODEX_ROUND_DENIED" $?
[ "$(counted codex_round_started t5)" -eq 3 ] && [ "$(counted codex_round_denied t5)" -eq 1 ]; check "hook: rounds and the refusal are counted for the worktree's task" $?
[ "$(hook Bash "$(bashp "$call --design")")" -eq 0 ]; check "hook: the design gate call is let through" $?
[ "$(hook Bash "$(bashp 'ls -la')")" -eq 0 ]; check "hook: a command without codex is let through" $?
[ "$(hook Bash '{"command":"ls","description":"look for codex notes"}')" -eq 0 ]; check "hook: codex in the description only is let through" $?
[ "$(hook Read '{"file_path":"/w/codex.md"}')" -eq 0 ]; check "hook: other tools are let through" $?
for c in 'codex exec review' 'npx @openai/codex review' 'co""dex review' "c\\odex review" 'CODEX review' \
         "$call; codex exec x" "$call extra" "bash $gate" "$call --design x" \
         "bash \"\$PADDOCK_ORG\" --as codex-gate codex_round start --task t5" \
         "bash \"\$PADDOCK_ORG\" --as secretary codex_round allow --task t5 --rounds 99" \
         'echo x >> ~/.local/share/paddock/codex-rounds/events/x/codex-gate.jsonl'; do
  [ "$(hook Bash "$(bashp "$c")")" -eq 2 ] && grep -q refused "$tmp/herr"; check "hook refuses: $c" $?
done
[ "$(hook Skill '{"skill":"codex:rescue"}')" -eq 2 ] && grep -q refused "$tmp/herr"; check "hook refuses the codex:rescue skill" $?
[ "$(hook mcp__renga-peers__spawn_codex_pane '{}')" -eq 2 ] && grep -q refused "$tmp/herr"; check "hook refuses a codex pane tool" $?
[ "$(HOOKENV='PADDOCK_CODEX_GATE=' hook Bash "$(bashp "$call")")" -eq 2 ] && grep -q refused "$tmp/herr"; check "hook: no gate configured, every codex call is refused" $?
r=$(payload Bash "$(bashp "$call")" | org --as codex-gate codex_round hook 2>&1 >/dev/null | grep -c refused)
[ "$r" -ge 1 ]; check "hook: no CLAUDE_PROJECT_DIR, the gate call is refused" $?
[ "$(rc org --as w-t5 codex_round hook </dev/null)" -eq 7 ]; check "hook runs only as codex-gate" $?

# --- the hook is registered in the worker settings and fails closed ---
hc_cmd=$(node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  for (const m of (s.hooks && s.hooks.PreToolUse) || []) {
    const re = new RegExp("^(" + m.matcher + ")$");
    if (["Bash", "Skill", "mcp__renga-peers__spawn_codex_pane"].every(t => re.test(t)))
      for (const h of m.hooks) if (/codex_round hook/.test(h.command)) { console.log(h.command); process.exit(0); }
  }
  process.exit(1);' "$settings"); check "worker settings run codex_round hook for Bash, Skill and codex tools" $?
r=$(payload Bash "$(bashp 'codex exec x')" | env PADDOCK_ORG="$script" PADDOCK_STATE_DIR="$state" PADDOCK_CODEX_DIR="$cdir" \
  CLAUDE_PROJECT_DIR=/w/workers/t6 sh -c "$hc_cmd" >/dev/null 2>&1; echo $?)
[ "$r" -eq 2 ]; check "the settings' hook command refuses a direct codex call" $?
r=$(payload Bash "$(bashp 'codex exec x')" | env -u PADDOCK_ORG CLAUDE_PROJECT_DIR=/w/workers/t6 sh -c "$hc_cmd" >/dev/null 2>&1; echo $?)
[ "$r" -eq 2 ]; check "the settings' hook command fails closed when PADDOCK_ORG is unset" $?

exit $fail
