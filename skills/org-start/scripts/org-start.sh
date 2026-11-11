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
A secretary terminal that has finished is removed (hc rm) before a new one starts.

Environment overrides:
  PADDOCK_CORE_TEMPLATES_DIR  herdr-core templates folder
  PADDOCK_APP_MODS_DIR        herdr-app mods folder
  PADDOCK_APP_LAYOUTS_DIR     herdr-app layouts folder
  PADDOCK_BIN_DIR          folder of the org script and the worker rules and settings (absolute;
                              default ${XDG_DATA_HOME:-~/.local/share}/paddock/bin)
  PADDOCK_READY_TRIES         seconds to wait for a status (default 15)
  PADDOCK_WORKER_GH_TOKEN_FILE  read-only GitHub token file for workers (default $cfg/paddock/worker-gh-token)
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
layouts=${PADDOCK_APP_LAYOUTS_DIR:-$(dirname "$mods")/layouts} # beside mods: an overridden mods folder never touches the real layouts
# Issue #128: the org script goes where a worker may read it and may not write (see worker-settings.json).
orgbin=${PADDOCK_BIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/paddock/bin}
case "$orgbin" in /*) ;; *) die 2 "PADDOCK_BIN_DIR must be an absolute path: $orgbin" ;; esac
tries=${PADDOCK_READY_TRIES:-15}
name=${PADDOCK_SECRETARY_NAME:-secretary} # terminal name only; the template stays "secretary"

# 1. Reuse the core (this starts one from this shell if none runs).
hc ls >/dev/null 2>&1 || die 5 "cannot reach the herdr core (hc ls failed)"

# 2. Place the template and the mods. Plain copies: re-running changes nothing.
mkdir -p "$templates" || die 6 "cannot create $templates"
mkdir -p "$orgbin" || die 6 "cannot create $orgbin"
# The bin folder must not be the templates folder or inside it: the stale cleanup below would remove
# the new copies, and hc would list the rules file. Both exist now, so cd -P resolves symlinks and "..".
pt=$(cd -P "$templates" && pwd) && pb=$(cd -P "$orgbin" && pwd) || die 6 "cannot resolve $templates or $orgbin"
case "$pb/" in "$pt"/*) die 2 "PADDOCK_BIN_DIR must not be the templates folder or inside it: $orgbin" ;; esac
cp -f "$root/templates/secretary.md" "$templates/secretary.md" || die 6 "cannot copy the secretary template"
cp -f "$root/templates/worker.md" "$templates/worker.md" || die 6 "cannot copy the worker template"
# The org commands (Issue #60), and the worker's rules and settings files its template command names
# (Q10, Q12): a worker may read this folder and may not write it (worker-settings.json, Issue #128).
# Not in the templates folder: hc lists every *.md there as a template (Issue #129).
for f in scripts/org scripts/hooks/premise-reminder.sh templates/secretary-settings.json templates/worker-rules.md templates/worker-settings.json; do
  cp -f "$root/$f" "$orgbin/${f##*/}" || die 6 "cannot copy $f to $orgbin"
done
# Copies an older org-start placed beside the templates (Issue #129).
rm -f "$templates/worker-rules.md" "$templates/worker-settings.json" \
  || die 6 "cannot remove the old worker-rules.md / worker-settings.json from $templates"
# Q20: a worker will not start without the read-only GitHub token file. Warn only; never read it.
tokfile=${PADDOCK_WORKER_GH_TOKEN_FILE:-$cfg/paddock/worker-gh-token}
[ -s "$tokfile" ] || echo "org-start: warning: no read-only GitHub token in $tokfile; workers will refuse to start until you create it (see skills/org-start/SKILL.md)" >&2

if [ ! -d "$mods/org-agents" ] && [ -z "${PADDOCK_APP_MODS_DIR:-}" ] && command -v herdr-app >/dev/null 2>&1; then
  # First time: let herdr-app create the folder so it gets the type files.
  herdr-app do mod.clone '{"name":"agents","as":"org-agents"}' >/dev/null 2>&1 \
    || echo "org-start: mod.clone failed; copying the mod without type files" >&2
fi
mkdir -p "$mods/org-agents" || die 6 "cannot create $mods/org-agents"
cp -f "$root/mods/org-agents/main.js" "$root/mods/org-agents/mod.json" "$mods/org-agents/" \
  || die 6 "cannot copy the org-agents mod"

# Issue #195: the screen. The cockpit mod and the layout go to the app's host too.
mkdir -p "$mods/org-cockpit" "$layouts" || die 6 "cannot create $mods/org-cockpit or $layouts"
cp -f "$root/mods/org-cockpit/main.js" "$root/mods/org-cockpit/mod.json" "$mods/org-cockpit/" \
  || die 6 "cannot copy the org-cockpit mod"
# Keep the "secretary" prop (a secretary on another machine) the person put in the installed layout.
# ponytail: the first prop found goes into every org-cockpit block; per-block props if they differ.
keep=$(grep -Eo '"secretary"[[:space:]]*:[[:space:]]*"[^"]*"' "$layouts/paddock.json" 2>/dev/null | head -n 1)
if [ -n "$keep" ]; then
  sed "s|\"props\": { \"role\"|\"props\": { $keep, \"role\"|" "$root/layouts/paddock.json" > "$layouts/paddock.json.new" \
    && mv -f "$layouts/paddock.json.new" "$layouts/paddock.json" || die 6 "cannot place the layout"
else
  cp -f "$root/layouts/paddock.json" "$layouts/paddock.json" || die 6 "cannot place the layout"
fi
# The app's check needs a display; a failure warns and does not stop the start.
if command -v herdr-app >/dev/null 2>&1; then
  herdr-app check "$mods/org-cockpit" >/dev/null 2>&1 \
    || echo "org-start: warning: herdr-app check failed for $mods/org-cockpit (run it by hand to see why)" >&2
fi

# 3. Start the secretary unless one exists. Never stops or restarts the core.
# Issue #192: a kept terminal that has finished still holds the name; remove it first.
if hc get --json "$name" 2>/dev/null | grep -Eq '"state": *"finished"'; then
  hc rm "$name" >/dev/null 2>&1 || die 5 "hc rm $name failed (the finished secretary terminal)"
  echo "org-start: removed the finished $name terminal"
fi
if hc get "$name" >/dev/null 2>&1; then
  echo "org-start: $name already exists; not starting another"
else
  # Issue #130: --cwd, so the secretary finds scripts/org and skills/*/scripts from any starting folder.
  hc run --bg --keep --name "$name" --cwd "$root" secretary || die 5 "hc run failed for the secretary"
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
