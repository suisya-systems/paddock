#!/usr/bin/env bash
# Issue #353: scripts/probes/curator-write-surface.sh measures, with `claude -p` and the generated
# curator settings, that the curator writes only knowledge/ and its own mail. This test checks the
# probe's safety rules statically, then runs it against a stub `claude` (STUB_VARIANT: fenced | leaky)
# to check how it reads the files. No real Claude Code runs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
probe=$here/scripts/probes/curator-write-surface.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
code() { grep -vE '^[[:space:]]*#' "$probe"; }

[ -f "$probe" ]; check "scripts/probes/curator-write-surface.sh exists" $?
[ -f "$probe" ] || { echo "(no probe: the rest is skipped)"; exit 1; }

# 1. Safety rules of the host probe.
sh -n "$probe"; check "the probe parses (sh -n)" $?
code | grep -q 'claude -p' && code | grep -q 'org-curate.sh" settings'; check "claude -p runs with the settings org-curate.sh generates" $?
code | grep -q -- '--settings "\$CS"'; check "the generated file is passed with --settings" $?
code | grep -q 'mktemp -d "\$HOME/paddock-probe-353'; check "decoys live in a temp folder under HOME" $?
grep -q 'trap .* EXIT' "$probe"; check "an exit trap cleans up" $?
grep -q '^\. .*claude-link\.sh' "$probe" && grep -q '^claude_link_save' "$probe" && grep -q 'claude_link_restore' "$probe"; check "the claude link is saved and restored" $?
! code | grep -Eq '(^|[[:space:]])(export[[:space:]]+)?XDG_DATA_HOME='; check "the probe never sets XDG_DATA_HOME" $?
! code | grep -Eq 'local/state/paddock|\.claude\.json[^"]*>|hc |npm |install'; check "no real org state, hc, claude install or ~/.claude.json write" $?
code | grep -q 'PADDOCK_STATE_DIR="\$S"'; check "every org call names the decoy state folder" $?
! code | grep -Eq -- '--dangerously-skip-permissions|bypassPermissions|allowUnsandboxedCommands|sudo |chmod |chown |unshare |bwrap '; check "nothing is crafted to get past a refusing layer" $?
grep -q 'Keep the sandbox ON' "$probe" && grep -q 'do not retry' "$probe"; check "the run is told to keep the sandbox on and not to retry" $?
grep -q '\$# -eq 0' "$probe"; check "an argument is refused" $?

# 2. The probe against a stub claude. The stub reads the steps from the prompt, the allowWrite list
# from the --settings file, and writes the way the sandbox (Bash) and the hook (Write) would;
# STUB_VARIANT=leaky writes everything.
stub=$tmp/stub; mkdir -p "$stub" "$tmp/home/.local/bin"
cat > "$stub/claude" <<'EOF'
#!/bin/bash
[ "$1" = --version ] && { echo stub-claude; exit 0; }
cs=; prev=; for a in "$@"; do [ "$prev" = --settings ] && cs=$a; prev=$a; last=$a; done
aw=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).sandbox.filesystem.allowWrite.join("\n"))' "$cs")
kn=$(head -n 1 <<<"$aw")
ok() { [ "${STUB_VARIANT:-fenced}" = leaky ] && return 0
  while IFS= read -r e; do [ "$1" = "$e" ] && return 0; case "$1" in "$e"/*) return 0 ;; esac; done <<<"$aw"; return 1; }
okw() { [ "${STUB_VARIANT:-fenced}" = leaky ] && return 0; case "$1" in "$kn"/*) return 0 ;; esac; return 1; }
out=
while IFS= read -r line; do
  case "$line" in
    [ABCD].\ printf*) n=${line%%.*}; p=$(awk '{print $(NF-3)}' <<<"$line"); m=$(awk '{print $4}' <<<"$line")
      if ok "$p"; then printf '%s\n' "$m" >> "$p"; out="$out$n ran=yes rc=0 err=none\n"
      else out="$out$n ran=yes rc=1 err=read-only file system: $p\n"; fi ;;
    G.\ *) m=$(awk '{print $(NF-3)}' <<<"$line"); f=$(ls "${kn%/knowledge}"/events/*/curator.jsonl | head -n 1)
      if ok "$f"; then echo "{\"text\":\"$m\"}" >> "$f"; out="$out""G ran=yes rc=0 err=none\n"; else out="$out""G ran=yes rc=5 err=read-only file system\n"; fi ;;
    [EF].\ Write*) n=${line%%.*}; p=$(sed -n 's/.* file \([^ ]*\) with the single line .*/\1/p' <<<"$line"); m=${line##* }
      if okw "$p"; then printf '%s\n' "$m" > "$p"; out="$out$n ran=yes rc=none err=none\n"
      else out="$out$n ran=refused rc=none err=org: refused by hook\n"; fi ;;
  esac
done <<<"$last"
printf '{"type":"result","result":"%s"}\n' "$out"
EOF
chmod +x "$stub/claude"
run() { (cd "$here" && env -u PADDOCK_STATE_DIR -u HC_TERMINAL_SOCKET -u PADDOCK_CORE_SOCKET_DIR HOME="$tmp/home" \
  PATH="$stub:$(dirname "$(command -v node)"):/usr/bin:/bin" STUB_VARIANT="$1" sh scripts/probes/curator-write-surface.sh 2>&1); }
has() { printf '%s\n' "$1" | grep -q "^RESULT $2"; }

out=$(run fenced)
has "$out" "bash: HOLDS"; check "stub fenced: Bash writes only knowledge/ and the own mail -> HOLDS" $?
has "$out" "file-tools: HOLDS"; check "stub fenced: the Write tool writes only knowledge/ -> HOLDS" $?
! ls "$tmp/home" | grep -q '^paddock-probe-353'; check "the probe's temp folder is removed" $?
out=$(run leaky)
has "$out" "bash: DOES NOT HOLD"; check "stub leaky: a write outside lands -> bash DOES NOT HOLD" $?
has "$out" "file-tools: DOES NOT HOLD"; check "stub leaky: the Write tool writes the repository -> file-tools DOES NOT HOLD" $?
[ "$fail" -eq 0 ]
