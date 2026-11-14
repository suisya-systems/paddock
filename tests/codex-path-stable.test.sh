#!/usr/bin/env bash
# Issue #364: the codex the review gate runs must be the one prepare checks, and the recorded codex-path
# must outlive the shell that made it. org-start resolves the folder fnm's per-shell link points at
# (a /fnm_multishells/ path is temporary), refuses a real temporary folder, warns when two installs
# are on PATH; the gate prefers codex-path over PATH and says which version it ran; prepare's
# codex-cli check uses the gate's lookup order. Stubs only; no core runs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

mkdir -p "$tmp/bin" "$tmp/home/.local/bin" "$tmp/stub" "$tmp/core"
cat > "$tmp/bin/hc" <<'EOF2'
#!/bin/sh
case "$1" in
  get) [ -f "$STUB/secretary" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       echo '{"name":"secretary","state":"live","status":{"app":"claude-code","state":"idle"}}' ;;
  run) : > "$STUB/secretary"; echo '{"name":"secretary"}' ;;
  *) echo ok ;;
esac
exit 0
EOF2
chmod +x "$tmp/bin/hc"
printf '#!/bin/sh\nexit 0\n' > "$tmp/home/.local/bin/claude"; chmod +x "$tmp/home/.local/bin/claude"
printf 'notes = false\n' > "$tmp/core/config.toml"
mkcodex() { # mkcodex <folder> <version>: a stub codex that logs its folder and prints its version
  mkdir -p "$1"
  printf '#!/bin/sh\ncase "$1" in --version) echo "codex-cli %s"; exit 0;; esac\necho "%s $*" >> "$STUB_LOG"\necho " succeeded in 12ms:"; exit 0\n' "$2" "$1" > "$1/codex"
  chmod +x "$1/codex"
}
start() { # start <PATH for org-start>
  rm -rf "$tmp/stub/secretary"
  env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u APPDATA \
      STUB="$tmp/stub" PATH="$1" HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/xdg" \
      PADDOCK_CORE_CONFIG_DIR="$tmp/core" PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" \
      PADDOCK_APP_MODS_DIR="$tmp/app/mods" PADDOCK_APP_LAYOUTS_DIR="$tmp/app/layouts" \
      PADDOCK_BIN_DIR="$tmp/bin-org" PADDOCK_READY_TRIES=2 bash "$here/skills/org-start/scripts/org-start.sh" 2>&1
}
base="/usr/bin:/bin"
rec() { cat "$tmp/bin-org/codex-path" 2>/dev/null; }

# --- org-start: a per-shell fnm folder is a link; record the folder it points at ---
mkcodex "$tmp/fnm/node-versions/v24/installation/bin" 0.163.0
mkdir -p "$tmp/fnm_multishells"
ln -s "$tmp/fnm/node-versions/v24/installation" "$tmp/fnm_multishells/1_2"
out=$(start "$tmp/fnm_multishells/1_2/bin:$tmp/home/.local/bin:$tmp/bin:$base"); rc=$?
[ "$rc" -eq 0 ] && [ "$(rec)" = "$tmp/fnm/node-versions/v24/installation/bin/codex" ]
check "a codex under fnm's per-shell link is recorded by its stable folder" $?

# --- a temporary folder that is not a link cannot be resolved: refuse it and say so ---
rm -f "$tmp/bin-org/codex-path"
mkcodex "$tmp/fnm_multishells/3_4/bin" 0.163.0
out=$(start "$tmp/fnm_multishells/3_4/bin:$tmp/home/.local/bin:$tmp/bin:$base"); rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$tmp/bin-org/codex-path" ] && grep -q 'fnm_multishells' <<<"$out"
check "a codex that stays under fnm_multishells is not recorded, and org-start says why" $?

# --- two installs: record the first on PATH, warn with both versions and the fix ---
rm -f "$tmp/bin-org/codex-path"
mkcodex "$tmp/nvm/bin" 0.157.0
out=$(start "$tmp/nvm/bin:$tmp/fnm_multishells/1_2/bin:$tmp/home/.local/bin:$tmp/bin:$base"); rc=$?
[ "$rc" -eq 0 ] && [ "$(rec)" = "$tmp/nvm/bin/codex" ]; check "two installs: the first on PATH is recorded" $?
grep -q '0.157.0' <<<"$out" && grep -q '0.163.0' <<<"$out" && grep -qi 'PATH' <<<"$out" && grep -q "$tmp/nvm/bin" <<<"$out"
check "two installs: the warning names both versions, the chosen one and the fix" $?
rm -f "$tmp/bin-org/codex-path"
out=$(start "$tmp/nvm/bin:$tmp/home/.local/bin:$tmp/bin:$base")
! grep -qi 'several codex\|more than one codex' <<<"$out"; check "one install: no warning" $?

# --- the gate: codex-path first, then PATH; it reports the version it ran ---
repo=$tmp/repo; mkdir -p "$repo"
(
  cd "$repo" && git init -q -b main . \
    && git config user.email t@example.com && git config user.name t \
    && echo one > a.txt && git add a.txt && git commit -q -m one \
    && git update-ref refs/remotes/origin/main HEAD \
    && echo two >> a.txt && git commit -q -am two
) >/dev/null 2>&1
export STUB_LOG=$tmp/calls
gatedir=$tmp/gatedir; mkdir -p "$gatedir"; cp "$here/scripts/second-model-review.sh" "$gatedir/"
printf '%s\n' "$tmp/nvm/bin/codex" > "$gatedir/codex-path"
mkcodex "$tmp/other/bin" 0.200.0
: > "$STUB_LOG"
out=$(cd "$repo" && TMPDIR="$tmp" PATH="$tmp/other/bin:/usr/bin:/bin" bash "$gatedir/second-model-review.sh" 2>&1 </dev/null); rc=$?
last=$(printf '%s\n' "$out" | tail -n 1)
[ "$rc" -eq 0 ] && grep -q "^$tmp/nvm/bin " "$STUB_LOG" && ! grep -q "^$tmp/other/bin " "$STUB_LOG"
check "the gate runs codex-path even when another codex is on PATH" $?
grep -q '0.157.0' <<<"$last" && grep -q "$tmp/nvm/bin/codex" <<<"$last"; check "the gate's last line records the version and path it used" $?
grep -q 'codex-cli 0.157.0' <<<"$out"; check "the gate prints the version before the review" $?

# --- prepare's codex-cli check looks codex up in the gate's order ---
S=$here/scripts/probes/prototype-3.sh
fn=$(sed -n '/^# BEGIN codex-lookup/,/^# END codex-lookup/p' "$S")
[ -n "$fn" ]; check "prepare has the codex lookup block" $?
lookup() { # lookup <PATH>: prints "<path> <source>" or nothing
  PADDOCK_BIN_DIR="$tmp/bin-prep" PATH="$1" sh -c "$fn"'
    if codex_gate_lookup; then echo "$CODEX_BIN $CODEX_SRC"; fi'
}
mkdir -p "$tmp/bin-prep"; rm -f "$tmp/bin-prep/codex-path"
[ "$(lookup "$tmp/other/bin:/usr/bin:/bin")" = "$tmp/other/bin/codex PATH" ]; check "prepare: no codex-path, PATH codex" $?
printf '%s\n' "$tmp/nvm/bin/codex" > "$tmp/bin-prep/codex-path"
[ "$(lookup "$tmp/other/bin:/usr/bin:/bin")" = "$tmp/nvm/bin/codex codex-path" ]; check "prepare: codex-path wins over PATH, like the gate" $?
printf '%s\n' "$tmp/gone/codex" > "$tmp/bin-prep/codex-path"
[ "$(lookup "$tmp/other/bin:/usr/bin:/bin")" = "$tmp/other/bin/codex PATH" ]; check "prepare: a stale codex-path falls back to PATH, like the gate" $?
[ -z "$(lookup /usr/bin:/bin)" ]; check "prepare: nothing found" $?
exit "$fail"
