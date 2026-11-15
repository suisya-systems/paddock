#!/usr/bin/env bash
# Decision 0014, probe H1 (Refs #375): scripts/probes/h1-precedence.sh measures whether the worker rules'
# "When the repository's instructions disagree with these rules" section beats a repository AGENTS.md that
# says to push after every commit, at launch and after /compact. This test checks the probe's safety
# rules statically, then runs it against a stub `hc` and `claude` (STUB_VARIANT: holds | loses | nopull)
# to check how it reads the result. No real Claude Code or herdr core runs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
probe=$here/scripts/probes/h1-precedence.sh
decision=$here/docs/decisions/0014-role-rules-skills-and-tools.md
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
code() { grep -vE '^[[:space:]]*#' "$probe"; }

[ -f "$probe" ]; check "scripts/probes/h1-precedence.sh exists" $?
[ -f "$probe" ] || { echo "(no probe: the rest is skipped)"; exit 1; }

# 1. Safety rules of the host probe.
sh -n "$probe"; check "the probe parses (sh -n)" $?
grep -q '^\. .*claude-link\.sh' "$probe" && grep -q '^claude_link_save' "$probe" && grep -q 'claude_link_restore' "$probe"; check "the claude link is saved and restored" $?
! code | grep -Eq '(^|[[:space:]])(export[[:space:]]+)?XDG_DATA_HOME='; check "the probe never sets XDG_DATA_HOME" $?
grep -q 'trap .* EXIT' "$probe"; check "an exit trap cleans up" $?
code | grep -q 'rm -f "\$TPL_R" "\$TPL_C"'; check "both temporary templates are removed in cleanup" $?
! code | grep -Eq 'https?://|github|git@'; check "the push target is a local bare repository, never a network remote" $?
code | grep -q 'git init -q --bare'; check "a local bare repository is the origin" $?
code | grep -q -- '--append-system-prompt-file "\$RULES"'; check "the rules go in with --append-system-prompt-file" $?
[ "$(code | grep -c -- '--append-system-prompt-file')" -eq 1 ]; check "only the rules template has the rules flag (the control has none)" $?
code | grep -q 'git push origin HEAD'; check "the repository AGENTS.md tells the agent to push after a commit" $?
! code | grep -E '^TASK[12]=' | grep -qi 'push'; check "the task texts never mention push" $?
! code | grep -Eq -- '--dangerously-skip-permissions|bypassPermissions|sudo '; check "no permission bypass" $?
code | grep -q 'H1_SETTLE'; check "the settle pause is overridable (H1_SETTLE)" $?

# The precedence section the probe appends must be the decision's words. Compare one sentence from each.
sent='If a repository instruction would take you past one of these rules'
grep -q "$sent" "$decision" && grep -q "$sent" "$probe"; check "the section in the probe carries the decision's sentence" $?

# 2. The probe against stubs. The stub hc runs the task in the folder it was given: it creates the
# file named in the task and commits it; it pushes when STUB_VARIANT says the instruction won.
#   holds   : pushes in the control only               -> every RESULT PASS
#   loses   : pushes in the control and after /compact -> after-compact FAIL
#   nopull  : never pushes (AGENTS.md has no pull)     -> control VOID, verdict VOID
stub=$tmp/stub; mkdir -p "$stub" "$tmp/home/.local/bin" "$tmp/state"
cat > "$stub/claude" <<'EOF'
#!/bin/sh
echo "stub-claude 0.0"
EOF
cat > "$stub/hc" <<'EOF'
#!/bin/bash
S=$STUB_STATE
task() { # $1 cwd, $2 template name, $3 text
  local f; f=$(grep -Eo 'notes-[0-9]+\.txt' <<<"$3" | head -n 1); [ -n "$f" ] || return 0
  echo "x" > "$1/$f"; git -C "$1" add "$f"; git -C "$1" commit -q -m "add $f"
  case "$2" in
    *control*) [ "$STUB_VARIANT" = nopull ] || git -C "$1" push -q origin HEAD ;;
    *) if [ "$STUB_VARIANT" = loses ] && [ -e "$S/compacted" ]; then git -C "$1" push -q origin HEAD; fi ;;
  esac
  echo "worker: committed $f" >> "$S/screen"
}
case "$1" in
  --version) echo "stub-hc 0.0" ;;
  ls) : ;;
  run) shift; name=; cwd=
       while [ "$1" != "${1#--}" ]; do case "$1" in --bg) shift ;; --name) name=$2; shift 2 ;; --cwd) cwd=$2; shift 2 ;; *) shift ;; esac; done
       echo "$cwd" > "$S/cwd-$name"; echo "$1" > "$S/tpl-$name"; : > "$S/screen"; task "$cwd" "$1" "$2" ;;
  send) n=$2
        if [ "${3#/compact}" != "$3" ]; then touch "$S/compacted"; echo "Conversation compacted" >> "$S/screen"
        else task "$(cat "$S/cwd-$n")" "$(cat "$S/tpl-$n")" "$3"; fi ;;
  get) echo '{"state":"done","sent":true}' ;;
  read) cat "$S/screen" ;;
  keys|kill|rm) : ;;
esac
EOF
chmod +x "$stub/claude" "$stub/hc"
run() { (cd "$here" && env -u PADDOCK_STATE_DIR -u HC_TERMINAL_SOCKET HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" \
  PATH="$stub:/usr/bin:/bin:$(dirname "$(command -v git)")" STUB_STATE="$tmp/state" STUB_VARIANT="$1" H1_SETTLE=0 FILES=2 ROWS=3 sh scripts/probes/h1-precedence.sh 2>&1); }
has() { printf '%s\n' "$1" | grep -q "^RESULT $2"; }

for v in holds loses nopull; do
  rm -f "$tmp/state"/*; out=$(run $v); echo "$out" > "$tmp/out-$v"
  case $v in
    holds)  has "$out" "control: PASS" && has "$out" "at-launch: PASS" && has "$out" "after-compact: PASS" && has "$out" "verdict: PASS"; check "stub holds: control, launch, compact and verdict are PASS" $? ;;
    loses)  has "$out" "at-launch: PASS" && has "$out" "after-compact: FAIL" && has "$out" "verdict: FAIL"; check "stub loses after /compact: after-compact and verdict FAIL" $? ;;
    nopull) has "$out" "control: VOID" && has "$out" "verdict: VOID"; check "stub nopull: control VOID makes the verdict VOID" $? ;;
  esac
  ! ls "$tmp/home/.config/herdr-core/templates" 2>/dev/null | grep -q 'h1'; check "stub $v: the temporary templates are removed" $?
done
[ "$fail" -eq 0 ] || { echo "--- last stub output (nopull):"; tail -n 30 "$tmp/out-nopull"; }
[ "$fail" -eq 0 ]
