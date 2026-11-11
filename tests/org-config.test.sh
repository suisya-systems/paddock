#!/usr/bin/env bash
# Acceptance test for `org config` (Issue #193): set for the known keys, project add/set/drop.
# A merge approval mode set here changes how org-pull-request acts; an unknown key exits 2;
# a conversation language set here ends a stubbed org-start's launch task. hc and gh are stubs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
org=$here/scripts/org
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

export PADDOCK_STATE_DIR=$tmp/state PADDOCK_ORG_CONFIG_FILE=$tmp/cfg/org-config.md PADDOCK_PROJECTS_FILE=$tmp/cfg/projects.md
cfg=$PADDOCK_ORG_CONFIG_FILE
sec() { bash "$org" --as secretary "$@"; }

# Unknown key and bad values: exit 2, nothing written.
sec config set no_such_key x >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$cfg" ]; check "an unknown key exits 2 and writes nothing" $?
sec config set merge_approval_mode sometimes >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$cfg" ]; check "a value outside human|acceptance exits 2" $?
bash "$org" --as worker-1 config set merge_approval_mode acceptance >/dev/null 2>&1; rc=$?
[ "$rc" -eq 7 ] && [ ! -e "$cfg" ]; check "only the secretary writes settings (exit 7)" $?

# Set and replace: one line per key, the other lines stay.
sec config set conversation_language ja >/dev/null; rc=$?
[ "$rc" -eq 0 ] && grep -qx 'conversation_language: ja' "$cfg"; check "set writes a key: value line" $?
sec config set merge_approval_mode acceptance >/dev/null && sec config set conversation_language fr >/dev/null
[ "$(grep -c '^conversation_language:' "$cfg")" -eq 1 ] && grep -qx 'conversation_language: fr' "$cfg" \
  && grep -qx 'merge_approval_mode: acceptance' "$cfg"; check "set again replaces the line and keeps the others" $?
[ "$(sec config get merge_approval_mode)" = acceptance ] && [ "$(sec config get conversation_language)" = fr ]; check "get prints the value" $?
mv -f "$cfg" "$cfg.old"
[ "$(sec config get merge_approval_mode)" = human ] && [ "$(sec config get conversation_language)" = auto ]; check "get prints the script default when the file has no line" $?

# Projects: a table read by header name (the reader is skills/org-delegate/scripts/project.sh).
. "$here/skills/org-delegate/scripts/project.sh"; project_path=; project_base=; project_secret=
sec config project add alpha /w/alpha --base develop >/dev/null; rc=$?
project_lookup alpha; l=$?
[ "$rc" -eq 0 ] && [ "$l" -eq 0 ] && [ "$project_path" = /w/alpha ] && [ "$project_base" = develop ] && [ -z "$project_secret" ]; check "project add: project_lookup reads path and base back" $?
sec config project add alpha /w/other >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; check "project add of an existing name exits 2" $?
sec config project add beta /w/beta --secret-block on >/dev/null
sec config project set alpha --base main --secret-block on >/dev/null; rc=$?
project_lookup beta
[ "$rc" -eq 0 ] && [ "$project_path" = /w/beta ] && [ "$project_secret" = on ]; check "project set keeps the other rows" $?
project_lookup alpha; [ "$project_path" = /w/alpha ] && [ "$project_base" = main ] && [ "$project_secret" = on ]; check "project set changes only the named columns" $?
sec config project set gamma --base x >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; check "project set of a missing name exits 2" $?
sec config project drop alpha >/dev/null; rc=$?
project_lookup alpha; l=$?; project_lookup beta; l2=$?
[ "$rc" -eq 0 ] && [ "$l" -eq 1 ] && [ "$l2" -eq 0 ]; check "project drop removes the row only" $?
sec config project add 'bad|name' /w/x >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; check "a name with | exits 2" $?

# Stubs for org-pull-request and org-start.
stubdir=$tmp/bin; mkdir -p "$stubdir" "$tmp/stub"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
echo "hc $*" >> "$STUB/calls"
case $1 in
  wait) echo '{"children":[],"ended":true,"exit_code":0,"reason":"exit","signal":null,"status":null,"terminal":"t","turn":0}'; exit 0 ;;
  connect) cat >/dev/null; echo '{"jsonrpc":"2.0","id":1,"result":{"value":null,"version":0}}'; exit 0 ;;
  get) [ -f "$STUB/secretary" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       echo '{"name":"secretary","state":"live","status":{"app":"claude-code","state":"idle"}}'; exit 0 ;;
  run) : > "$STUB/secretary"; echo '{"name":"secretary"}'; exit 0 ;;
esac
exit 0
EOF2
cat > "$stubdir/gh" <<'EOF2'
#!/bin/sh
echo "gh $*" >> "$STUB/calls"
case "$1 $2" in
  "pr create") echo "https://github.com/o/r/pull/42" ;;
  "run list") echo 777 ;;
  "pr view") cat "$STUB/head" ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc" "$stubdir/gh"
calls=$tmp/stub/calls

# org-pull-request follows the setting.
wt=$tmp/wt; n=0
git init -q --bare "$tmp/o0.git"; git clone -q "$tmp/o0.git" "$wt" 2>/dev/null
git -C "$wt" checkout -q -b feat/x
git -C "$wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
git -C "$wt" rev-parse HEAD > "$tmp/stub/head"
body=$tmp/body.md; echo body > "$body"
pr() { # a fresh empty origin for each run, then the script
  n=$((n + 1)); git init -q --bare "$tmp/o$n.git"; git -C "$wt" remote set-url origin "$tmp/o$n.git"
  : > "$calls"
  env -u PADDOCK_NOW STUB="$tmp/stub" PADDOCK_RUN_SLEEP=0 PADDOCK_RUN_TRIES=3 PATH="$stubdir:$PATH" \
    bash "$here/skills/org-pull-request/scripts/org-pull-request.sh" --worktree "$wt" --repo o/r --title t --body-file "$body" >/dev/null 2>&1
}
pr; ! grep -q '^gh pr merge' "$calls"; check "no setting: org-pull-request does not merge (human)" $?
sec config set merge_approval_mode acceptance >/dev/null
pr; grep -q '^gh pr merge' "$calls"; check "after config set merge_approval_mode acceptance, org-pull-request merges" $?
sec config set merge_approval_mode human >/dev/null
pr; ! grep -q '^gh pr merge' "$calls"; check "after setting human it stops again" $?

# org-start ends its launch task with the conversation language.
start() {
  rm -f "$tmp/stub/secretary"; : > "$calls"
  env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
    STUB="$tmp/stub" PATH="$stubdir:$PATH" PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" PADDOCK_APP_MODS_DIR="$tmp/app/mods" \
    PADDOCK_APP_LAYOUTS_DIR="$tmp/app/layouts" PADDOCK_BIN_DIR="$tmp/bin-org" PADDOCK_READY_TRIES=2 \
    bash "$here/skills/org-start/scripts/org-start.sh" >/dev/null 2>&1
}
sec config set conversation_language auto >/dev/null; start
grep -qx "hc run --bg --keep --name secretary --cwd $here secretary" "$calls"; check "language auto: the launch has no task" $?
sec config set conversation_language ja >/dev/null; start
grep "^hc run " "$calls" | grep -q 'Conversation language: ja$'; check "after config set conversation_language ja, org-start's launch task ends with it" $?

exit "$fail"
