#!/usr/bin/env bash
# Issue #160, step 2: scripts/probes/own-file-allow-write.sh measures, with `claude -p`, whether a
# sandbox allowWrite entry that names ONE file is taken (a) with no entry for its folder and (b) with
# a denyWrite on the folder. This test checks the probe's safety rules statically, then runs the probe
# against a stub `claude` that mimics a sandbox (STUB_VARIANT: deny-wins | allow-wins)
# to check how the probe reads the files. No real Claude Code runs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
probe=$here/scripts/probes/own-file-allow-write.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
code() { grep -vE '^[[:space:]]*#' "$probe"; } # the probe without comment lines

[ -f "$probe" ]; check "scripts/probes/own-file-allow-write.sh exists" $?
[ -f "$probe" ] || { echo "(no probe: the rest is skipped)"; exit 1; }

# 1. Safety rules of the host probe.
sh -n "$probe"; check "the probe parses (sh -n)" $?
grep -q 'claude -p' "$probe" && grep -q -- '--settings "\$ROOT/templates/worker-settings.json"' "$probe"; check "claude -p runs with the shipped worker settings" $?
code | grep -q 'settings.local.json'; check "the per-task settings file (settings.local.json) is written" $?
code | grep -q 'allowWrite' && code | grep -q 'denyWrite'; check "the cases use allowWrite and denyWrite entries" $?
! code | grep -Eq '(^|[[:space:]])(export[[:space:]]+)?XDG_DATA_HOME='; check "the probe never sets XDG_DATA_HOME (Issue #212)" $?
grep -q '^\. .*claude-link\.sh' "$probe" && grep -q '^claude_link_save' "$probe" && grep -q 'claude_link_restore' "$probe"; check "the claude link is saved and restored from the exit trap" $?
grep -q 'trap .* EXIT' "$probe"; check "an exit trap cleans up" $?
code | grep -q 'mktemp -d "\$HOME/paddock-probe-160'; check "decoys live in a temp folder under HOME that the trap removes" $?
! code | grep -Eq -- '--dangerously-skip-permissions|bypassPermissions|allowUnsandboxedCommands|sudo |chmod |chown |unshare |bwrap '; check "nothing is crafted to get past a refusing layer" $?
grep -q 'Keep the sandbox ON' "$probe" && grep -q 'do not retry' "$probe"; check "the worker is told to keep the sandbox on and not to retry another way" $?
! code | grep -Eq 'local/state/paddock|PADDOCK_STATE_DIR|scripts/org|org-delegate|hc |\.claude\.json'; check "no real org state, org script, hc or Claude config is touched" $?
! code | grep -Eq '^[[:space:]]*cd[[:space:]]+(/|~|\$HOME)[^"]*$'; check "no cd to a fixed folder" $?
! grep -qE 'PROJ=\$\{1|NEEDS-PERSON' "$probe"; check "the probe takes no argument and never waits for a person" $?
grep -q 'RESULT precondition-failed' "$probe" && grep -q '\$# -eq 0' "$probe"; check "an argument is refused" $?

# 2. The probe against a stub claude that mimics the sandbox.
# The stub reads OWN= SIBLING= NEW= from the prompt and allowWrite / denyWrite from
# ./.claude/settings.local.json, and writes a marker to each path the way the sandbox would.
stub=$tmp/stub; mkdir -p "$stub" "$tmp/home/.local/bin"
cat > "$stub/claude" <<'EOF'
#!/bin/sh
for a in "$@"; do last=$a; done
get() { printf '%s\n' "$last" | sed -n "s/^$1=//p" | head -n 1; }
[ "$1" = --version ] && { echo stub-claude; exit 0; }
own=$(get OWN); sib=$(get SIBLING); new=$(get NEW)
sl=$(tr -d '\n\t ' < .claude/settings.local.json)
list() { printf '%s' "$sl" | sed -n "s/.*\"$1\":\[\([^]]*\)\].*/\1/p" | tr -d '"' | tr ',' '\n'; }
under() { # path entry
  [ "$1" = "$2" ] && return 0; case "$1" in "$2"/*) return 0 ;; esac; return 1
}
anyunder() { # path, list name
  for e in $(list "$2"); do under "$1" "$e" && return 0; done; return 1
}
ok() { # path
  if [ "${STUB_VARIANT:-deny-wins}" = allow-wins ]; then anyunder "$1" allowWrite && return 0; anyunder "$1" denyWrite && return 1; return 1; fi
  anyunder "$1" denyWrite && return 1
  anyunder "$1" allowWrite
}
if [ "${STUB_VARIANT:-}" = no-file-entry ] && [ -n "$own" ]; then :; fi
out=
for pair in "A:$own" "C:$sib" "D:$new"; do
  n=${pair%%:*}; p=${pair#*:}
  if ok "$p" 2>/dev/null; then printf '%s\n' "$(printf '%s\n' "$last" | awk -v s="$n." '$1==s{print $4}')" >> "$p" 2>/dev/null; out="$out$n ran=yes rc=0 err=none\n"
  else out="$out$n ran=yes rc=1 err=(eval):1: read-only file system: $p\n"; fi
done
printf '{"type":"result","result":"%s"}\n' "$out"
EOF
chmod +x "$stub/claude"
run() { (cd "$here" && env HOME="$tmp/home" PATH="$stub:/usr/bin:/bin" STUB_VARIANT="$1" sh scripts/probes/own-file-allow-write.sh 2>&1); }
has() { printf '%s\n' "$1" | grep -q "^RESULT $2"; }

out=$(run deny-wins)
has "$out" "control: PASS"; check "stub: folder allowed -> control PASS" $?
has "$out" "file-entry: HOLDS"; check "stub: file entry alone -> HOLDS (sibling and new file refused)" $?
has "$out" "deny-parent: DENY WINS"; check "stub: parent denyWrite beats the file entry -> DENY WINS" $?
ls "$tmp/home" | grep -q '^paddock-probe-160'; [ $? -ne 0 ]; check "the probe's temp folder is removed" $?
out=$(run allow-wins)
has "$out" "deny-parent: ALLOW WINS"; check "stub: file entry beats the parent denyWrite -> ALLOW WINS" $?
[ "$fail" -eq 0 ]
