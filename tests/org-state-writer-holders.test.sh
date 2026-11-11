#!/usr/bin/env bash
# Acceptance test for Issue #38 (hold line L-N8, the org-state half). What a static check can
# show about "only the secretary writes org-state":
# 1. scripts/org refuses a document write (set, update) from any id but the secretary, for both
#    documents, before it calls hc; a read (get) is open. This is the id the caller claims
#    (--as), so it is a check by convention; the test says what the script does, not that it binds.
# 2. The host probe that measures whether a worker can doc.set exists, runs only against its own
#    core, leaves claude's data folder alone, and restores the claude link on exit (Issue #212).
# 3. Row L-N8 of the inventory names the holders and the probe.
# Needs bash and coreutils; hc is a stub, so no core runs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
probe=$here/scripts/probes/org-state-write-denied.sh
inv=$here/docs/design/predecessor-inventory.md
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
mkdir -p "$tmp/bin"
cat > "$tmp/bin/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$HC_CALLS"
cat > /dev/null
echo '{"jsonrpc":"2.0","id":1,"result":{"value":{"work":[],"approvals":[]},"version":1}}'
EOF2
chmod +x "$tmp/bin/hc"
export HC_CALLS=$tmp/calls PADDOCK_STATE_DIR=$tmp/state PADDOCK_HC_HOLD=0 PATH="$tmp/bin:$PATH"
: > "$HC_CALLS"
org() { bash "$here/scripts/org" "$@"; }

# 1. The script's writer check.
for d in org-state secretary-handover; do
  for id in w-p38 person w-secretary secretary-2; do
    for sub in set update; do
      : > "$HC_CALLS"
      if [ "$sub" = set ]; then echo '{}' | org --as "$id" doc set "$d" >/dev/null 2>&1; rc=$?
      else org --as "$id" doc update "$d" -- cat >/dev/null 2>&1 </dev/null; rc=$?; fi
      [ "$rc" -eq 7 ] && [ ! -s "$HC_CALLS" ]; check "$id: doc $sub $d exits 7 and never calls hc" $?
    done
  done
done
: > "$HC_CALLS"
org --as w-p38 doc get org-state >/dev/null 2>&1; [ -s "$HC_CALLS" ]; check "a worker can read org-state (doc get reaches hc)" $?
: > "$HC_CALLS"
echo '{"work":[],"approvals":[]}' | org --as secretary doc set org-state >/dev/null 2>&1; [ -s "$HC_CALLS" ]; check "the secretary's doc set reaches hc" $?

# 2. The host probe.
[ -f "$probe" ]; check "scripts/probes/org-state-write-denied.sh exists" $?
if [ -f "$probe" ]; then
  sh -n "$probe"; check "the probe parses (sh -n)" $?
  grep -q '^HC_SESSION=' "$probe" && grep -q '^XDG_CONFIG_HOME=' "$probe"; check "the probe sets its own HC_SESSION and XDG_CONFIG_HOME (a temporary core)" $?
  ! grep -Eq '^[[:space:]]*(export[[:space:]]+)?XDG_DATA_HOME=' "$probe"; check "the probe never sets XDG_DATA_HOME for claude (Issue #212)" $?
  grep -q '^\. .*claude-link\.sh' "$probe" && grep -q '^claude_link_save' "$probe" && grep -q 'claude_link_restore' "$probe"; check "the probe saves the claude link and restores it from its exit trap (Issues #212, #213)" $?
  grep -q 'claude -p' "$probe" && grep -q -- '--settings "\$ROOT/templates/worker-settings.json"' "$probe" && grep -q 'worker-rules.md' "$probe"; check "the probe runs claude -p with the shipped worker settings and rules" $?
  grep -q 'denyRead' "$probe" && grep -q 'denyWrite' "$probe"; check "the probe gives the run the per-task socket-folder entries" $?
  ! grep -Eq '^[^#]*(hc run|hc keys|org-delegate\.sh|org-start\.sh)' "$probe"; check "the probe starts no worker terminal and answers no dialog (folder-trust is not raised by claude -p)" $?
  ! grep -Eq 'PROJ=\$\{1|NEEDS-PERSON' "$probe"; check "the probe needs no argument and never stops for a person" $?
  grep -q 'doc set org-state' "$probe" && grep -q -- '--as secretary' "$probe"; check "the probe tries a worker doc set of org-state, also with the id forged to secretary" $?
  grep -q 'hc connect' "$probe"; check "the probe also tries a raw hc connect outside the script" $?
fi

# 3. The inventory row.
row=$(grep '^| L-N8 ' "$inv")
for want in "scripts/probes/org-state-write-denied.sh" "tests/org-state-writer-holders.test.sh"; do
  case "$row" in *"$want"*) check "row L-N8 names $want" 0 ;; *) check "row L-N8 names $want" 1 ;; esac
done
[ "$fail" -eq 0 ]
