#!/usr/bin/env bash
# secretary-handover: end the secretary's terminal and launch a fresh one that resumes
# from the handover document (Q16 decision c). Needs only bash, coreutils and hc.
# See ../SKILL.md. The watcher (org-watch) runs it on the marker watcher/renew-secretary; the person
# can run it from their login shell or a service. Never from an agent.
set -u

usage() {
  cat <<'USAGE'
Usage: secretary-handover.sh [-h|--help]

Reads the core document secretary-handover (written by the secretary), then ends the
secretary terminal (hc kill, hc rm) and runs a fresh one from the secretary template
with "resume from the handover" as the task, in the secretary's own folder <state>/secretary
(the rules org-start placed there are its AGENTS.md). Types nothing into any agent, except when
that folder's trust dialog stops the new secretary: then it answers the dialog once (Yes, checked
on the screen first) and sends the first message again.

Environment overrides:
  PADDOCK_SECRETARY_NAME  terminal name (default secretary; same as org-start)
  PADDOCK_STATE_DIR       state folder; the secretary runs in its secretary/ (default
                          ${XDG_STATE_HOME:-~/.local/state}/paddock; same as org-start)
  PADDOCK_READY_TRIES     seconds to wait for a status after the trust dialog (default 15)

Exit codes: 0 relaunched, 2 bad argument, 3 hc not found, 4 run inside an agent,
5 core unreachable or hc run/kill/rm failed, 8 a turn is in progress, 9 no handover
document, 10 the new secretary did not get its first message, 11 its status could
not be read (nothing was ended), 12 the secretary's rules are not placed (nothing was ended).
USAGE
}

case "${1:-}" in
  "") ;;
  -h|--help) usage; exit 0 ;;
  *) echo "secretary-handover: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

die() { code=$1; shift; echo "secretary-handover: $*" >&2; exit "$code"; }

command -v hc >/dev/null 2>&1 || die 3 "hc not found on PATH (install herdr-core)"

# Same start rule as org-start (Q17 d): not from inside an agent.
for v in CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID \
         CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN; do
  if [ -n "$(printenv "$v" 2>/dev/null)" ]; then
    die 4 "$v is set: this shell is inside an agent. Run it from your own login shell."
  fi
done

name=${PADDOCK_SECRETARY_NAME:-secretary}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd) # the checkout: its scripts and template body
sdir=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}/secretary # where the new secretary starts (decision 0014 F)
[ -f "$sdir/AGENTS.md" ] && [ -f "$sdir/CLAUDE.md" ] \
  || die 12 "the secretary's rules are not placed in $sdir (AGENTS.md, CLAUDE.md). Run bash $root/skills/org-start/scripts/org-start.sh --place-only first, then this again; nothing was ended."
# the template's PADDOCK_HOME comes from this file; a missing or stale one would start a secretary without its tools.
bd=${PADDOCK_BIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/paddock/bin}
ph=$(cat "$bd/paddock-home" 2>/dev/null)
[ -n "$ph" ] && [ -f "$ph/scripts/org" ] \
  || die 12 "$bd/paddock-home does not name a paddock checkout ('$ph'). Run bash $root/skills/org-start/scripts/org-start.sh --place-only first, then this again; nothing was ended."

# 1. The handover document must exist before anything is ended. hc has no document verb,
# so one doc.get line goes into hc connect, input held open 1 s (prototype 1).
# ponytail: the answer shape {"result":{"value":{...}}} is read from the mod's code, not measured here.
req='{"jsonrpc":"2.0","id":1,"method":"doc.get","params":{"name":"secretary-handover"}}'
doc=$({ printf '%s\n' "$req"; sleep 1; } | hc connect 2>/dev/null) || die 5 "cannot reach the herdr core (hc connect failed)"
printf '%s' "$doc" | grep -Eq '"value": *\{' \
  || die 9 "no secretary-handover document (never written, or already cleared). Ask the secretary to write it first; nothing was ended."

# 2. Never end a secretary that is mid-turn, and never guess: an unreadable status is a refusal.
# Only a clear not_found means there is no old terminal (an earlier run may have died after rm).
if st=$(hc get --json "$name" 2>&1); then
  st=$(printf '%s' "$st" | tr -d '\n')
  printf '%s' "$st" | grep -Eq '"state": *"' \
    || die 11 "cannot read the status of $name (unexpected hc get output); nothing was ended."
  if printf '%s' "$st" | grep -Eq '"status": *\{[^{}]*"state": *"(working|blocked)"'; then
    die 8 "$name has a turn in progress (working or blocked). Wait until it is idle, then rerun; nothing was ended."
  fi
  hc kill "$name" >/dev/null 2>&1 || die 5 "hc kill $name failed"
  hc rm "$name" >/dev/null 2>&1 || die 5 "hc rm $name failed"
elif ! printf '%s' "$st" | grep -q 'not_found'; then
  die 11 "cannot read the status of $name (hc get failed); nothing was ended."
fi

# 3. The task travels in the launch (decision 0002). The new secretary reads the document itself.
task="Resume as the secretary from the handover. Read the core document secretary-handover (doc.get through hc connect), the org-state document, and hc ls for the running workers (task_id labels). Take up what they say, then clear secretary-handover (doc.set with a null value) and tell the person you are back."
lang=$(bash "$root/scripts/org" --as secretary config get conversation_language 2>/dev/null) # Q9
[ -z "$lang" ] || [ "$lang" = auto ] || task="$task Conversation language: $lang"
out=$(hc run --bg --keep --name "$name" --cwd "$sdir" secretary "$task") || die 5 "hc run failed for $name; rerun this script (the handover document is untouched)"
if ! printf '%s' "$out" | grep -Eq '"sent": *true'; then
  # The first launch in a new folder stops at Claude Code's folder-trust dialog (decision 0014 F moved the
  # secretary to <state>/secretary): answer it as org-start does, wait for a status, send the first message again.
  . "$root/skills/org-start/scripts/trust-dialog.sh"
  td_answer "$name"; case $? in
    1) die 10 "$name started but first_message.sent is not true. Read it with 'hc read $name' before doing anything else." ;;
    2) die 10 "$name shows the folder-trust dialog and the cursor did not reach 'Yes, I trust this folder'; nothing confirmed. Look at 'hc read $name'" ;;
  esac
  echo "secretary-handover: accepted the folder-trust dialog for $sdir on $name"
  i=0; tries=${PADDOCK_READY_TRIES:-15}
  until hc get --json "$name" 2>/dev/null | grep -Eq '"status": *\{'; do
    i=$((i + 1)); [ "$i" -lt "$tries" ] || die 10 "$name has no status ${tries}s after the folder-trust dialog. Read it with 'hc read $name'"
    sleep 1
  done
  body=$(awk 'n >= 2 { print; next } /^---$/ { n++ }' "$root/templates/secretary.md")
  hc send "$name" "$body

$task" >/dev/null 2>&1 \
    || die 10 "answered the folder-trust dialog but could not send the first message to $name; send the template body and the task by hand with hc send $name"
fi
# the request the secretary left for the watcher (scripts/org renew_secretary) is fulfilled, whoever ran this
rm -f "${sdir%/secretary}/watcher/renew-secretary"
echo "secretary-handover: relaunched $name from the handover; it clears the document once it has resumed"
