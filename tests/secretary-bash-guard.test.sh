#!/usr/bin/env bash
# Issue #378: the secretary's PreToolUse hook refuses long blocking shell calls (a CI watch, a sleep
# over 5 s, a loop that sleeps) and keeps refusing hc keys / a forced hc send; heredoc bodies and
# quoted text that only mention these commands pass. Needs bash and node (to build the JSON payload).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
hook=$(node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const m = (s.hooks.PreToolUse || []).find((x) => new RegExp(x.matcher).test("Bash"));
  process.stdout.write(m ? m.hooks[0].command : "");' "$here/templates/secretary-settings.json")
grep -q 'secretary-bash-guard\.sh' <<<"$hook"; check "secretary-settings.json runs secretary-bash-guard.sh on Bash" $?
err=
fire() {
  err=$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1],description:"gh run watch; sleep 600",timeout:200000}}))' "$1" |
        PADDOCK_BIN_DIR=$here/scripts/hooks sh -c "$hook" 2>&1 >/dev/null)
}
refused() { fire "$1"; local rc=$?; [ $rc -eq 2 ] && grep -q "$2" <<<"$err"; check "refused ($rc): $1" $?; }
allowed() { fire "$1"; local rc=$?; [ $rc -eq 0 ]; check "allowed ($rc): $1" $?; }

for c in 'gh pr checks 377 --watch' 'gh pr checks --watch --interval 10 377' 'gh run watch 123' \
         'cd /x && gh run watch' 'gh pr checks 5 --required --watch'; do
  refused "$c" 'org wait --children'
done
for c in 'sleep 60' 'sleep 6' 'sleep 2m' 'sleep infinity' 'echo a; sleep 30 && echo b' 'sleep 1 30'; do
  refused "$c" 'hc run --bg'
done
refused 'while ! gh pr view 5 --json state | grep -q MERGED; do sleep 5; done' 'polling loop'
refused 'until hc get w-t1 | grep -q idle; do sleep 2; done' 'polling loop'
refused $'for i in 1 2 3\ndo\n  gh pr checks 5\n  sleep 3\ndone' 'polling loop'
refused "bash -c 'gh pr checks 5 --watch'" 'CI watch'
# the old refusal set, unchanged
for c in 'hc keys w-t1 enter' '/usr/local/bin/hc keys t3 esc' 'hc send --force w-t1 yes' 'hc send w-t1 -f yes'; do
  refused "$c" 'L-N3'
done

for c in 'bash scripts/org --as secretary wait --children' \
         'bash skills/org-pull-request/scripts/org-pull-request.sh --task t1 --title "x" --body-file b.md' \
         'sleep 1' 'sleep 0.5' 'sleep 5' 'gh pr checks 377' 'gh pr checks 377 --required' 'gh pr view 377' 'gh run view 5' \
         'git status' 'ls -la' 'hc send w-t1 hello' 'hc read w-t1' 'grep -n watch file' 'echo sleeping' \
         'hc run --bg --name ci-5 sh -c "gh pr checks 5 --watch"'; do
  allowed "$c"
done
# heredoc bodies and quoted text that mention the commands
allowed $'cat > "$TMPDIR/task.md" <<\'EOF\'\nDo not run gh run watch or gh pr checks --watch; no sleep 60, no while true; do sleep 5; done.\nNever hc keys w-t1 enter, never hc send --force w-t1.\nEOF\nbash skills/org-delegate/scripts/org-delegate.sh --project p --task-id t1 --task-file "$TMPDIR/task.md"'
allowed $'cat <<-EOF > b.md\n\tgh run watch 5\n\tsleep 600\n\tEOF\ngh pr view 5'
allowed $'git commit -F - <<EOF\nsleep 99\nEOF'
allowed 'bash skills/org-delegate/scripts/org-delegate.sh --task-id t2 --task "Never run gh pr checks --watch or sleep 60; hc keys is refused."'
allowed "git commit -m 'stop the secretary from a sleep 600 loop: while true; do sleep 9; done'"
allowed 'cat <<< "sleep 60"'
# a heredoc ends at its word: a blocking call after it is still seen
refused $'cat > f <<EOF\ntext\nEOF\nsleep 60' 'sleep over'
exit $fail
