#!/usr/bin/env bash
# Acceptance test for the worker template (Issue #61): templates/worker.md, its rules
# file and settings file, and org-start placing them. Needs only bash, coreutils and
# node (for JSON.parse). Neither hc nor claude runs: both are stubs on PATH.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tpl=$here/templates/worker.md
sec=$here/templates/secretary.md
rules=$here/templates/worker-rules.md
settings=$here/templates/worker-settings.json
start=$here/skills/org-start/scripts/org-start.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
cmdline() { # cmdline <template>: the value of the command: header line
  sed -n '2,${/^---[[:space:]]*$/q;p;}' "$1" 2>/dev/null | grep -m1 '^command:' | sed 's/^command:[[:space:]]*//;s/[[:space:]]*$//'
}
body() { sed '1,/^---[[:space:]]*$/d' "$1" 2>/dev/null | sed '1,/^---[[:space:]]*$/d'; } # after the closing ---

# 1. The three files exist.
[ -f "$tpl" ]; check "templates/worker.md exists" $?
[ -f "$rules" ]; check "templates/worker-rules.md exists" $?
[ -f "$settings" ]; check "templates/worker-settings.json exists" $?

# 2. Header checker: the real templates pass, and a rules file (no front matter) is not a template.
(cd "$here" && bash scripts/check-templates.sh >/dev/null 2>&1); check "check-templates.sh passes on the repo" $?
mkdir -p "$tmp/fx/templates"
printf -- '---\ndescription: A role.\ncommand: claude\n---\nBody\n' > "$tmp/fx/templates/t.md"
printf 'Rules only, no header\n' > "$tmp/fx/templates/t-rules.md"
(cd "$tmp/fx" && bash "$here/scripts/check-templates.sh" >/dev/null 2>&1); check "a *-rules.md file without a header is not checked as a template" $?
printf 'No header\n' > "$tmp/fx/templates/u.md"
(cd "$tmp/fx" && bash "$here/scripts/check-templates.sh" >/dev/null 2>&1); [ $? -ne 0 ]; check "a real template without a header still fails" $?

# 3. Header fields.
desc=$(sed -n '2,${/^---[[:space:]]*$/q;p;}' "$tpl" 2>/dev/null | grep -m1 '^description:' | sed 's/^description:[[:space:]]*//')
[ -n "$desc" ]; check "description is non-empty" $?
cmd=$(cmdline "$tpl")
[ -n "$cmd" ]; check "command is non-empty" $?

# 4. The command starts with the secretary's env -u prefix; the lists are equal.
seccmd=$(cmdline "$sec"); prefix=${seccmd% claude}
[ -n "$cmd" ]; case "$cmd" in "$prefix "*) true ;; *) false ;; esac; check "command starts with the secretary's env -u prefix" $?
[ -n "$(grep -o -- '-u [A-Z_]*' <<<"$seccmd")" ]; check "secretary's env -u list is not empty" $?
[ -n "$cmd" ] && [ "$(grep -o -- '-u [A-Z_]*' <<<"$cmd" | sort)" = "$(grep -o -- '-u [A-Z_]*' <<<"$seccmd" | sort)" ]; check "env -u list equals the secretary's" $?

# 5. The command names the GH variables, the rules file, the settings file, the token file.
grep -q 'GH_CONFIG_DIR=' <<<"$cmd"; check "command sets GH_CONFIG_DIR" $?
grep -q 'GH_TOKEN=' <<<"$cmd"; check "command sets GH_TOKEN" $?
grep -q -- '--append-system-prompt-file .*worker-rules\.md' <<<"$cmd"; check "command passes worker-rules.md with --append-system-prompt-file" $?
grep -q -- '--settings .*worker-settings\.json' <<<"$cmd"; check "command passes worker-settings.json with --settings" $?
grep -q 'worker-gh-token' <<<"$cmd" && grep -q 'PADDOCK_WORKER_GH_TOKEN_FILE' <<<"$cmd"; check "command names the token file and its override" $?
[ -f "$tpl" ] && ! grep -Eq 'ghp_|github_pat_' "$tpl"; check "no token value in the template" $?

# 6. The command, run through sh with a stub claude.
stub=$tmp/bin; mkdir -p "$stub"
cat > "$stub/claude" <<'EOF2'
#!/bin/sh
{
  for a in "$@"; do echo "ARG:$a"; done
  echo "GH_TOKEN=${GH_TOKEN-unset}"
  echo "GH_CONFIG_DIR=${GH_CONFIG_DIR-unset}"
  echo "SESSION=${CLAUDE_CODE_SESSION_ID-unset}"
  echo "CHILD=${CLAUDE_CODE_CHILD_SESSION-unset}"
} > "$CLAUDE_OUT"
EOF2
chmod +x "$stub/claude"
cfg=$tmp/cfg; mkdir -p "$cfg/paddock"
launch() { # launch <out file> [extra env...]; runs the header command as hc would, through sh
  local out=$1; shift
  env -u APPDATA -u PADDOCK_WORKER_GH_TOKEN_FILE -u PADDOCK_CORE_TEMPLATES_DIR -u PADDOCK_BIN_DIR \
      XDG_CONFIG_HOME="$cfg" XDG_DATA_HOME="$tmp/data" PATH="$stub:$PATH" CLAUDE_OUT="$out" \
      CLAUDE_CODE_SESSION_ID=abc CLAUDE_CODE_CHILD_SESSION=1 GH_TOKEN=person-write-token "$@" \
      sh -c "$cmd" 2>&1
}
# 6a. Token file missing: the launch fails with a message naming the path; claude never runs.
rm -f "$cfg/paddock/worker-gh-token" "$tmp/o1"
msg=$([ -n "$cmd" ] && launch "$tmp/o1"); rc=$?
[ -n "$cmd" ] && [ "$rc" -ne 0 ] && [ ! -e "$tmp/o1" ]; check "missing token file fails the launch, claude not started" $?
grep -q "$cfg/paddock/worker-gh-token" <<<"$msg"; check "the failure message names the token path" $?
# 6b. Token file present: default path.
printf 'read-only-token-value\n' > "$cfg/paddock/worker-gh-token"
msg=$([ -n "$cmd" ] && launch "$tmp/o2"); rc=$?
[ "$rc" -eq 0 ] && [ -f "$tmp/o2" ]; check "token file present: claude is started" $?
grep -qx 'GH_TOKEN=read-only-token-value' "$tmp/o2" 2>/dev/null; check "GH_TOKEN is the token file's content, not the person's" $?
gd=$(sed -n 's/^GH_CONFIG_DIR=//p' "$tmp/o2" 2>/dev/null)
[ -n "$gd" ] && [ -d "$gd" ] && [ -z "$(ls -A "$gd")" ] && [ "$gd" != "$HOME/.config/gh" ]; check "GH_CONFIG_DIR is an existing empty directory" $?
[ -n "$cmd" ] && launch "$tmp/o3" >/dev/null
[ -n "$gd" ] && [ "$gd" != "$(sed -n 's/^GH_CONFIG_DIR=//p' "$tmp/o3" 2>/dev/null)" ]; check "GH_CONFIG_DIR differs per launch" $?
grep -qx 'SESSION=unset' "$tmp/o2" 2>/dev/null && grep -qx 'CHILD=unset' "$tmp/o2"; check "session-bound variables are removed before claude" $?
td=$tmp/data/paddock/bin # Issue #129: beside the org script, not in the core templates folder
grep -qx "ARG:--append-system-prompt-file" "$tmp/o2" 2>/dev/null && grep -qx "ARG:$td/worker-rules.md" "$tmp/o2"; check "claude gets the rules file from the paddock bin folder" $?
grep -qx "ARG:--settings" "$tmp/o2" 2>/dev/null && grep -qx "ARG:$td/worker-settings.json" "$tmp/o2"; check "claude gets the settings file from the paddock bin folder" $?
# 6c. Overrides.
printf 'other-token\n' > "$tmp/tok"; mkdir -p "$tmp/bdir"
[ -n "$cmd" ] && launch "$tmp/o4" PADDOCK_WORKER_GH_TOKEN_FILE="$tmp/tok" PADDOCK_BIN_DIR="$tmp/bdir" >/dev/null
grep -qx 'GH_TOKEN=other-token' "$tmp/o4" 2>/dev/null && grep -qx "ARG:$tmp/bdir/worker-rules.md" "$tmp/o4" && grep -qx "ARG:$tmp/bdir/worker-settings.json" "$tmp/o4"; check "PADDOCK_* overrides move the token file and the rules and settings folder" $?
: > "$tmp/empty"
[ -n "$cmd" ] && launch "$tmp/o5" PADDOCK_WORKER_GH_TOKEN_FILE="$tmp/empty" >/dev/null; rc=$?
[ -n "$cmd" ] && [ "$rc" -ne 0 ] && [ ! -e "$tmp/o5" ]; check "an empty token file also fails the launch" $?

# 7. Rules file and template body: English, the held lines are stated.
for f in "$tpl" "$rules"; do
  [ -f "$f" ] && ! LC_ALL=C grep -q -P '[^\x00-\x7F]' "$f"; r=$?; check "${f##*/} is ASCII only" $r
done
all=$(body "$tpl"; cat "$rules" 2>/dev/null)
for want in 'one task' 'worktree' 'hc send' 'scripts/org' 'PADDOCK_ORG' 'push' 'blocked' 'herdr' 'GitHub'; do
  grep -qi -- "$want" <<<"$all"; check "role text mentions: $want" $?
done
grep -qi 'never[^.]*hc send' <<<"$all"; check "role text forbids hc send" $?
[ -f "$tpl" ] && [ -f "$rules" ] && [ -f "$settings" ] && ! grep -Eiq "/home/|/Users/|happy_ryo|iwama" "$tpl" "$rules" "$settings"; check "no owner-specific paths or names" $?

# 8. Settings file parses and carries the entries the hold lines need.
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$settings" 2>/dev/null; check "worker-settings.json parses" $?
js() { node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const t=(x)=>JSON.stringify(x||null);'"$1" "$settings" 2>/dev/null; }
js 'process.exit(Array.isArray(s.permissions&&s.permissions.deny)&&s.permissions.deny.length>0?0:1)'; check "settings has a permissions.deny list" $?
js 'process.exit(/git push/.test(t(s.permissions.deny))?0:1)'; check "deny covers git push" $?
js 'process.exit(/Bash\(hc/.test(t(s.permissions.deny))?0:1)'; check "deny covers hc (L-N2)" $?
js 'process.exit(/herdr-core/.test(t(s.permissions.deny))&&/herdr-app/.test(t(s.permissions.deny))?0:1)'; check "deny covers herdr-core and herdr-app folders (L-N1)" $?
js 'process.exit(/hosts\.yml/.test(t(s.permissions.deny))?0:1)'; check "deny covers the GitHub CLI login file (L-K2 second line)" $?
js 'process.exit(s.sandbox&&s.sandbox.enabled===true?0:1)'; check "sandbox is enabled" $?
js 'process.exit(/herdr-core/.test(t(s.sandbox.filesystem&&s.sandbox.filesystem.denyRead))?0:1)'; check "sandbox denyRead covers herdr's state (L-N9)" $?
js 'process.exit(/herdr-app/.test(t(s.sandbox.filesystem&&s.sandbox.filesystem.denyRead))?0:1)'; check "sandbox denyRead covers the window's files (L-N9)" $?
js 'process.exit(/herdr-core/.test(t(s.sandbox.filesystem&&s.sandbox.filesystem.denyWrite))?0:1)'; check "sandbox denyWrite covers herdr-core (L-N1)" $?
js 'process.exit(!("defaultMode" in (s.permissions||{}))?0:1)'; check "settings sets no defaultMode (ignored there, Q10)" $?

# 9. org-start places the template with the secretary template, the rules and settings in the bin folder, and warns when the token is missing.
hcstub=$tmp/hcbin; mkdir -p "$hcstub"
cat > "$hcstub/hc" <<'EOF3'
#!/bin/sh
case "$1" in
  ls) echo ok ;;
  get) [ -f "$STUB/secretary" ] || exit 1
       echo '{"name":"secretary","status":{"app":"claude-code","state":"idle"}}' ;;
  run) : > "$STUB/secretary"; echo '{"name":"secretary"}' ;;
esac
exit 0
EOF3
chmod +x "$hcstub/hc"; mkdir -p "$tmp/stubstate"
xdg=$tmp/xdg; mkdir -p "$xdg"
startrun() { # startrun [extra env...]
  env -u APPDATA -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u PADDOCK_WORKER_GH_TOKEN_FILE \
      STUB="$tmp/stubstate" PATH="$hcstub:$PATH" XDG_CONFIG_HOME="$xdg" \
      PADDOCK_CORE_TEMPLATES_DIR="$tmp/placed" PADDOCK_APP_MODS_DIR="$tmp/mods" PADDOCK_BIN_DIR="$tmp/placed-bin" PADDOCK_READY_TRIES=2 \
      "$@" bash "$start" 2>&1
}
out=$(startrun); rc=$?
[ "$rc" -eq 0 ]; check "org-start still exits 0 when the token file is missing" $?
[ -f "$tpl" ] && cmp -s "$tpl" "$tmp/placed/worker.md"; check "org-start placed worker.md" $?
for f in worker-rules.md worker-settings.json; do # Issue #129: beside the org script, not with the templates
  [ -f "$here/templates/$f" ] && cmp -s "$here/templates/$f" "$tmp/placed-bin/$f" && [ ! -e "$tmp/placed/$f" ]; check "org-start placed $f in the bin folder, not the templates folder" $?
done
cmp -s "$sec" "$tmp/placed/secretary.md"; check "org-start still places secretary.md" $?
grep -qi 'warn' <<<"$out" && grep -q "$xdg/paddock/worker-gh-token" <<<"$out"; check "missing token file: warning names the default path" $?
mkdir -p "$xdg/paddock"; printf 'tok-secret-value\n' > "$xdg/paddock/worker-gh-token"
out=$(startrun); rc=$?
[ "$rc" -eq 0 ] && ! grep -qi 'warn' <<<"$out"; check "token file present: no warning" $?
! grep -q 'tok-secret-value' <<<"$out"; check "org-start never prints the token" $?
out=$(startrun PADDOCK_WORKER_GH_TOKEN_FILE="$tmp/nowhere"); rc=$?
[ "$rc" -eq 0 ] && grep -qi 'warn' <<<"$out" && grep -q "$tmp/nowhere" <<<"$out"; check "override path is the one checked" $?

# 10. Docs and CI follow the template.
! grep -m1 '^Not in it' "$here/docs/design/prototype-1.md" | grep -qi 'the worker template'; check "prototype-1 no longer lists the worker template as not built" $?
grep -q 'templates/worker' "$here/README.md"; check "README names the worker template" $?
for row in 'L-N1' 'L-N2' 'L-N9' 'L-K2' 'L-K4' 'INS-12'; do
  grep "^| $row" "$here/docs/design/predecessor-inventory.md" | grep -q 'templates/worker'; check "inventory row $row points at the worker template" $?
done
grep -Eq 'tests/(worker-template|\*)\.test\.sh|tests/\*\.test\.sh' "$here/.github/workflows/ci.yml"; check "CI runs this test (by name or by the tests/*.test.sh glob)" $?

exit $fail
