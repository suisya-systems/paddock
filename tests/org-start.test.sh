#!/usr/bin/env bash
# Acceptance test for skills/org-start/scripts/org-start.sh. Needs only bash and
# coreutils: hc and herdr-app are replaced by stubs on PATH, so no core runs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-start/scripts/org-start.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

[ -f "$script" ]; check "script exists" $?
[ -f "$here/skills/org-start/SKILL.md" ]; check "SKILL.md exists" $?
bash -n "$script" 2>/dev/null; check "script parses" $?

# Stub hc. State lives in $STUB: a file "secretary" exists once `run` ran.
# Every call is appended to $STUB/calls. STUB_CORE_DOWN=1 makes `ls` fail.
stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/calls"
case "$1" in
  ls) [ -z "${STUB_CORE_DOWN:-}" ] || { echo '{"error":{"kind":"unavailable"}}'; exit 1; }
      echo "ok"; exit 0 ;;
  get) case " $* " in *" watcher "*) [ -f "$STUB/watcher" ] && { echo "{\"name\":\"watcher\",\"state\":\"live\"}"; exit 0; }; echo "{\"error\":{\"kind\":\"not_found\"}}"; exit 1 ;; esac
       [ -f "$STUB/secretary" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       if [ -f "$STUB/finished" ]; then echo '{"name":"secretary","state":"finished","reason":"killed","status":null}'; exit 0; fi
       echo '{"name":"secretary","state":"live","status":{"app":"claude-code","state":"idle"}}'; exit 0 ;;
  rm) rm -f "$STUB/secretary" "$STUB/finished"; echo '{"removed":true}'; exit 0 ;;
  run) case " $* " in *" --name watcher "*) : > "$STUB/watcher"; echo "{\"name\":\"watcher\"}"; exit 0 ;; esac; : > "$STUB/secretary"; echo '{"name":"secretary"}'; exit 0 ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"
printf '#!/bin/sh\n' > "$stubdir/claude"; chmod +x "$stubdir/claude" # Issue #268: org-start needs claude on PATH

run() { # run <extra env...> -- ; uses fresh dirs under $tmp/w unless reused
  env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
      STUB="$tmp/stub" PATH="$stubdir:$PATH" \
      PADDOCK_CORE_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/core-notes-off" PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates" \
      PADDOCK_APP_MODS_DIR="$tmp/app/mods" PADDOCK_APP_LAYOUTS_DIR="$tmp/app/layouts" PADDOCK_BIN_DIR="$tmp/bin-org" \
      PADDOCK_READY_TRIES=2 "$@" bash "$script" 2>&1
}
mkdir -p "$tmp/stub"

# Argument handling.
out=$(bash "$script" --help 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -qi 'usage' <<<"$out"; check "--help exits 0 with usage" $?
bash "$script" --no-such-flag >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; check "unknown argument exits 2" $?

# Refusal: hc missing.
out=$(env PATH="$tmp/empty" "$(command -v bash)" "$script" 2>&1); rc=$?
[ "$rc" -eq 3 ]; check "no hc on PATH exits 3" $?

# Refusal: running inside an agent. hc must not be called at all.
: > "$tmp/stub/calls"
out=$(run CLAUDE_CODE_CHILD_SESSION=1); rc=$?
[ "$rc" -eq 4 ] && [ ! -s "$tmp/stub/calls" ]; check "agent environment exits 4 without calling hc" $?
out=$(run CLAUDECODE=1); rc=$?
[ "$rc" -eq 4 ]; check "CLAUDECODE alone also refuses" $?

# Refusal: core unreachable. Nothing is started.
: > "$tmp/stub/calls"
out=$(run STUB_CORE_DOWN=1); rc=$?
[ "$rc" -eq 5 ] && ! grep -q '^run' "$tmp/stub/calls"; check "core unreachable exits 5, starts nothing" $?

# First run.
: > "$tmp/stub/calls"
out=$(run); rc=$?
[ "$rc" -eq 0 ]; check "first run exits 0 ($out)" $?
[ "$(grep -c "^run .* secretary" "$tmp/stub/calls")" -eq 1 ] \
  && grep -qx "run --bg --keep --name secretary --cwd $here secretary" "$tmp/stub/calls"; check "starts the secretary once with --keep" $?
[ "$(grep -c '^run .*--name watcher' "$tmp/stub/calls")" -eq 1 ] \
  && grep -qx "run --bg --keep --no-notify --name watcher --label paddock_role=watcher --cwd $here -- bash $here/skills/org-watch/scripts/org-watch.sh" "$tmp/stub/calls"; check "starts the watcher once, kept, with the role label" $?
cmp -s "$here/templates/secretary.md" "$tmp/core/templates/secretary.md"; check "template placed in core templates folder" $?
cmp -s "$here/mods/org-agents/main.js" "$tmp/app/mods/org-agents/main.js" \
  && cmp -s "$here/mods/org-agents/mod.json" "$tmp/app/mods/org-agents/mod.json"; check "mod files placed" $?
cmp -s "$here/scripts/org" "$tmp/bin-org/org" && [ ! -e "$tmp/core/templates/org" ]; check "scripts/org placed in the bin folder, not the templates folder (as PADDOCK_ORG, Issue #128)" $?
! grep -Eq '^server (stop|restart)' "$tmp/stub/calls"; check "never stops or restarts the core" $?
# Issue #129: the worker's rules and settings go beside the org script, not into the templates folder
# (hc lists every *.md there as a template).
cmp -s "$here/templates/worker-rules.md" "$tmp/bin-org/worker-rules.md" \
  && cmp -s "$here/templates/worker-settings.json" "$tmp/bin-org/worker-settings.json"; check "worker-rules.md and worker-settings.json placed in the bin folder (Issue #129)" $?
[ ! -e "$tmp/core/templates/worker-rules.md" ] && [ ! -e "$tmp/core/templates/worker-settings.json" ]; check "no rules or settings file in the templates folder" $?
bad=; for f in "$tmp/core/templates"/*.md; do [ "$(head -n 1 "$f")" = "---" ] || bad="$bad ${f##*/}"; done
[ -z "$bad" ]; check "every *.md in the templates folder has a front matter${bad:+ (not:$bad)}" $?

# Name override: the terminal gets the given name; the template stays "secretary".
: > "$tmp/stub/calls"; rm -f "$tmp/stub/secretary"
out=$(run PADDOCK_SECRETARY_NAME=probe-sec); rc=$?
[ "$rc" -eq 0 ] && grep -qx "run --bg --keep --name probe-sec --cwd $here secretary" "$tmp/stub/calls" \
  && grep -qx 'get probe-sec' "$tmp/stub/calls"; check "PADDOCK_SECRETARY_NAME names the terminal" $?
rm -f "$tmp/stub/secretary"; run >/dev/null # back to the first-run state for the next checks

# Second run: idempotent.
: > "$tmp/stub/calls"
out=$(run); rc=$?
[ "$rc" -eq 0 ]; check "second run exits 0" $?
! grep -q '^run ' "$tmp/stub/calls"; check "second run starts no second secretary" $?
[ "$(find "$tmp/app/mods" -mindepth 1 | wc -l)" -eq 6 ]; check "second run does not duplicate mods" $?

# Issue #129: copies an older org-start left in the templates folder are removed.
printf 'stale\n' > "$tmp/core/templates/worker-rules.md"; printf '{}\n' > "$tmp/core/templates/worker-settings.json"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$tmp/core/templates/worker-rules.md" ] && [ ! -e "$tmp/core/templates/worker-settings.json" ]; check "stale rules and settings copies are removed from the templates folder" $?
cmp -s "$here/templates/worker-rules.md" "$tmp/bin-org/worker-rules.md"; check "the bin folder copy is kept after the cleanup" $?
# A stale copy that cannot be removed fails the run (exit 6), not a silent "ready".
ro=$tmp/ro/templates; mkdir -p "$ro"
cp "$here/templates/secretary.md" "$here/templates/worker.md" "$ro/"; printf 'stale\n' > "$ro/worker-rules.md"
chmod a-w "$ro"
out=$(run PADDOCK_CORE_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/core-notes-off" PADDOCK_CORE_TEMPLATES_DIR="$ro"); rc=$?
chmod u+w "$ro"
[ "$rc" -eq 6 ]; check "a stale copy that cannot be removed exits 6 ($rc)" $?
# The bin folder must not be the templates folder, nor inside it, nor an alias of it.
for b in "$tmp/core/templates" "$tmp/core/templates/sub"; do
  out=$(run PADDOCK_BIN_DIR="$b"); rc=$?
  [ "$rc" -eq 2 ]; check "PADDOCK_BIN_DIR $b refused (exit 2, $rc)" $?
done
ln -s "$tmp/core/templates" "$tmp/alias"
out=$(run PADDOCK_BIN_DIR="$tmp/alias"); rc=$?
[ "$rc" -eq 2 ] && [ -f "$tmp/core/templates/worker.md" ]; check "PADDOCK_BIN_DIR through a symlink to the templates folder refused ($rc)" $?

# Issue #192: a kept secretary terminal that has finished is removed before a new one is started.
: > "$tmp/stub/calls"; : > "$tmp/stub/secretary"; : > "$tmp/stub/finished"
out=$(run); rc=$?
[ "$rc" -eq 0 ]; check "finished secretary: exits 0 ($out)" $?
r=$(grep -n '^rm secretary' "$tmp/stub/calls" | head -1 | cut -d: -f1)
s=$(grep -n '^run ' "$tmp/stub/calls" | head -1 | cut -d: -f1)
[ -n "$r" ] && [ -n "$s" ] && [ "$r" -lt "$s" ]; check "finished secretary: rm is logged, then run" $?
# A live secretary is left alone.
: > "$tmp/stub/calls"
out=$(run); rc=$?
! grep -Eq '^(rm|run) ' "$tmp/stub/calls"; check "live secretary: no rm, no run" $?

exit $fail
