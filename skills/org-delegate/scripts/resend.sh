#!/usr/bin/env bash
# resend.sh <task_id>: finish a delegate that stopped at the folder-trust dialog (org-delegate exit 10). Sends the first
# message org-delegate saved, once w-<task_id> reports a status, then writes the work entry (--title) it saved.
# org-escalation answer yes runs it after the dialog; run it by hand to retry after exit 12 or 13. See ../SKILL.md.
# Exit codes: 0 done, 2 bad argument, 6 nothing saved for this task, 12 no status or the send failed (kept),
# 13 sent, but the org-state entry was not written (kept; run again).
set -u
die() { code=$1; shift; echo "resend: $*" >&2; exit "$code"; }
id=${1:-}
case "$id" in ''|-*|*[!a-z0-9_-]*) die 2 "usage: resend.sh <task_id>" ;; esac
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
. "$(dirname "${BASH_SOURCE[0]}")/work-entry.sh"
d=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}/resend/$id
w=w-$id
if [ -f "$d/message" ]; then
  i=0
  until hc get --json "$w" 2>/dev/null | tr -d '\n' | grep -Eq '"status": *\{'; do
    i=$((i + 1)); [ "$i" -lt "${PADDOCK_PROMPT_TRIES:-30}" ] || die 12 "$w reports no status; the first message was not sent (kept: run resend.sh $id again)"
    sleep 1
  done
  hc send "$w" "$(cat "$d/message")" >/dev/null 2>&1 || die 12 "hc send to $w failed; the first message was not sent (kept: run resend.sh $id again)"
  rm -f "$d/message"; echo "SENT $w"
elif [ ! -f "$d/entry" ]; then die 6 "nothing saved for $id"; fi
if [ -f "$d/entry" ]; then
  work_entry_add "$root/scripts/org" "$id" "$(cat "$d/entry")" \
    || die 13 "$w got its first message, but the org-state entry was not written (kept: run resend.sh $id again)"
  rm -f "$d/entry"
fi
rmdir "$d" 2>/dev/null; exit 0
