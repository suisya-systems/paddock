#!/usr/bin/env bash
# secretary-handover: end the secretary's terminal and launch a fresh one that resumes
# from the handover document (Q16 decision c). Needs only bash, coreutils and hc.
# See ../SKILL.md. Run it from the person's login shell or a service, never from an agent.
set -u

usage() {
  cat <<'USAGE'
Usage: secretary-handover.sh [-h|--help]

Reads the core document secretary-handover (written by the secretary), then ends the
secretary terminal (hc kill, hc rm) and runs a fresh one from the secretary template
with "resume from the handover" as the task. Types nothing into any agent.

Environment overrides:
  PADDOCK_SECRETARY_NAME  terminal name (default secretary; same as org-start)

Exit codes: 0 relaunched, 2 bad argument, 3 hc not found, 4 run inside an agent,
5 core unreachable or hc run/kill/rm failed, 8 a turn is in progress, 9 no handover
document, 10 the new secretary did not get its first message, 11 its status could
not be read (nothing was ended).
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
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd) # Issue #130: the new secretary starts here, whatever folder this runs from

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
lang=$(bash "$root/scripts/org" --as secretary config get conversation_language 2>/dev/null) # Q9, Issue #193
[ -z "$lang" ] || [ "$lang" = auto ] || task="$task Conversation language: $lang"
out=$(hc run --bg --keep --name "$name" --cwd "$root" secretary "$task") || die 5 "hc run failed for $name; rerun this script (the handover document is untouched)"
printf '%s' "$out" | grep -Eq '"sent": *true' \
  || die 10 "$name started but first_message.sent is not true. Read it with 'hc read $name' before doing anything else."
echo "secretary-handover: relaunched $name from the handover; it clears the document once it has resumed"
