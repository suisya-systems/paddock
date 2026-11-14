#!/usr/bin/env bash
# Issue #353: the curator's write limit (only the state folder's knowledge/) is held by settings, not
# only by the template text. `org-curate.sh settings` writes a per-run --settings file from
# skills/org-curate/curator-settings.json (allowWrite: knowledge/ and the curator's own mail files), `start`
# writes it and starts the curator, and the curator template refuses to start without it and runs in
# knowledge/. hc and claude are stubs. Needs bash, coreutils and node (to read the JSON).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
oc=$here/skills/org-curate/scripts/org-curate.sh
tpl=$here/skills/org-curate/curator-settings.json
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
js() { f=$1 s=$2; shift 2; node -e "const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); $s" "$f" "$@"; }
clean_env() { env -u CLAUDECODE -u HC_TERMINAL_SOCKET -u PADDOCK_CORE_SOCKET_DIR -u PADDOCK_STATE_DIR -u XDG_STATE_HOME "$@"; }

# 1. The shared curator settings.
[ -f "$tpl" ]; check "skills/org-curate/curator-settings.json exists" $?
js "$tpl" 'const b=s.sandbox; process.exit(b.enabled===true && b.failIfUnavailable===true && b.allowUnsandboxedCommands===false && b.filesystem.allowWrite.length===0 ? 0 : 1)' 2>/dev/null
check "sandbox on, fail if unavailable, no unsandboxed rerun, allowWrite empty (filled per run)" $?
[ "$(grep -c '"allowWrite": \[\]' "$tpl" 2>/dev/null)" = 1 ]; check "exactly one empty \"allowWrite\": [] to fill in" $?
js "$tpl" 'process.exit(["Bash(git push:*)","Bash(hc:*)","Bash(gh pr:*)"].every(d=>s.permissions.deny.includes(d)) ? 0 : 1)' 2>/dev/null
check "the curator may not push, run hc or open pull requests" $?

# 2. `settings` writes the per-run file.
st=$tmp/state sock=$tmp/sock
out=$(clean_env PADDOCK_STATE_DIR="$st" PADDOCK_CORE_SOCKET_DIR="$sock" bash "$oc" settings 2>&1); rc=$?
cs=$st/settings/curator.json
[ "$rc" -eq 0 ] && [ -f "$cs" ]; check "settings writes <state>/settings/curator.json ($out)" $?
[ "$out" = "$cs" ]; check "settings prints the file's path" $?
js "$cs" 'process.exit(0)' 2>/dev/null; check "the generated file is valid JSON" $?
aw=$(js "$cs" 'console.log(s.sandbox.filesystem.allowWrite.join("\n"))' 2>/dev/null)
grep -qxF "$st/knowledge" <<<"$aw"; check "allowWrite names the knowledge folder" $?
grep -qxF "$st/events/curator.seq" <<<"$aw" && grep -qxF "$st/locks/curator" <<<"$aw" \
  && grep -q "^$st/events/[0-9-]*/curator.jsonl\$" <<<"$aw"; check "allowWrite names the curator's own mail files" $?
! grep -qxF "$st" <<<"$aw" && ! grep -q "secretary" <<<"$aw"; check "allowWrite names neither the whole state folder nor another id's file" $?
[ -f "$st/events/curator.seq" ] && [ -d "$st/knowledge" ]; check "the own files and the knowledge folder exist before the run" $?
js "$cs" 'const f=s.sandbox.filesystem; process.exit(f.denyRead.includes(process.argv[2]) && f.denyWrite.includes(process.argv[2]) ? 0 : 1)' "$sock" 2>/dev/null
check "the core's socket folder is denied (as for a worker)" $?
js "$cs" 'process.exit(s.env && s.env.PADDOCK_STATE_DIR===process.argv[2] ? 0 : 1)' "$st" 2>/dev/null
check "the file pins PADDOCK_STATE_DIR to the state folder it was made for" $?
rm -f "$cs"
clean_env PADDOCK_STATE_DIR="$st" bash "$oc" settings >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$cs" ]; check "no core socket folder known: refused, nothing written" $?
clean_env PADDOCK_STATE_DIR="$tmp/st\"ate" PADDOCK_CORE_SOCKET_DIR="$sock" bash "$oc" settings >/dev/null 2>&1
[ $? -ne 0 ]; check "a state path with a quote is refused (it goes into JSON)" $?
clean_env PADDOCK_STATE_DIR="$st" PADDOCK_CORE_SOCKET_DIR="$sock" bash "$oc" settings >/dev/null 2>&1

# 3. The file-tool hook of the generated file: only knowledge/ is let through.
hook=$(js "$cs" 'const h=s.hooks.PreToolUse.find(e=>/NotebookEdit/.test(e.matcher)); process.stdout.write(h.matcher+"\n"+h.hooks[0].command)' 2>/dev/null)
matcher=${hook%%$'\n'*}; hook=${hook#*$'\n'}
mkdir -p "$tmp/repo"
run_hook() { printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$1" \
  | clean_env HOME="$tmp/home" PADDOCK_STATE_DIR="$st" sh -c "$hook" >/dev/null 2>&1; }
run_hook "$st/knowledge/curated/a.md"; [ $? -eq 0 ]; check "hook: a curated note is let through" $?
run_hook "$st/knowledge/skill-candidates.md"; [ $? -eq 0 ]; check "hook: the candidate queue is let through" $?
run_hook "$tmp/repo/README.md"; [ $? -eq 2 ]; check "hook: the repository is refused" $?
run_hook "$st/events/secretary.jsonl"; [ $? -eq 2 ]; check "hook: the rest of the state folder is refused" $?
run_hook "$cs"; [ $? -eq 2 ]; check "hook: its own settings file is refused" $?
run_hook "$st/knowledge/../events/x"; [ $? -eq 2 ]; check "hook: .. out of knowledge/ is refused" $?
run_hook "$st/knowledge-x/a.md"; [ $? -eq 2 ]; check "hook: a sibling folder named knowledge-x is refused" $?
printf '{"tool_name":"Write","tool_input":{"file_path":"%s/knowledge/a\\"b","content":"x"}}' "$st" \
  | clean_env PADDOCK_STATE_DIR="$st" sh -c "$hook" >/dev/null 2>&1; [ $? -eq 2 ]; check "hook: a path with a JSON escape is refused" $?
printf '{"tool_name":"Write","tool_input":{"content":"x"}}' | clean_env PADDOCK_STATE_DIR="$st" sh -c "$hook" >/dev/null 2>&1
[ $? -eq 2 ]; check "hook: no path is refused" $?
for t in Edit Write MultiEdit NotebookEdit; do [[ $t =~ $matcher ]]; check "hook matcher takes $t" $?; done

# 4. `start` writes the file, then starts the curator with hc.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/hc" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_CALLS"
[ "$1" = run ] && [ -f "$STUB_CS" ] && echo settings-present >> "$STUB_CALLS"
exit 0
EOF
chmod +x "$tmp/bin/hc"
rm -f "$cs"
out=$(clean_env PATH="$tmp/bin:$PATH" STUB_CALLS="$tmp/calls" STUB_CS="$cs" PADDOCK_STATE_DIR="$st" \
  HC_TERMINAL_SOCKET="$sock/t.sock" bash "$oc" start 2>&1); rc=$?
[ "$rc" -eq 0 ]; check "start exits 0 ($out)" $?
grep -q '^run --bg --name curator curator' "$tmp/calls" 2>/dev/null; check "start runs hc run --bg --name curator curator" $?
grep -qx settings-present "$tmp/calls" 2>/dev/null; check "the settings file is written before the curator starts" $?
grep -qF "$oc" "$tmp/calls" 2>/dev/null; check "the brief names the org-curate script by its absolute path" $?
js "$cs" 'process.exit(s.sandbox.filesystem.denyRead.includes(process.argv[2]) ? 0 : 1)' "$sock" 2>/dev/null
check "start takes the socket folder from HC_TERMINAL_SOCKET" $?

# 5. The curator template: --settings is the per-run file, it runs in knowledge/, and it does not start without the file.
cmd=$(sed -n 's/^command: //p' "$here/templates/curator.md")
bd=$tmp/bd; mkdir -p "$bd"
printf '#!/bin/sh\necho "pwd=$(pwd)"; echo "args=$*"\n' > "$bd/fake-claude"; chmod +x "$bd/fake-claude"
printf '%s\n' "$bd/fake-claude" > "$bd/claude-path"
out=$(cd "$tmp" && clean_env PADDOCK_BIN_DIR="$bd" PADDOCK_STATE_DIR="$st" sh -c "$cmd" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -qxF "pwd=$st/knowledge" <<<"$out"; check "the curator runs in the knowledge folder ($out)" $?
grep -qF -- "--settings $cs" <<<"$out"; check "the curator is started with --settings <state>/settings/curator.json" $?
rm -f "$cs"
out=$(cd "$tmp" && clean_env PADDOCK_BIN_DIR="$bd" PADDOCK_STATE_DIR="$st" sh -c "$cmd" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! grep -q '^args=' <<<"$out"; check "without the settings file the curator does not start" $?

# 6. The secretary and the count line start it through org-curate.sh start.
grep -q 'org-curate.sh start' "$here/templates/secretary.md"; check "secretary.md starts the curator with org-curate.sh start" $?
! grep -q 'hc run --bg --name curator curator' "$here/templates/secretary.md"; check "no bare hc run of the curator is left in secretary.md" $?
grep -q 'start the curator: bash skills/org-curate/scripts/org-curate.sh start' "$oc"; check "the count line says to start the curator with org-curate.sh start" $?

[ "$fail" -eq 0 ]
