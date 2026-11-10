#!/usr/bin/env bash
# Acceptance test for Issue #155 (L-N2 holders). Needs bash, coreutils, git and node; hc and
# claude are stubs, so no core runs.
# 1. Every worker template command removes the core's variables before Claude Code starts.
# 2. The per-task settings file org-delegate writes denies sandbox reads and writes on the
#    core's socket folder, and org-delegate stops before creating anything when it cannot
#    tell where that folder is.
# 3. The L-N2 probe checks every core variable seen in a worker's environment.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
delegate=$here/skills/org-delegate/scripts/org-delegate.sh
probe=$here/scripts/probes/core-api-reach.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
# Every core variable seen in a worker's environment (inventory row L-N2) plus HC_SOCKET.
CORE_VARS="HC_SESSION HC_SOCKET HC_SCOPE HC_TERMINAL_ID HC_TERMINAL_SOCKET"
cmdline() { sed -n '2,${/^---[[:space:]]*$/q;p;}' "$1" | grep -m1 '^command:' | sed 's/^command:[[:space:]]*//'; }

# 1. Worker templates (not the *-rules.md file, which has no header).
n=0
for tpl in "$here"/templates/worker*.md; do
  case "$tpl" in *-rules.md) continue ;; esac
  n=$((n + 1)); cmd=$(cmdline "$tpl"); t=${tpl##*/}
  for v in $CORE_VARS; do
    grep -q -- "-u $v " <<<"$cmd"; check "$t: the env -u list removes $v" $?
  done
done
[ "$n" -gt 0 ]; check "at least one worker template was checked" $?

# The worker template's command, run through sh as the core would, with every core variable set.
cmd=$(cmdline "$here/templates/worker.md")
stub=$tmp/bin; mkdir -p "$stub" "$tmp/cfg/paddock"
cat > "$stub/claude" <<'EOF'
#!/bin/sh
{ env | sed -n 's/^\(HC_[A-Za-z0-9_]*\)=.*/NAME:\1/p'
  echo "PADDOCK_ORG=${PADDOCK_ORG-unset}"; echo "GH_TOKEN=${GH_TOKEN-unset}"; } > "$CLAUDE_OUT"
EOF
chmod +x "$stub/claude"
printf 'tok\n' > "$tmp/cfg/paddock/worker-gh-token"
env -u APPDATA -u PADDOCK_WORKER_GH_TOKEN_FILE -u PADDOCK_BIN_DIR XDG_CONFIG_HOME="$tmp/cfg" \
  XDG_DATA_HOME="$tmp/data" PATH="$stub:$PATH" CLAUDE_OUT="$tmp/out" \
  HC_SESSION=s HC_SOCKET=/x/s.sock HC_SCOPE=scope HC_TERMINAL_ID=t9 HC_TERMINAL_SOCKET=/x/s.sock HC_OTHER=1 \
  sh -c "$cmd" >/dev/null 2>&1
[ -f "$tmp/out" ]; check "the worker command starts claude" $?
for v in $CORE_VARS; do
  ! grep -qx "NAME:$v" "$tmp/out" 2>/dev/null; check "claude does not get $v" $?
done
grep -qx "PADDOCK_ORG=$tmp/data/paddock/bin/org" "$tmp/out" 2>/dev/null && grep -qx 'GH_TOKEN=tok' "$tmp/out"
check "the report path is intact: PADDOCK_ORG and the read-only GH_TOKEN still reach claude" $?

# 2. org-delegate with a stub hc.
cat > "$stub/hc" <<'EOF'
#!/bin/sh
echo "$*" >> "$STUB/calls"
case "$1" in
  ls) echo '[]' ;;
  get) exit 1 ;;
  file) path=; for a in "$@"; do path=$a; done; mkdir -p "$(dirname "$path")" && cat > "$path" ;;
  run) echo '{"first_message":{"sent":true,"started":true,"turn":0}}' ;;
esac
exit 0
EOF
chmod +x "$stub/hc"
proj=$tmp/project
git init -q -b main "$proj" 2>/dev/null || { git init -q "$proj"; git -C "$proj" checkout -q -b main; }
git -C "$proj" -c user.name=t -c user.email=t@t.invalid commit -q --allow-empty -m init
k=0
deleg() { # deleg <env...> -- <extra args...>: one delegation of a fresh task id; sets $wt, $rc, $out
  local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  k=$((k + 1)); wt=$tmp/workers/t$k; mkdir -p "$tmp/stub"; : > "$tmp/stub/calls"
  out=$(env -u PADDOCK_ORG_ID -u PADDOCK_CORE_SOCKET_DIR -u HC_TERMINAL_SOCKET STUB="$tmp/stub" \
    PATH="$stub:$PATH" PADDOCK_WORKERS_DIR="$tmp/workers" PADDOCK_STATE_DIR="$tmp/state" "${envs[@]}" \
    bash "$delegate" --project "$proj" --task-id "t$k" --task "x" "$@" 2>&1); rc=$?
}
js() { node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const f=(s.sandbox||{}).filesystem||{};'"$1" "$wt/.claude/settings.local.json" "${@:2}" 2>/dev/null; }
D=$tmp/run/herdr-core
deleg HC_TERMINAL_SOCKET="$D/default.sock" --
[ "$rc" -eq 0 ]; check "delegation from a core terminal exits 0 ($out)" $?
js 'process.exit(JSON.stringify(f.denyRead)===JSON.stringify([process.argv[2]])?0:1)' "$D"
check "settings.local.json: sandbox denyRead is the folder of HC_TERMINAL_SOCKET" $?
js 'process.exit(JSON.stringify(f.denyWrite)===JSON.stringify([process.argv[2]])?0:1)' "$D"
check "settings.local.json: sandbox denyWrite is the folder of HC_TERMINAL_SOCKET" $?
deleg HC_TERMINAL_SOCKET="$D/default.sock" -- --allow-write "$tmp/extra"
js 'process.exit(JSON.stringify(f.allowWrite)===JSON.stringify([process.argv[2]])&&JSON.stringify(f.denyRead)===JSON.stringify([process.argv[3]])?0:1)' "$tmp/extra" "$D"
check "with --allow-write: allowWrite kept, socket folder still denied" $?
deleg HC_TERMINAL_SOCKET="$D/default.sock" PADDOCK_CORE_SOCKET_DIR="$tmp/other" --
[ "$rc" -eq 0 ] && js 'process.exit(JSON.stringify(f.denyRead)===JSON.stringify([process.argv[2]])&&JSON.stringify(f.denyWrite)===JSON.stringify([process.argv[2]])?0:1)' "$tmp/other"
check "PADDOCK_CORE_SOCKET_DIR overrides the folder" $?
for bad in "" "HC_TERMINAL_SOCKET=rel/s.sock" "PADDOCK_CORE_SOCKET_DIR=rel" "PADDOCK_CORE_SOCKET_DIR=/a\"b" \
           "PADDOCK_CORE_SOCKET_DIR=/a\\b" "PADDOCK_CORE_SOCKET_DIR=/a$(printf '\t')b"; do
  # shellcheck disable=SC2086
  if [ -n "$bad" ]; then deleg "$bad" --; else deleg --; fi
  [ "$rc" -eq 2 ] && [ ! -e "$wt" ] && ! grep -Eq '^(run|file) ' "$tmp/stub/calls" && grep -q 'socket' <<<"$out"
  check "no usable socket folder (${bad:-none given}): exit 2, nothing created, the message says socket" $?
done

# 3. The probe checks each core variable (names only).
[ -f "$probe" ]; check "the L-N2 probe exists" $?
for v in $CORE_VARS; do
  grep -q "$v" "$probe" 2>/dev/null; check "the probe's environment check names $v" $?
done
grep -q 'PADDOCK_CORE_SOCKET_DIR\|HC_TERMINAL_SOCKET' "$probe" 2>/dev/null && grep -q 'settings.local.json' "$probe"
check "the probe reads the socket folder entry from the worktree's settings.local.json" $?
exit $fail
