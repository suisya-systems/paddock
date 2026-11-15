#!/usr/bin/env bash
# Decision 0014, host probe H3: scripts/probes/h3-rules-after-auto-compact.sh measures whether the
# secretary's standing rules (AGENTS.md + CLAUDE.md = @AGENTS.md in a non-git folder, mode F; or an
# --append-system-prompt-file file, mode R) hold after an AUTOMATIC compaction, and when an edit of
# the rules reaches the running session. This test checks the probe's safety rules and shape
# statically; no hc and no Claude Code run here (they run on the host).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
probe=$here/scripts/probes/h3-rules-after-auto-compact.sh
decision=$here/docs/decisions/0014-role-rules-skills-and-tools.md
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
code() { grep -vE '^[[:space:]]*#' "$probe"; }

[ -f "$probe" ]; check "scripts/probes/h3-rules-after-auto-compact.sh exists" $?
[ -f "$probe" ] || { echo "(no probe: the rest is skipped)"; exit 1; }

sh -n "$probe"; check "the probe parses (sh -n)" $?
! LC_ALL=C grep -q '[^[:print:][:space:]]' "$probe"; check "ASCII only (cp932 consoles)" $?

# Header: how to run it and how to read PASS.
head -n 60 "$probe" | grep -q 'sh scripts/probes/h3-rules-after-auto-compact.sh F'; check "header: run command for mode F" $?
head -n 60 "$probe" | grep -q 'sh scripts/probes/h3-rules-after-auto-compact.sh R'; check "header: run command for mode R" $?
head -n 60 "$probe" | grep -q 'PASS'; check "header: says how to read PASS" $?

# Mode argument is checked before anything touches hc.
empty=$(mktemp -d); trap 'rm -rf "$empty"' EXIT
out=$(cd "$here" && PATH="$empty:/usr/bin:/bin" sh "$probe" 2>&1); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'RESULT precondition-failed'; check "no mode: refused with a RESULT line" $?
out=$(cd "$here" && PATH="$empty:/usr/bin:/bin" sh "$probe" X 2>&1); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'RESULT precondition-failed'; check "unknown mode: refused with a RESULT line" $?

# The compaction must be automatic: the probe never types /compact.
! code | grep -q '/compact'; check "never types /compact" $?
code | grep -qi 'compaction'; check "detects the compaction from the screen" $?

# The folder: not a git repository, holding the two files; R keeps the rules outside the folder.
! code | grep -Eq 'git init|git clone'; check "never makes the folder a git repository" $?
code | grep -q 'rev-parse'; check "checks the folder is not inside a git repository" $?
code | grep -q '@AGENTS.md'; check "CLAUDE.md is @AGENTS.md" $?
code | grep -q 'AGENTS.md'; check "AGENTS.md holds the codeword rule" $?
code | grep -q -- '--append-system-prompt-file'; check "mode R passes --append-system-prompt-file" $?

# Steps: control, fill until compaction, ask after, edit mid-session, ask again, restart.
for s in S1 S2 S3 S4 S5 S6; do grep -q "== $s" "$probe"; check "step $s is printed" $?; done
code | grep -Eq 'sed .*(AGENTS|RULES)'; check "the rules file is edited mid-session" $?
code | grep -q 'hc kill'; check "a restart step relaunches the terminal" $?
code | grep -q '\.claude/projects'; check "replies are captured from the session transcript, not only the screen" $?
code | grep -q 'RESULT h3'; check "prints RESULT lines" $?

# Hygiene shared with the other probes.
grep -q '^\. .*claude-link\.sh' "$probe" && grep -q '^claude_link_save' "$probe" && grep -q 'claude_link_restore' "$probe"; check "the claude link is saved and restored" $?
grep -q 'trap .* EXIT' "$probe"; check "an exit trap cleans up" $?
code | grep -q '\$HOME/'; check "the folder lives under HOME (not /tmp: trust)" $?
! code | grep -Eq -- '--dangerously-skip-permissions|bypassPermissions'; check "no permission bypass" $?

# The decision record names the script in the H3 row.
grep -E '^\| H3 ' "$decision" | grep -q 'h3-rules-after-auto-compact.sh'; check "decision 0014 H3 row names the script" $?

[ "$fail" -eq 0 ] && echo "all ok"; exit "$fail"
