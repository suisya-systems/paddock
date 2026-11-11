#!/usr/bin/env bash
# Static check for Issue #216, step 1: the folder-trust probe scripts/probes/folder-trust-cases.sh
# compares the cases (plain sub-folder, git worktree, clone, worktree of a trusted repository) and
# keeps to the host probe rules: a temporary hc core only, no answer to the trust dialog, no write
# to ~/.claude.json, the claude link restored, no arguments. Nothing is run.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
p=$here/scripts/probes/folder-trust-cases.sh
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
# code = the probe without comment lines
code() { grep -vE '^[[:space:]]*#' "$p" 2>/dev/null; }

[ -f "$p" ]; check "probe exists" $?
bash -n "$p" 2>/dev/null; check "probe parses" $?

code | grep -q 'hc keys'; r=$?; [ -f "$p" ] && [ $r -ne 0 ]; check "never answers the dialog (no hc keys)" $?
code | grep -q 'hc send'; r=$?; [ -f "$p" ] && [ $r -ne 0 ]; check "sends nothing to a terminal (no hc send)" $?
code | grep -F '.claude.json' | sed 's#[0-9]*>/dev/null##g' | grep -Eq '>|tee|sed -i|\bmv\b|\bcp\b|\brm\b|\bln\b|\bjq\b'; r=$?
[ -f "$p" ] && [ $r -ne 0 ]; check "never writes ~/.claude.json" $?
code | grep -q 'claude\.json'; check "reads ~/.claude.json (to show the trust entries)" $?

code | grep -q '^HC_SESSION='; check "own HC_SESSION" $?
code | grep -q '^XDG_CONFIG_HOME='; check "own XDG_CONFIG_HOME" $?
code | grep -qE '(^|[[:space:]])XDG_DATA_HOME='; r=$?; [ -f "$p" ] && [ $r -ne 0 ]; check "sets no XDG_DATA_HOME" $?
code | grep -q 'hc server stop'; check "stops its own core in cleanup" $?
code | grep -q 'hc kill'; check "kills the terminal after reading the screen" $?
grep -q '^\. .*claude-link\.sh' "$p" 2>/dev/null && grep -q '^claude_link_save' "$p" && grep -q 'claude_link_restore' "$p"; check "saves and restores the claude link" $?
grep -q 'unknown argument' "$p" 2>/dev/null; check "takes no arguments" $?

code | grep -q 'git worktree add'; check "case: git worktree" $?
code | grep -qE 'git (clone|init)'; check "case: git repository under the workers folder" $?
grep -q 'case-plain' "$p" 2>/dev/null && grep -q 'case-worktree' "$p" && grep -q 'case-clone' "$p" && grep -q 'case-trusted-repo' "$p"; check "names the four cases" $?
code | grep -q 'hc read'; check "prints the observed screen" $?
grep -q 'case-trusted-in-workers' "$p" 2>/dev/null; check "names the case org-delegate uses (worktree of a trusted repository inside the workers folder)" $?
code | grep -E 'git -C "?\$TRUSTED_REPO"? worktree add' | grep -q '\$BASE'; check "that case adds the trusted repository's worktree under the workers folder" $?
code | grep -E 'hc (kill|rm) ' | grep -q 'trusted-in-workers'; check "cleanup kills and removes that case's terminal" $?
code | grep -q 'v=NO-DIALOG'; check "a screen without dialog text reads NO-DIALOG" $?
exit $fail
