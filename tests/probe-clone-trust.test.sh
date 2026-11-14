#!/usr/bin/env bash
# Static check for Issue #362: the host probe scripts/probes/clone-trust.sh parses, refuses bad arguments before it
# touches anything, never presses a key or writes the person's Claude config, clones only into its own temp
# folder, and prints every RESULT. The probe itself is not run (it needs GitHub, hc and a claude worker).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
p=$here/scripts/probes/clone-trust.sh
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

[ -f "$p" ]; check "probe exists" $?
sh -n "$p" 2>/dev/null; check "sh -n parses" $?
sh "$p" --help 2>&1 | grep -q 'Issue #362'; check "--help prints the usage" $?
sh "$p" --help 2>&1 | LC_ALL=C grep -qP '[^\x00-\x7F]'; r=$?; [ $r -ne 0 ]; check "--help is ASCII only (cp932 consoles)" $?
LC_ALL=C grep -qP '[^\x00-\x7F]' "$p"; r=$?; [ $r -ne 0 ]; check "the whole probe is ASCII only" $?

for r in clone-cli clone-git base rerun-skip no-access trust-held trust-answer marker-cleared; do
  grep -q "res $r\|RESULT $r" "$p"; check "reports RESULT $r" $?
done
code=$(grep -vE '^[[:space:]]*#' "$p")
printf '%s\n' "$code" | grep -qE 'hc keys|hc send'; r=$?; [ $r -ne 0 ]; check "never presses a key or types into a terminal itself" $?
printf '%s\n' "$code" | grep -qE '\.claude\.json'; r=$?; [ $r -ne 0 ]; check "never touches the person's Claude config" $?
printf '%s\n' "$code" | grep -q 'PADDOCK_PROJECTS_DIR="\$WORK/pp"'; check "clones into its own temp folder" $?
printf '%s\n' "$code" | grep -q 'PADDOCK_PROJECTS_FILE="\$WORK/projects.md"'; check "registers in its own temp projects.md" $?
printf '%s\n' "$code" | grep -q 'org-clone.sh'; check "runs org-clone" $?
printf '%s\n' "$code" | grep -q 'org-escalation.sh'; check "uses org-escalation prompt/ask/answer" $?
printf '%s\n' "$code" | grep -qE 'push|--force|--admin'; r=$?; [ $r -ne 0 ]; check "pushes nothing" $?

cd "$here" || exit 1
sh "$p" --bogus >/dev/null 2>&1; [ $? -eq 2 ] || false; check "unknown option exits 2" $?
sh "$p" --repo noslash >/dev/null 2>&1; [ $? -eq 2 ] || false; check "--repo without OWNER/NAME exits 2" $?
sh "$p" --repo a/b --task-id 'A B' >/dev/null 2>&1; [ $? -eq 2 ] || false; check "a bad --task-id exits 2" $?
exit $fail
