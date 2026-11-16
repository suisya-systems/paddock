#!/usr/bin/env bash
# Acceptance test for Issue #444 (decision 0015): org-watch and a proposal of the secretary's own.
# A hidden entry (one with show_at) is not told to the person before or after its show_at; once its
# show_at is reached the watcher writes one line to the secretary's mailbox (run sweep) and decides
# nothing more. A shown entry (no show_at) is an ordinary card. Nothing is sent to any w-*.
# Stubbed hc (tests/hc-stub.sh), the real scripts/org; no core.
. "$(dirname "${BASH_SOURCE[0]}")/hc-stub.sh"
script=$here/skills/org-watch/scripts/org-watch.sh
T=2026-11-16T09:00:00Z; T0=$(date -u -d "$T" +%s); ID=secretary-20261116T090000Z
doc() { printf '{"jsonrpc":"2.0","id":1,"result":{"value":{"work":[],"approvals":[%s]},"version":3}}\n' "$1" > "$tmp/stub/doc"; }
pass() { ENVX="PADDOCK_WATCH_NOW=$1 PADDOCK_WATCH_N=10 PADDOCK_HC_HOLD=0 PADDOCK_NUDGE_RETRY=0 PADDOCK_POWERSHELL=/nonexistent" run_script "$script" --once; }
mails() { PATH="$stubdir:$PATH" PADDOCK_STATE_DIR="$tmp/state" bash "$here/scripts/org" --as secretary check_messages --peek 2>/dev/null | grep -cF "$1"; }
HIDDEN="{\"id\":\"$ID\",\"task_id\":\"secretary\",\"origin\":\"secretary\",\"question\":\"Merge both PRs?\",\"asked_at\":\"$T\",\"show_at\":\"2026-11-16T09:10:00Z\",\"seen\":\"\"}"
SHOWN="{\"id\":\"$ID\",\"task_id\":\"secretary\",\"origin\":\"secretary\",\"question\":\"Merge both PRs?\",\"asked_at\":\"$T\",\"seen\":\"\"}"
M="proposal $ID reached its show time: run org-escalation sweep"

reset; doc "$HIDDEN"
out=$(pass $((T0 + 300)))
! grep -q 'Approval waiting' <<<"$out" && [ "$(mails "$M")" -eq 0 ]; check "hidden before show_at: no toast, no mail" $?
out=$(pass $((T0 + 600)))
! grep -q 'Approval waiting' <<<"$out" && [ "$(mails "$M")" -eq 1 ]; check "show_at reached: one mail to the secretary, still no toast" $?
pass $((T0 + 630)) >/dev/null; [ "$(mails "$M")" -eq 1 ]; check "not repeated on the next pass" $?
doc "$SHOWN"; out=$(pass $((T0 + 660)))
grep -q 'Approval waiting: secretary - Merge both PRs?' <<<"$out"; check "once the sweep showed it: an ordinary approval toast" $?
! grep -q '"to":"w-' "$tmp"/state/events/*/*.jsonl 2>/dev/null && ! grep -q '^send w-' "$calls"; check "nothing to any w-*" $?
exit "$fail"
