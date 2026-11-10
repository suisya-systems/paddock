#!/usr/bin/env bash
# Checks how scripts/probes/sandbox-unavailable.sh (Issue #164) reads its runs, with a stub
# `claude` and a stub `bwrap`; no real Claude Code runs. The stub mimics the documented
# behaviour: bwrap on PATH -> sandboxed (only the working-folder write lands); no bwrap and
# failIfUnavailable in the settings -> exits 1 naming bubblewrap; no bwrap without it -> runs
# unsandboxed (both writes land). STUB_VARIANT changes the no-bwrap + failIfUnavailable case.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
stub=$tmp/stub; mkdir -p "$stub"
printf '#!/bin/sh\nexit 0\n' > "$stub/bwrap"
cat > "$stub/claude" <<'EOF'
#!/bin/sh
set=; for a in "$@"; do [ "$prev" = --settings ] && set=$a; prev=$a; last=$a; done
paths=$(printf '%s\n' "$last" | sed -n 's/.*touch \([^ ]*\) \([^ ]*\)$/\1 \2/p')
in=${paths% *}; out=${paths#* }
if command -v bwrap >/dev/null 2>&1; then touch "$in"; echo '{"type":"result"}'; exit 0; fi
if grep -q failIfUnavailable "$set"; then
  case "${STUB_VARIANT:-good}" in
    good) echo "Error: sandbox required (sandbox.failIfUnavailable) but bubblewrap (bwrap) is not installed" >&2; exit 1 ;;
    leak) touch "$in" "$out"; exit 0 ;;
    timeout) exit 124 ;;
    silent) exit 1 ;;
  esac
fi
touch "$in" "$out"; exit 0
EOF
chmod +x "$stub/claude" "$stub/bwrap"
# A short PATH: the probe links every program on PATH, and a long one (WSL adds Windows folders) is slow.
probe() { (cd "$here" && env -u CLAUDE_CONFIG_DIR HOME="$tmp" PATH="$stub:/usr/bin:/bin" STUB_VARIANT="$1" \
  sh scripts/probes/sandbox-unavailable.sh 2>&1); }
has() { grep -q "^RESULT $2" <<<"$1"; }

out=$(probe good)
has "$out" "control: PASS"; check "control run sandboxed -> PASS" $?
has "$out" "fail-closed: PASS"; check "refusal naming bubblewrap, nothing written -> fail-closed PASS" $?
has "$out" "default: INFO ran unsandboxed"; check "without the setting the stub falls back -> default INFO unsandboxed" $?
has "$out" "retry: NOT MEASURED"; check "retry is reported as not measured" $?
ls "$tmp" | grep -q paddock-probe-164; [ $? -ne 0 ]; check "the probe folder is removed" $?
out=$(probe leak); has "$out" "fail-closed: FAIL"; check "both writes land -> fail-closed FAIL" $?
out=$(probe timeout); has "$out" "fail-closed: INCONCLUSIVE"; check "exit 124 -> fail-closed INCONCLUSIVE" $?
out=$(probe silent); has "$out" "fail-closed: INCONCLUSIVE"; check "refusal that does not name the sandbox -> INCONCLUSIVE" $?
[ "$fail" -eq 0 ]
