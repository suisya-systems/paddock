#!/bin/bash
# Issue #245 review: the worker settings' file-tool hook reads the path with grep, not a JSON parser,
# so a path it cannot read exactly (a JSON escape: quote, backslash, control character) or no path
# at all is refused, not let through. A symlink named state"link into the state folder was the bypass.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
hook=$(node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const h = s.hooks.PreToolUse.find(e => /NotebookEdit/.test(e.matcher));
  process.stdout.write(h.matcher + "\n" + h.hooks[0].command)' "$here/templates/worker-settings.json")
matcher=${hook%%$'\n'*}; hook=${hook#*$'\n'}
mkdir -p "$tmp/home/.local/state/paddock/events" "$tmp/home/wt"
ln -s "$tmp/home/.local/state/paddock/events" "$tmp/home/wt/state\"link"
run_hook() { printf '%s' "$1" | env -u PADDOCK_STATE_DIR -u XDG_STATE_HOME HOME="$tmp/home" sh -c "$hook" >/dev/null 2>&1; }

run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$tmp/home/wt/state\\\"link/secretary.jsonl\",\"content\":\"x\"}}"
[ $? -eq 2 ]; check "a path with an escaped quote (symlink state\"link into the state folder) is refused" $?
run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$tmp/home/wt/a\\\\b\",\"content\":\"x\"}}"
[ $? -eq 2 ]; check "a path with an escaped backslash is refused" $?
run_hook '{"tool_name":"Write","tool_input":{"content":"x"}}'
[ $? -eq 2 ]; check "a payload with no path is refused" $?
run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$tmp/home/wt/plain.txt\",\"content\":\"a \\\"quoted\\\" text\"}}"
[ $? -eq 0 ]; check "a plain worktree path is let through (escapes in the content do not count)" $?
for t in Edit Write MultiEdit NotebookEdit; do [[ $t =~ $matcher ]]; check "the matcher takes $t" $?; done
for t in mcp__x__Write_doc EditTool; do ! [[ $t =~ $matcher ]]; check "the matcher does not take $t (no path to check)" $?; done

[ "$fail" -eq 0 ]
