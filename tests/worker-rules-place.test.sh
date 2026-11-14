#!/usr/bin/env bash
# Acceptance test for Issue #129: the worker's rules and settings files are not in the
# herdr-core templates folder (hc lists every *.md there as a template). With default
# folders on both sides, the paths the worker template passes to claude are the files
# org-start placed; the worker settings let a worker read them and not write them.
# Needs bash, coreutils and node (JSON.parse). hc and claude are stubs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tpl=$here/templates/worker.md
settings=$here/templates/worker-settings.json
start=$here/skills/org-start/scripts/org-start.sh
tmp=$(mktemp -d)
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
cmd=$(sed -n '2,${/^---[[:space:]]*$/q;p;}' "$tpl" | grep -m1 '^command:' | sed 's/^command:[[:space:]]*//;s/[[:space:]]*$//')

bin=$tmp/bin; mkdir -p "$bin" "$tmp/stub"
cat > "$bin/claude" <<'EOF2'
#!/bin/sh
for a in "$@"; do echo "$a"; done > "$CLAUDE_OUT"
EOF2
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
mkdir -p "$home/.config/herdr-core"; printf 'notes = false\n' > "$home/.config/herdr-core/config.toml"
clean() { # clean <cmd...>: scratch HOME, none of the folder overrides, no agent variables
  env -u APPDATA -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
      -u PADDOCK_CORE_TEMPLATES_DIR -u PADDOCK_APP_MODS_DIR -u PADDOCK_BIN_DIR \
      -u PADDOCK_STATE_DIR \
      -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
      HOME="$home" PATH="$bin:$PATH" STUB="$tmp/stub" PADDOCK_READY_TRIES=1 "$@"
}
arg_after() { grep -A1 -x -- "$1" "$tmp/args" | sed -n 2p; } # arg_after <flag>: the value claude got

# 1. org-start with default folders; the core templates folder holds only real templates.
clean bash "$start" >/dev/null 2>&1; check "org-start exits 0 with default folders" $?
td=$home/.config/herdr-core/templates
[ -f "$td/worker.md" ]; check "the worker template is in the core templates folder" $?
bad=; for f in "$td"/*; do case "$f" in *.md) [ "$(head -n 1 "$f")" = "---" ] || bad="$bad ${f##*/}" ;; *) bad="$bad ${f##*/}" ;; esac; done
[ -z "$bad" ]; check "the core templates folder holds only templates (hc templates lists no broken entry)${bad:+ (not templates:$bad)}" $?

# 2. The worker template's launch names the files org-start placed.
rm -f "$tmp/args"; clean CLAUDE_OUT="$tmp/args" sh -c "$cmd" >/dev/null 2>&1
rules=$(arg_after --append-system-prompt-file); sets=$(arg_after --settings)
[ -n "$rules" ] && cmp -s "$here/templates/worker-rules.md" "$rules"; check "--append-system-prompt-file names the placed rules file ($rules)" $?
[ -n "$sets" ] && cmp -s "$settings" "$sets"; check "--settings names the placed settings file ($sets)" $?
case "$rules$sets" in *herdr-core*) false ;; *) true ;; esac; check "neither path is under herdr-core" $?

# 3. The worker settings: readable, not writable.
prefixes() { # prefixes <js expression giving an array>: one expanded path per line, /** stripped
  node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const a='"$1"';for(const x of a||[])console.log(x)' "$settings" \
    | sed "s|^~|$home|; s|/\*\*\$||; s|/\$||"
}
under() { case "$1" in "$2"|"$2"/*) return 0 ;; esac; return 1; }
covered() { # covered <path> <js expression>: 0 if any prefix covers path
  local p; while IFS= read -r p; do [ -n "$p" ] && under "$1" "$p" && return 0; done < <(prefixes "$2"); return 1
}
for f in "$rules" "$sets"; do
  n=${f##*/}
  [ -n "$f" ] && ! covered "$f" 's.permissions.deny.filter(r=>/^Read\(/.test(r)).map(r=>r.slice(5,-1))' \
    && ! covered "$f" 's.sandbox.filesystem.denyRead'; check "$n is not under a read deny" $?
  [ -n "$f" ] && covered "$f" 's.permissions.deny.filter(r=>/^Edit\(/.test(r)).map(r=>r.slice(5,-1))'; check "$n is under an Edit deny" $?
  [ -n "$f" ] && covered "$f" 's.sandbox.filesystem.denyWrite'; check "$n is under sandbox denyWrite" $?
  [ -n "$f" ] && ! covered "$f" 's.sandbox.filesystem.allowWrite'; check "$n is not under sandbox allowWrite" $?
done

exit $fail
