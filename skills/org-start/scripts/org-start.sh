#!/usr/bin/env bash
# org-start: reuse the herdr core, start the secretary, place the mods, report readiness.
# Needs only bash, coreutils and hc. See ../SKILL.md. Run it from the person's login shell.
set -u

usage() {
  cat <<'USAGE'
Usage: org-start.sh [-h|--help]

Starts the paddock secretary on the running herdr core (the first hc command
starts a core if none runs; run this from a login shell, never from an agent).
Idempotent: a second run starts no second secretary and copies the same files.

Environment overrides:
  PADDOCK_CORE_TEMPLATES_DIR  herdr-core templates folder
  PADDOCK_APP_MODS_DIR        herdr-app mods folder
  PADDOCK_READY_TRIES         seconds to wait for a status (default 15)
  PADDOCK_SECRETARY_NAME      terminal name of the secretary (default secretary)

Exit codes: 0 ready, 2 bad argument, 3 hc not found, 4 run inside an agent,
5 core unreachable, 6 files could not be placed, 7 secretary has no status.
USAGE
}

case "${1:-}" in
  "") ;;
  -h|--help) usage; exit 0 ;;
  *) echo "org-start: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

die() { code=$1; shift; echo "org-start: $*" >&2; exit "$code"; }

command -v hc >/dev/null 2>&1 || die 3 "hc not found on PATH (install herdr-core)"

# Q17 (d): never start a core from inside an agent. The first hc command starts a
# core that inherits this environment, so refuse before any hc call.
# ponytail: a core that an agent already started cannot be detected yet (no probe
# reads the core's own environment); the start rule and the template's env -u cover it.
for v in CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID \
         CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN; do
  if [ -n "$(printenv "$v" 2>/dev/null)" ]; then
    die 4 "$v is set: this shell is inside an agent. Run org-start from your own login shell."
  fi
done

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cfg=${XDG_CONFIG_HOME:-$HOME/.config}
[ -n "${APPDATA:-}" ] && cfg=$APPDATA # Windows (Git Bash)
templates=${PADDOCK_CORE_TEMPLATES_DIR:-$cfg/herdr-core/templates}
mods=${PADDOCK_APP_MODS_DIR:-$cfg/herdr-app/mods}
tries=${PADDOCK_READY_TRIES:-15}
name=${PADDOCK_SECRETARY_NAME:-secretary} # terminal name only; the template stays "secretary"

# 1. Reuse the core (this starts one from this shell if none runs).
hc ls >/dev/null 2>&1 || die 5 "cannot reach the herdr core (hc ls failed)"

# 2. Place the template and the mods. Plain copies: re-running changes nothing.
mkdir -p "$templates" || die 6 "cannot create $templates"
cp -f "$root/templates/secretary.md" "$templates/secretary.md" || die 6 "cannot copy the secretary template"

if [ ! -d "$mods/org-agents" ] && [ -z "${PADDOCK_APP_MODS_DIR:-}" ] && command -v herdr-app >/dev/null 2>&1; then
  # First time: let herdr-app create the folder so it gets the type files.
  herdr-app do mod.clone '{"name":"agents","as":"org-agents"}' >/dev/null 2>&1 \
    || echo "org-start: mod.clone failed; copying the mod without type files" >&2
fi
mkdir -p "$mods/org-agents" || die 6 "cannot create $mods/org-agents"
cp -f "$root/mods/org-agents/main.js" "$root/mods/org-agents/mod.json" "$mods/org-agents/" \
  || die 6 "cannot copy the org-agents mod"

# 3. Start the secretary unless one exists. Never stops or restarts the core.
if hc get "$name" >/dev/null 2>&1; then
  echo "org-start: $name already exists; not starting another"
else
  hc run --bg --keep --name "$name" secretary || die 5 "hc run failed for the secretary"
fi

# 4. Readiness: hc get shows a status object. (The CLAUDE_CODE_CHILD_SESSION check is probe #52.)
i=0
while [ "$i" -lt "$tries" ]; do
  if hc get --json "$name" 2>/dev/null | grep -Eq '"status": *\{'; then
    echo "org-start: ready. $name reports a status; the mod is in $mods/org-agents"
    exit 0
  fi
  i=$((i + 1)); sleep 1
done
die 7 "secretary has no status after ${tries}s; look at 'hc get $name' and 'hc read $name'"
