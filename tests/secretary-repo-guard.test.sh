#!/usr/bin/env bash
# The secretary's PreToolUse hook refuses a Bash, Read, Grep, Glob or Agent call that names a folder under $HOME
# outside paddock's own (state, checkout, projects, workers, local, bin, config, ~/.claude, $TMPDIR) and the
# paths in projects.md; the refusal names paddock:org-clone. HOME is a temp folder. Needs bash and node.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
settings=$here/templates/secretary-settings.json
H=$tmp/home
mkdir -p "$H/.config/paddock"
printf '| name | path | base |\n|---|---|---|\n| kura | %s/src/kura | main |\n| t | ~/tilde/repo | main |\n| sp | %s/My Repo | main |\n' "$H" "$H" > "$H/.config/paddock/projects.md"

for t in Bash Read Grep Glob Agent; do
  node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const m = (s.hooks.PreToolUse || []).find((x) => new RegExp(x.matcher).test(process.argv[2]));
    process.exit(m && /secretary-bash-guard\.sh/.test(m.hooks[0].command) ? 0 : 1);' "$settings" "$t"
  check "secretary-settings.json runs secretary-bash-guard.sh on $t" $?
done
hook=$(node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(s.hooks.PreToolUse.find(x=>new RegExp(x.matcher).test("Read")).hooks[0].command)' "$settings")

err=
fire() { # fire <tool> <tool_input as JSON>
  run_hook "$(printf '{"tool_name":"%s","tool_input":%s}' "$1" "$2")"
}
run_hook() { # run_hook <payload>
  err=$(printf '%s' "$1" |
        env -u XDG_STATE_HOME -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u APPDATA -u PADDOCK_STATE_DIR -u PADDOCK_PROJECTS_DIR \
            -u PADDOCK_WORKERS_DIR -u PADDOCK_LOCAL_DIR -u PADDOCK_PROJECTS_FILE -u CLAUDE_TMPDIR \
            HOME="$H" TMPDIR="$H/tmpdir" PADDOCK_HOME="$H/work/paddock" PADDOCK_BIN_DIR="$here/scripts/hooks" sh -c "$hook" 2>&1 >/dev/null)
}
js() { node -e 'process.stdout.write(JSON.stringify(JSON.parse(process.argv[1])))' "$1"; }
bash_in() { node -e 'process.stdout.write(JSON.stringify({command:process.argv[1]}))' "$1"; }
refused() { fire "$1" "$2"; local rc=$?; [ $rc -eq 2 ] && grep -q 'paddock:org-clone' <<<"$err"; check "refused ($rc): $1 $2" $?; }
allowed() { fire "$1" "$2"; local rc=$?; [ $rc -eq 0 ]; check "allowed ($rc): $1 $2 ${err:0:120}" $?; }

for c in 'ls ~/work/x' 'git -C ~/work/x fetch' 'cat $HOME/work/x/f' 'cd ${HOME}/src && ls' "ls $H/work/x" 'find ~ -name kura' \
         'ls "$HOME/work/x"' 'ls ~/paddock-workers/../work/x' 'git status; cat ~/.ssh/config' 'cat "$HOME/Private Repo/f"' "cat '~/work/a b'" 'ls ~/.claude ~/work' \
         'X=~/work/x; ls $X'; do
  refused Bash "$(bash_in "$c")"
done
refused Read "{\"file_path\":\"$H/work/x/f\"}"
refused Grep "{\"pattern\":\"x\",\"path\":\"$H/src\"}"
refused Glob "{\"pattern\":\"$H/work/**/*.md\"}"
refused Agent "$(js "{\"prompt\":\"Read the repository at $H/work/x and summarise it\"}")"

for c in 'cat ~/.local/state/paddock/org-state.json' 'ls $HOME/paddock-workers/t1' 'ls ~/paddock-projects/o/n' \
         'ls ~/paddock-local/t1' 'cat ~/.claude/projects/m/MEMORY.md' "cat $H/src/kura/README.md" 'ls ~/tilde/repo/src' \
         'bash "$PADDOCK_HOME/scripts/org" --as secretary check_messages' "ls $H/work/paddock/skills" \
         'cat ~/.config/paddock/projects.md' 'ls $TMPDIR/x' 'git log HEAD~1' 'ls /tmp/x' \
         'bash "$PADDOCK_HOME/scripts/org" --as secretary config project add kd ~/work/kd' \
         'bash x.sh --task t1 --task "Never touch ~/work/x, the person keeps it"' 'echo $HOMEBREW_PREFIX' \
         'ls ~other/repo' "ls ${H}2/repo" 'cat "$HOME/My Repo/README.md"'; do
  allowed Bash "$(bash_in "$c")"
done
allowed Read "{\"file_path\":\"$H/src/kura/f\"}"
allowed Read "{\"file_path\":\"$H/tmpdir/task.md\"}"
allowed Read "{\"file_path\":\"$H/My Repo/a b.md\"}"
refused Read "{\"file_path\":\"$H/My Other/a.md\"}"
allowed Grep "{\"pattern\":\"x\",\"path\":\"$H/paddock-workers/t1\"}"
allowed Glob "{\"pattern\":\"**/*.md\"}"
allowed Agent '{"prompt":"Summarise the mailbox"}'
# a call with no tool_name is a Bash call, as before
run_hook '{"tool_input":{"command":"ls ~/work/x"}}'
[ $? -eq 2 ]; check "refused without tool_name: ls ~/work/x" $?
exit $fail
