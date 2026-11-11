#!/usr/bin/env bash
# Acceptance test for `org brief` (Issue #191): one read-only call prints the handover, the
# org state and the labelled terminals with their status. Stubbed hc; no core runs.
. "$(dirname "${BASH_SOURCE[0]}")/hc-stub.sh"
org=$here/scripts/org

# The shared stub answers every doc.get with the org-state document; wrap it so the
# handover document answers with its own text.
wrap=$tmp/wrap; mkdir -p "$wrap"
cat > "$wrap/hc" <<EOF2
#!/bin/sh
if [ "\$1" = connect ]; then
  req=\$(cat)
  case "\$req" in
    *secretary-handover*) echo "\$*" >> "\$STUB/calls"
      echo '{"jsonrpc":"2.0","id":1,"result":{"value":{"note":"HANDOVER-MARK pick up t1"},"version":2}}'; exit 0 ;;
  esac
  printf '%s' "\$req" | "$stubdir/hc" "\$@"; exit \$?
fi
exec "$stubdir/hc" "\$@"
EOF2
chmod +x "$wrap/hc"
brief() { env -u CLAUDECODE STUB="$tmp/stub" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_HC_HOLD=0 \
  PATH="$wrap:$PATH" bash "$org" --as secretary brief "$@" 2>&1; }

reset; term w-t1 t1; term other
echo working > "$tmp/stub/state-w-t1"
out=$(brief); rc=$?
[ "$rc" -eq 0 ]; check "org brief exits 0 ($rc)" $?
grep -q 'HANDOVER-MARK' <<<"$out"; check "prints the handover document" $?
grep -q 'Do alpha' <<<"$out" && grep -q 'Beta' <<<"$out"; check "prints the org state" $?
grep -Eq 'w-t1.*t1.*working' <<<"$out"; check "prints the labelled terminal with its status" $?
! grep -q 'other' <<<"$out"; check "leaves out the terminal that has no task label" $?
! grep -Eq '^(run|kill|rm|send|keys|server|set) ' "$calls"; check "the stub logs no write, kill or run" $?
grep -q '^ls' "$calls"; check "the terminals came from hc ls" $?
[ ! -e "$tmp/state/events" ]; check "writes no event record" $?
exit "$fail"
