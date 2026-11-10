#!/usr/bin/env bash
# Acceptance test for Issue #128: a worker can reach the org script.
# The path the worker template exports as PADDOCK_ORG must not be under a folder the
# worker settings deny reading, nor under a folder the worker may write; org-start must
# place scripts/org at exactly that path; and a report done run through it must land in
# the secretary's box. Needs bash, coreutils and node (JSON.parse). hc and claude are stubs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tpl=$here/templates/worker.md
settings=$here/templates/worker-settings.json
start=$here/skills/org-start/scripts/org-start.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
cmd=$(sed -n '2,${/^---[[:space:]]*$/q;p;}' "$tpl" | grep -m1 '^command:' | sed 's/^command:[[:space:]]*//;s/[[:space:]]*$//')

# Stubs: claude prints PADDOCK_ORG; hc answers just enough for org-start.
bin=$tmp/bin; mkdir -p "$bin" "$tmp/stub"
printf '#!/bin/sh\necho "$PADDOCK_ORG" > "$CLAUDE_OUT"\n' > "$bin/claude"
cat > "$bin/hc" <<'EOF2'
#!/bin/sh
case "$1" in
  ls) echo ok ;;
  get) [ -f "$STUB/secretary" ] || exit 1
       echo '{"name":"secretary","status":{"app":"claude-code","state":"idle"}}' ;;
  run) : > "$STUB/secretary"; echo '{"name":"secretary"}' ;;
esac
exit 0
EOF2
chmod +x "$bin/claude" "$bin/hc"

home=$tmp/home; mkdir -p "$home/.config/paddock"
printf 'tok\n' > "$home/.config/paddock/worker-gh-token"
clean() { # clean <cmd...>: scratch HOME, none of the folder overrides, no agent variables
  env -u APPDATA -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
      -u PADDOCK_CORE_TEMPLATES_DIR -u PADDOCK_APP_MODS_DIR -u PADDOCK_BIN_DIR \
      -u PADDOCK_WORKER_GH_TOKEN_FILE -u PADDOCK_STATE_DIR -u PADDOCK_ORG_ID \
      -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
      HOME="$home" PATH="$bin:$PATH" STUB="$tmp/stub" PADDOCK_READY_TRIES=1 "$@"
}
exported() { # exported [env...]: PADDOCK_ORG as the worker template's command sets it
  rm -f "$tmp/out"; clean CLAUDE_OUT="$tmp/out" "$@" sh -c "$cmd" >/dev/null 2>&1; cat "$tmp/out" 2>/dev/null
}

# 1. The exported path is not under a denied read prefix, nor under a writable one.
org=$(exported)
[ -n "$org" ]; check "the worker template exports PADDOCK_ORG ($org)" $?
prefixes() { # prefixes <js expression giving an array>: one expanded path per line, /** stripped
  node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const a='"$1"';for(const x of a||[])console.log(x)' "$settings" \
    | sed "s|^~|$home|; s|/\*\*\$||; s|/\$||"
}
under() { case "$1" in "$2"|"$2"/*) return 0 ;; esac; return 1; } # under <path> <prefix>
hit=
while IFS= read -r p; do [ -n "$p" ] && under "$org" "$p" && hit="$hit $p"; done < <(
  prefixes 's.permissions.deny.filter(r=>/^Read\(/.test(r)).map(r=>r.slice(5,-1))'
  prefixes 's.sandbox.filesystem.denyRead')
[ -n "$org" ] && [ -z "$hit" ]; check "PADDOCK_ORG is not under a read deny of the worker settings${hit:+ (under$hit)}" $?
hit=
while IFS= read -r p; do [ -n "$p" ] && under "$org" "$p" && hit="$hit $p"; done < <(prefixes 's.sandbox.filesystem.allowWrite')
[ -n "$org" ] && [ -z "$hit" ]; check "PADDOCK_ORG is not under a folder the worker may write${hit:+ (under$hit)}" $?
under "$org" "$here"; [ $? -ne 0 ]; check "PADDOCK_ORG is outside the repository" $?

# 2. The worker settings keep the script's folder from being edited.
den=$(prefixes 's.permissions.deny.filter(r=>/^Edit\(/.test(r)).map(r=>r.slice(5,-1))')
dw=$(prefixes 's.sandbox.filesystem.denyWrite')
dir=${org%/*}; e=1; w=1
while IFS= read -r p; do [ -n "$p" ] && under "$dir" "$p" && e=0; done <<<"$den"
while IFS= read -r p; do [ -n "$p" ] && under "$dir" "$p" && w=0; done <<<"$dw"
[ -n "$org" ] && [ "$e" -eq 0 ]; check "permissions.deny has an Edit deny covering the script's folder" $?
[ -n "$org" ] && [ "$w" -eq 0 ]; check "sandbox denyWrite covers the script's folder" $?

# 3. org-start places scripts/org at exactly that path (defaults on both sides).
out=$(clean bash "$start" 2>&1); rc=$?
[ "$rc" -eq 0 ]; check "org-start exits 0 with default folders" $?
[ -n "$org" ] && cmp -s "$here/scripts/org" "$org"; check "org-start placed scripts/org at the exported path" $?
[ ! -e "$home/.config/herdr-core/templates/org" ]; check "no org copy left in the core templates folder" $?

# 4. One override moves both sides together; a relative one is refused.
org2=$(exported PADDOCK_BIN_DIR="$tmp/obin")
[ "$org2" = "$tmp/obin/org" ]; check "PADDOCK_BIN_DIR moves the exported path ($org2)" $?
clean PADDOCK_BIN_DIR="$tmp/obin" bash "$start" >/dev/null 2>&1
cmp -s "$here/scripts/org" "$tmp/obin/org"; check "PADDOCK_BIN_DIR moves the placed copy" $?
org3=$(exported XDG_DATA_HOME="$tmp/data")
[ "$org3" = "$tmp/data/paddock/bin/org" ]; check "XDG_DATA_HOME moves the exported path ($org3)" $?
(cd "$tmp" && clean PADDOCK_BIN_DIR=rel/bin bash "$start" >/dev/null 2>&1); rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$tmp/rel" ]; check "org-start refuses a relative PADDOCK_BIN_DIR (exit 2, $rc)" $?

# 5. Stand-in for the host check: report done through the placed copy reaches the secretary.
st=$tmp/state
[ -f "$org" ] && clean PADDOCK_STATE_DIR="$st" bash "$org" --as w-t1 report done --task t1 "finished" >/dev/null 2>&1
msgs=$(clean PADDOCK_STATE_DIR="$st" bash "$org" --as secretary check_messages --peek 2>&1)
grep -q 'w-t1' <<<"$msgs" && grep -q 'finished' <<<"$msgs"; check "report done through PADDOCK_ORG lands in the secretary's box" $?

exit $fail
