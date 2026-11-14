#!/usr/bin/env bash
# org-start: reuse the herdr core, start the secretary, place the mods, report readiness.
# Needs only bash, coreutils and hc. See ../SKILL.md. Run it from the person's login shell.
set -u

usage() {
  cat <<'USAGE'
Usage: org-start.sh [-h|--help]
       org-start.sh --check [--project DIR]...

Starts the paddock secretary on the running herdr core (the first hc command
starts a core if none runs; run this from a login shell, never from an agent).
Idempotent: a second run starts no second secretary and copies the same files.
A secretary terminal that has finished is removed (hc rm) before a new one starts.
A folder-trust dialog on the secretary is answered once (Yes, checked on the screen first).

--check only checks the first-run steps (hc, agent shell, claude, notes = false, hc on the running core's PATH,
and the folder trust of each --project clone) and prints 'ok <step>: ...' or 'TODO <step>: <exact fix>' for
every one. Read-only: it places nothing, calls no hc, starts no secretary. Exit 0 only when no TODO is left.
The core's PATH is read from /proc/<core pid>/environ (Linux and WSL only; the line says so elsewhere).

Environment overrides:
  PADDOCK_CORE_TEMPLATES_DIR  herdr-core templates folder
  PADDOCK_CORE_CONFIG_DIR     herdr-core config folder checked for notes = false (default $cfg/herdr-core)
  PADDOCK_APP_MODS_DIR        herdr-app mods folder
  PADDOCK_APP_LAYOUTS_DIR     herdr-app layouts folder
  HERDR_APP_HOME              the Linux herdr-app's home (socket looked for there; default ~/.config/herdr-app)
  PADDOCK_APP_MACHINE         machine name the app gives this core; the layout's secretary prop
                              becomes <machine>/<name> (default wsl when the app is herdr-app for
                              Windows and this is WSL)
  PADDOCK_BIN_DIR          folder of the org script and the worker rules and settings (absolute;
                              default ${XDG_DATA_HOME:-~/.local/share}/paddock/bin)
  PADDOCK_READY_TRIES         seconds to wait for a status (default 15)
  PADDOCK_SECRETARY_NAME      terminal name of the secretary (default secretary)
  PADDOCK_WATCHER_NAME        terminal name of the watcher (default watcher)
  PADDOCK_PROC_DIR            replaces /proc when the core's PATH is read (tests)

Exit codes: 0 ready (7 also prints the terminal exit code and last line), 2 bad argument, 3 hc not found, 4 run inside an agent,
5 core unreachable, 6 files could not be placed, 7 secretary has no status,
8 herdr-core notes are on (no notes = false in the core config).
9 claude not found from org-start's shell (the templates need its absolute path).
10 hc is not on the running core's PATH (restart herdr from a login shell that has it).
--check: 0 nothing left for a person, 1 a TODO is printed, 2 bad argument.
USAGE
}

check= projects=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --check) check=1; shift ;;
    --project) [ $# -ge 2 ] || { echo "org-start: --project needs a value" >&2; exit 2; }
      projects="$projects
$2"; shift 2 ;;
    *) echo "org-start: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -z "$projects" ] || [ -n "$check" ] || { echo "org-start: --project only goes with --check" >&2; exit 2; }

die() { code=$1; shift; echo "org-start: $*" >&2; exit "$code"; }

agentvar() { # the first agent session variable set in this environment
  for v in CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID \
           CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN; do
    if [ -n "$(printenv "$v" 2>/dev/null)" ]; then echo "$v"; return 0; fi
  done
  return 1
}

if [ -z "$check" ]; then
  command -v hc >/dev/null 2>&1 || die 3 "hc not found on PATH (install herdr-core)"
  # Q17 (d): never start a core from inside an agent. The first hc command starts a
  # core that inherits this environment, so refuse before any hc call.
  # ponytail: a core that an agent already started cannot be detected yet (no probe
  # reads the core's own environment); the start rule and the template's env -u cover it.
  v=$(agentvar) && die 4 "$v is set: this shell is inside an agent. Run org-start from your own login shell."
fi

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cfg=${XDG_CONFIG_HOME:-$HOME/.config}
[ -n "${APPDATA:-}" ] && cfg=$APPDATA # Windows (Git Bash)
templates=${PADDOCK_CORE_TEMPLATES_DIR:-$cfg/herdr-core/templates}
# the first-run checks (notes, core PATH, folder trust) are shared with prepare and setup.
. "$(dirname "${BASH_SOURCE[0]}")/first-run-checks.sh"
# Decision 0002: the core's child notes must be off. Never written here (the secretary may not
# write the core's config, L-N1).
coreconf=${PADDOCK_CORE_CONFIG_DIR:-$cfg/herdr-core}

if [ -n "$check" ]; then # every step, read-only; the first TODO does not hide the others
  todo=0
  ok() { echo "ok $1: $2"; }
  fix() { echo "TODO $1: $2"; todo=1; }
  if command -v hc >/dev/null 2>&1; then ok hc "found at $(command -v hc)"; else fix hc "install herdr-core and put its folder on PATH"; fi
  if v=$(agentvar); then fix agent-shell "$v is set: this shell is inside an agent; run org-start from your own login shell"
  else ok agent-shell "not inside an agent"; fi
  if command -v claude >/dev/null 2>&1; then ok claude "found at $(command -v claude)"
  else fix claude "put claude's folder on PATH (often ~/.local/bin) in this shell"; fi
  if fr_notes_ok "$coreconf"; then ok notes "notes = false in $coreconf/config.toml"; else fix notes "$FR_NOTES_FIX"; fi
  if command -v hc >/dev/null 2>&1; then
    fr_core_path; case $? in
      0) ok core-path "hc is on the running core's PATH" ;;
      1) fix core-path "$FR_PATH_FIX" ;;
      *) echo "skip core-path: $FR_PATH_WHY" ;;
    esac
  else echo "skip core-path: hc is not on PATH, so there is nothing to look for"; fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if fr_trusted "$p"; then ok trust "$p is recorded as trusted"
    else fix trust "$p is not recorded as trusted; a worker cut from it would stop at the dialog. Run once: cd '$p' && claude   # answer 'Yes, I trust this folder', then leave with /exit"; fi
  done <<<"$projects"
  exit "$todo"
fi

fr_notes_ok "$coreconf" || die 8 "herdr-core's notes are on: $FR_NOTES_FIX"
# Decision 0007: hc must be on the running core's PATH. Read from the core's own environment;
# silent where /proc is not readable (Linux and WSL only) or no core runs yet (the first hc starts one from here).
fr_core_path || { [ $? -eq 2 ] || die 10 "$FR_PATH_FIX"; }
# on WSL, herdr-app for Windows reads the Windows user's .config/herdr-app and sees this
# core as another machine (wsl). A herdr-app on PATH that is not an .exe is a Linux app: WSL's folder.
app=$(command -v herdr-app 2>/dev/null); appcfg=$cfg/herdr-app; appmachine=
# readlink only on a found app: some readlink builds answer "" with the current folder.
case "${app:+$(readlink -f "$app" 2>/dev/null)}" in ""|*.exe) winapp=1 ;; *) winapp= ;; esac
# a Linux herdr-app on PATH looks for the window at its own socket (HERDR_APP_HOME or
# ~/.config/herdr-app). The Windows window's socket is a file in the Windows user's folder, which WSL
# cannot connect to but can see: when WSL has none and Windows has one, the Windows program is used.
lsock=${HERDR_APP_HOME:-${HOME:-}/.config/herdr-app}/herdr-app.sock; wsock=
if [ -n "${WSL_DISTRO_NAME:-}" ] && [ -z "${PADDOCK_APP_MODS_DIR:-}" ] && { [ -n "$winapp" ] || [ ! -e "$lsock" ]; }; then
  winhome=$(wslpath "$(cmd.exe /d /c echo %USERPROFILE% 2>/dev/null | tr -d '\r')" 2>/dev/null)
  if [ -n "$winhome" ] && [ -d "$winhome" ]; then
    wsock=$winhome/.config/herdr-app/herdr-app.sock
    if [ -n "$winapp" ] || [ -e "$wsock" ]; then
      appcfg=$winhome/.config/herdr-app; appmachine=wsl
      # ponytail: the installer's default folder; LOCALAPPDATA moved elsewhere needs herdr-app(.exe) on PATH.
      exe=$winhome/AppData/Local/Programs/herdr-app/herdr-app.exe
      [ -n "$winapp" ] || app= # the Linux program has no window here
      # Bash adds no .exe, so herdr-app.exe on PATH is looked up by that name.
      [ -n "$app" ] || app=$(command -v herdr-app.exe 2>/dev/null) || { [ ! -x "$exe" ] || app=$exe; }
    fi
  elif [ -n "$winapp" ]; then
    echo "org-start: warning: WSL, but the Windows user folder was not found (cmd.exe, wslpath); placing the mods under $cfg/herdr-app" >&2
  fi
fi
apppath() { if [ -n "$appmachine" ]; then wslpath -w "$1"; else printf '%s\n' "$1"; fi; } # a path herdr-app reads
mods=${PADDOCK_APP_MODS_DIR:-$appcfg/mods}
layouts=${PADDOCK_APP_LAYOUTS_DIR:-$(dirname "$mods")/layouts} # beside mods: an overridden mods folder never touches the real layouts
# the org script goes where a worker may read it and may not write (see worker-settings.json).
orgbin=${PADDOCK_BIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/paddock/bin}
case "$orgbin" in /*) ;; *) die 2 "PADDOCK_BIN_DIR must be an absolute path: $orgbin" ;; esac
tries=${PADDOCK_READY_TRIES:-15}
name=${PADDOCK_SECRETARY_NAME:-secretary} # terminal name only; the template stays "secretary"

# 1. Reuse the core (this starts one from this shell if none runs).
hc ls >/dev/null 2>&1 || die 5 "cannot reach the herdr core (hc ls failed)"

# a terminal takes PATH from the core's holder, which may lack claude's folder. Record the
# absolute path found here; the templates exec it (and fall back to plain claude if the file is stale).
claudebin=$(command -v claude 2>/dev/null)
case "$claudebin" in /*) ;; *) die 9 "claude not found on PATH in this shell: put its folder on PATH (often ~/.local/bin) and run org-start again" ;; esac

# 2. Place the template and the mods. Plain copies: re-running changes nothing.
mkdir -p "$templates" || die 6 "cannot create $templates"
mkdir -p "$orgbin" || die 6 "cannot create $orgbin"
# The bin folder must not be the templates folder or inside it: the stale cleanup below would remove
# the new copies, and hc would list the rules file. Both exist now, so cd -P resolves symlinks and "..".
pt=$(cd -P "$templates" && pwd) && pb=$(cd -P "$orgbin" && pwd) || die 6 "cannot resolve $templates or $orgbin"
case "$pb/" in "$pt"/*) die 2 "PADDOCK_BIN_DIR must not be the templates folder or inside it: $orgbin" ;; esac
cp -f "$root/templates/secretary.md" "$templates/secretary.md" || die 6 "cannot copy the secretary template"
cp -f "$root/templates/worker.md" "$templates/worker.md" || die 6 "cannot copy the worker template"
# Decision 0009: the curator, which the secretary starts with `org-curate.sh start` (it writes the curator's settings file first).
cp -f "$root/templates/curator.md" "$templates/curator.md" || die 6 "cannot copy the curator template"
# The org commands, and the worker's rules and settings files its template command names
# (Q10, Q12): a worker may read this folder and may not write it (worker-settings.json).
# Not in the templates folder: hc lists every *.md there as a template.
for f in scripts/org scripts/second-model-review.sh scripts/hooks/premise-reminder.sh templates/secretary-settings.json templates/worker-rules.md templates/worker-settings.json; do
  cp -f "$root/$f" "$orgbin/${f##*/}" || die 6 "cannot copy $f to $orgbin"
done
printf '%s\n' "$claudebin" > "$orgbin/claude-path" || die 6 "cannot write $orgbin/claude-path"
# same for the review gate's CLI, which often lives in a Node version manager's folder. Optional:
# without it the gate ends "unavailable" and prepare's codex-cli check says so. Drop a stale record.
rm -f "$orgbin/codex-path" || die 6 "cannot remove the old $orgbin/codex-path"
# Record a path that outlives this shell. fnm puts codex under a per-shell folder
# (.../fnm_multishells/<pid>_<ms>, a link to the install) that goes away with the shell, so each PATH
# entry is resolved to its real folder (the file name is kept: a Node CLI needs its folder's node) and a
# folder that is still under fnm_multishells is skipped. The first one found is recorded, which is the
# one the gate runs; a second, different install gets a warning with the fix.
codexbin= codexall=
oldifs=$IFS; IFS=:
for d in $PATH; do
  [ -n "$d" ] && [ -x "$d/codex" ] && [ -f "$d/codex" ] || continue
  rd=$(cd -P "$d" 2>/dev/null && pwd -P) || continue
  case "$rd/" in */fnm_multishells/*) echo "org-start: skipping $d/codex: it is under fnm's temporary folder fnm_multishells, which goes away with its shell; install codex outside it (npm i -g @openai/codex under one Node version) and put that folder on PATH" >&2; continue ;; esac
  real=$(readlink -f "$rd/codex" 2>/dev/null) || real=$rd/codex
  case " $codexall " in *" $real "*) continue ;; esac
  codexall="$codexall $real"
  [ -n "$codexbin" ] && codexmore="${codexmore:-}
  $rd/codex ($("$rd/codex" --version 2>/dev/null | head -n 1))" || codexbin=$rd/codex
done
IFS=$oldifs
if [ -n "$codexbin" ]; then
  printf '%s\n' "$codexbin" > "$orgbin/codex-path" || die 6 "cannot write $orgbin/codex-path"
  if [ -n "${codexmore:-}" ]; then
    echo "org-start: several codex installs are on PATH; the review gate will run $codexbin ($("$codexbin" --version 2>/dev/null | head -n 1)), the first. Others:$codexmore
  To use another, put its folder first on PATH and run org-start again, or remove the ones you do not want." >&2
  fi
fi
# Copies an older org-start placed beside the templates.
rm -f "$templates/worker-rules.md" "$templates/worker-settings.json" \
  || die 6 "cannot remove the old worker-rules.md / worker-settings.json from $templates"

if [ ! -d "$mods/org-agents" ] && [ -z "${PADDOCK_APP_MODS_DIR:-}" ] && [ -n "$app" ]; then
  # First time: let herdr-app create the folder so it gets the type files.
  "$app" do mod.clone '{"name":"agents","as":"org-agents"}' >/dev/null 2>&1 \
    || echo "org-start: mod.clone failed; copying the mod without type files" >&2
fi
mkdir -p "$mods/org-agents" || die 6 "cannot create $mods/org-agents"
cp -f "$root/mods/org-agents/main.js" "$root/mods/org-agents/mod.json" "$mods/org-agents/" \
  || die 6 "cannot copy the org-agents mod"

# the screen. The cockpit mod and the layout go to the app's host too.
mkdir -p "$mods/org-cockpit" "$layouts" || die 6 "cannot create $mods/org-cockpit or $layouts"
cp -f "$root/mods/org-cockpit/main.js" "$root/mods/org-cockpit/mod.json" "$mods/org-cockpit/" \
  || die 6 "cannot copy the org-cockpit mod"
# Keep the "secretary" prop (a secretary on another machine) the person put in the installed layout.
# ponytail: the first prop found goes into every org-cockpit block; per-block props if they differ.
keep=$(grep -Eo '"secretary"[[:space:]]*:[[:space:]]*"[^"]*"' "$layouts/paddock.json" 2>/dev/null | head -n 1)
# when the app sees this core as another machine, the prop names this secretary there.
# The machine: PADDOCK_APP_MACHINE, else the one in the installed prop (a stale name is replaced), else wsl.
machine=${PADDOCK_APP_MACHINE:-$(printf '%s' "$keep" | sed -n 's|.*:[[:space:]]*"\([^/"]*\)/.*|\1|p')}
machine=${machine:-$appmachine}
[ -z "$machine" ] || keep="\"secretary\": \"$machine/$name\""
if [ -n "$keep" ]; then
  sed "s|\"props\": { \"role\"|\"props\": { $keep, \"role\"|" "$root/layouts/paddock.json" > "$layouts/paddock.json.new" \
    && mv -f "$layouts/paddock.json.new" "$layouts/paddock.json" || die 6 "cannot place the layout"
else
  cp -f "$root/layouts/paddock.json" "$layouts/paddock.json" || die 6 "cannot place the layout"
fi
# The app's check needs a display; a failure warns and does not stop the start.
if [ -n "$app" ]; then
  "$app" check "$(apppath "$mods/org-cockpit")" >/dev/null 2>&1 \
    || echo "org-start: warning: herdr-app check failed for $mods/org-cockpit (run it by hand to see why)" >&2
  echo "org-start: to open the screen: $(printf '%q' "$app") do layout.switch '{\"name\":\"paddock\"}'"
  # switch now, and say which window sockets were looked for. A failure only warns.
  sw=$("$app" do layout.switch '{"name":"paddock"}' 2>&1) \
    && echo "org-start: switched the screen to the paddock layout with $app" \
    || echo "org-start: warning: layout.switch failed: $sw" >&2
fi
if [ -n "${WSL_DISTRO_NAME:-}" ] && [ -n "$wsock" ]; then
  echo "org-start: herdr-app window sockets looked for: $lsock (WSL), $wsock (Windows)"
fi

# 3. Start the secretary unless one exists. Never stops or restarts the core.
# a kept terminal that has finished still holds the name; remove it first.
if hc get --json "$name" 2>/dev/null | grep -Eq '"state": *"finished"'; then
  hc rm "$name" >/dev/null 2>&1 || die 5 "hc rm $name failed (the finished secretary terminal)"
  echo "org-start: removed the finished $name terminal"
fi
# Q9: unless it is auto, the conversation language (org config) ends the launch task.
lang=$(bash "$root/scripts/org" --as secretary config get conversation_language 2>/dev/null)
task=; [ -z "$lang" ] || [ "$lang" = auto ] || task="Conversation language: $lang"
started=
if hc get "$name" >/dev/null 2>&1; then
  echo "org-start: $name already exists; not starting another"
else
  # --cwd, so the secretary finds scripts/org and skills/*/scripts from any starting folder.
  hc run --bg --keep --name "$name" --cwd "$root" secretary ${task:+"$task"} || die 5 "hc run failed for the secretary"
  started=1
fi

# 3b. The watcher (decision 0008): a kept terminal named watcher that tells the person outside the
# window. It carries paddock_role=watcher, so org-down ends it and no other terminal of that name.
# A terminal gets the core's environment, not this shell's, so what the watcher reads is passed in the command.
wenv=("PADDOCK_SECRETARY_NAME=$name")
for v in PADDOCK_STATE_DIR XDG_STATE_HOME PADDOCK_WATCH_N PADDOCK_WATCH_INTERVAL PADDOCK_POWERSHELL; do
  [ -z "${!v:-}" ] || wenv+=("$v=${!v}")
done
wname=${PADDOCK_WATCHER_NAME:-watcher}
wj=$(hc get --json "$wname" 2>/dev/null | tr -d '\n')
if printf '%s' "$wj" | grep -Eq '"state": *"finished"' && printf '%s' "$wj" | grep -Eq '"paddock_role": *"watcher"'; then
  hc rm "$wname" >/dev/null 2>&1 || echo "org-start: warning: hc rm $wname failed (the finished watcher terminal)" >&2
fi
if hc get "$wname" >/dev/null 2>&1; then
  echo "org-start: $wname already exists; not starting another"
elif hc run --bg --keep --no-notify --name "$wname" --label paddock_role=watcher --cwd "$root" -- env "${wenv[@]}" bash "$root/skills/org-watch/scripts/org-watch.sh" >/dev/null; then
  echo "org-start: started $wname (tells you outside the window; org-down ends it)"
else
  echo "org-start: warning: hc run failed for $wname; nobody will be told outside the window" >&2
fi

# 4. Readiness: hc get shows a status object.
# a new root shows Claude Code's folder-trust dialog and no status. Q13 (a) allows
# answering it once for the secretary's own root (never for a worktree): read, down, read again,
# enter only with the cursor on "Yes" (the default is "No, exit"). The first message did not arrive:
# hc sends the template body plus a blank line and the task, so both are sent again. Only for a
# secretary this run started in $root: an existing one may sit in another folder.
trusted=; i=0
while [ "$i" -lt "$tries" ]; do
  if hc get --json "$name" 2>/dev/null | grep -Eq '"status": *\{'; then
    if [ -n "$trusted" ]; then
      body=$(awk 'n >= 2 { print; next } /^---$/ { n++ }' "$templates/secretary.md")
      [ -n "$body" ] && hc send "$name" "$body${task:+

$task}" >/dev/null 2>&1 \
        || die 7 "answered the folder-trust dialog but could not send the first message (the body of $templates/secretary.md${task:+ and '$task'}); send it by hand with hc send $name"
    fi
    echo "org-start: ready. $name reports a status; the mod is in $mods/org-agents"
    exit 0
  fi
  if [ -n "$started" ] && [ -z "$trusted" ] && hc read "$name" 2>/dev/null | grep -Eq 'Quick safety check|Yes, I trust this folder'; then
    hc keys "$name" down >/dev/null 2>&1; sleep 1
    hc read "$name" 2>/dev/null | grep -q '❯.*Yes, I trust this folder' \
      || die 7 "$name shows the folder-trust dialog and the cursor did not reach 'Yes, I trust this folder'; nothing confirmed. Look at 'hc read $name'"
    hc keys "$name" enter >/dev/null 2>&1
    trusted=1; i=0; echo "org-start: accepted the folder-trust dialog for $root on $name"
    continue
  fi
  i=$((i + 1)); sleep 1
done
# say why. The terminal's exit state and its last output line, from hc get --json / hc read.
info=$(hc get --json "$name" 2>/dev/null)
code=$(printf '%s' "$info" | sed -n 's/.*"exit_code": *\(-\{0,1\}[0-9][0-9]*\).*/\1/p' | head -n 1)
last=$(hc read "$name" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 1)
why=
if [ -n "$code" ]; then why=" The terminal ended with exit code $code."; fi
if [ -n "$last" ]; then why="$why Its last line: $last"; fi
# Exit 127 or a "claude ... not found" line: the launch command (the template runs claude) was not on the terminal's PATH.
if [ "$code" = 127 ] || printf '%s' "$last" | grep -qi 'claude.*not found'; then
  why="$why. claude was not found: the secretary template (secretary.md in $templates) starts claude, and it is not on the PATH of the core's terminals; install it or fix that PATH"
fi
die 7 "secretary has no status after ${tries}s.$why Look at 'hc get $name' and 'hc read $name'"
