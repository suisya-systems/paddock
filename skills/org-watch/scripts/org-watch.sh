#!/usr/bin/env bash
# org-watch: tells the person, outside the window, about a waiting approval card, the secretary's
# incident and a terminal that never reported a status. Run by org-start as a kept terminal named
# watcher. Needs only bash, awk, sed, grep, coreutils and hc. See ../SKILL.md.
set -u

usage() {
  cat <<'USAGE'
Usage: org-watch.sh [--once] [-h|--help]

Polls the core and tells the person (a desktop toast with sound, else a terminal bell):
  - once per approval card waiting in org-state.approvals (task and question),
  - when a worker is blocked and the secretary's status, turn count and screen have not
    changed for N minutes (Q3),
  - when a terminal reported no status N minutes after it was created.
Each item is told once, and again after N minutes if it is still waiting.
It only reads (hc ls, get, read and the org-state document); it never types into a terminal.
  --once  one pass, then exit (0 done, 5 core unreachable); without it, loop until killed
Environment: PADDOCK_WATCH_N (minutes, default 10), PADDOCK_WATCH_INTERVAL (seconds, default 30),
PADDOCK_SECRETARY_NAME (default secretary), PADDOCK_POWERSHELL (powershell.exe path),
PADDOCK_STATE_DIR (the ledger is in its watcher folder).

Exit codes: 0 done, 2 bad argument, 3 hc not found, 5 core unreachable (--once).
USAGE
}

once=
for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --once) once=1 ;;
    *) echo "org-watch: unknown argument: $a" >&2; usage >&2; exit 2 ;;
  esac
done

die() { code=$1; shift; echo "org-watch: $*" >&2; exit "$code"; }
command -v hc >/dev/null 2>&1 || die 3 "hc not found on PATH (install herdr-core)"
here=$(dirname "${BASH_SOURCE[0]}")
. "$here/../../org-suspend/scripts/lib.sh"   # term_json, term_status, paddock_terminals
org=${PADDOCK_ORG:-$here/../../../scripts/org}
sec=${PADDOCK_SECRETARY_NAME:-secretary}
N=${PADDOCK_WATCH_N:-10}; limit=$((N * 60))
wdir=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}/watcher
mkdir -p "$wdir" || die 5 "cannot create $wdir"
told=$wdir/told; seen=$wdir/secretary.seen
tab=$(printf '\t')

# --- channel: a toast with sound, else notify-send, else the bell (the floor) ---
# A kept terminal's PATH can lack /mnt/c (measured), so the default Windows path is tried as well.
ps_exe() {
  [ -z "${PADDOCK_POWERSHELL:-}" ] || { echo "$PADDOCK_POWERSHELL"; return; }
  command -v powershell.exe 2>/dev/null && return
  local p=/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe
  [ -x "$p" ] && echo "$p"
}
# The script goes in on stdin and the text in environment variables (WSLENV), so nothing the
# person's tasks wrote is ever quoted into a command line.
PS_TOAST='$ErrorActionPreference = "Stop"
[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
$t = [Security.SecurityElement]::Escape($env:PADDOCK_TOAST_TITLE)
$b = [Security.SecurityElement]::Escape($env:PADDOCK_TOAST_BODY)
$x = New-Object Windows.Data.Xml.Dom.XmlDocument
$x.LoadXml("<toast><visual><binding template=`"ToastText02`"><text id=`"1`">$t</text><text id=`"2`">$b</text></binding></visual><audio src=`"ms-winsoundevent:Notification.Default`"/></toast>")
$app = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show([Windows.UI.Notifications.ToastNotification]::new($x))'
notify() { # notify <title> <body>
  local ps
  printf 'org-watch: %s - %s\n' "$1" "$2"
  if ps=$(ps_exe) && [ -n "$ps" ]; then
    printf '%s\n' "$PS_TOAST" | PADDOCK_TOAST_TITLE=$1 PADDOCK_TOAST_BODY=$2 \
      WSLENV="${WSLENV:+$WSLENV:}PADDOCK_TOAST_TITLE:PADDOCK_TOAST_BODY" \
      "$ps" -NoProfile -NonInteractive -Command - >/dev/null 2>&1 && return 0
  fi
  if command -v notify-send >/dev/null 2>&1; then
    notify-send --app-name=paddock --hint=string:sound-name:message-new-instant -- "$1" "$2" >/dev/null 2>&1 && return 0
  fi
  printf '\a'
}

# --- ledger: "key<TAB>epoch" of the last telling; one file for every kind of item ---
due() { # due <key>: 0 when never told, or last told N minutes ago or more
  local last; last=$(K=$1 awk -F'\t' '$1 == ENVIRON["K"] { l = $2 } END { print l }' "$told" 2>/dev/null)
  [ -z "$last" ] || [ $((now - last)) -ge "$limit" ]
}
mark() { # mark <key>
  { K=$1 awk -F'\t' '$1 != ENVIRON["K"]' "$told" 2>/dev/null; printf '%s\t%s\n' "$1" "$now"; } > "$told.new" && mv "$told.new" "$told"
}
tell() { # tell <key> <title> <body>: only if due; the key is kept active either way
  active="$active$1
"
  due "$1" || return 0
  notify "$2" "$3"; mark "$1"
}

# approval_lines <org-state doc>: "id<TAB>task_id<TAB>question" per entry of the top-level
# approvals array. A scanner that knows strings, escapes and nesting: a word like "approvals"
# or a brace inside a question or a task is data.
approval_lines() {
  printf '%s' "$1" | tr -d '\n' | awk '{
    n = 0; s = $0; L = length(s)
    for (i = 1; i <= L; i++) { c = substr(s, i, 1)
      if (c == "\"") { v = ""; for (i++; i <= L; i++) { c = substr(s, i, 1)
          if (c == "\\") { i++; c = substr(s, i, 1); if (c ~ /[ntr]/) c = " "; v = v c }
          else if (c == "\"") break; else v = v c }
        n++; tt[n] = "S"; tv[n] = v }
      else if (c ~ /[{}:\[\]]/) { n++; tt[n] = c; tv[n] = c } }
    d = 0; inapp = 0
    for (i = 1; i <= n; i++) { t = tt[i]
      if (t == "{" || t == "[") { d++; if (inapp && t == "{" && d == 3) { id = ""; tk = ""; qu = "" } }
      else if (t == "}" || t == "]") {
        if (inapp && t == "}" && d == 3) printf "%s\t%s\t%s\n", id, tk, qu
        if (inapp && t == "]" && d == 2) inapp = 0
        d-- }
      else if (t == "S" && !inapp && d == 1 && tv[i] == "approvals" && tt[i+1] == ":" && tt[i+2] == "[") inapp = 1
      else if (t == "S" && inapp && d == 3 && tt[i+1] == ":" && tt[i+2] == "S") {
        if (tv[i] == "id") id = tv[i+2]; else if (tv[i] == "task_id") tk = tv[i+2]; else if (tv[i] == "question") qu = tv[i+2] } }
  }'
}
num() { printf '%s' "$1" | grep -o "\"$2\": *[0-9][0-9]*" | head -1 | sed 's/.*: *//'; }

pass() {
  now=${PADDOCK_WATCH_NOW:-$(date +%s)}; active=; local prune=1
  local terms n j doc cards id tk qu ms cr fp since
  terms=$(paddock_terminals) || { echo "org-watch: cannot reach the core (hc ls failed)" >&2; return 5; }

  # 1. approval cards (org-state.approvals), once per card
  if doc=$("$BASH" "$org" --as watcher doc get org-state 2>/dev/null); then
    cards=$(approval_lines "$doc")
    while IFS="$tab" read -r id tk qu; do
      [ -n "$id" ] || continue
      tell "approval:$id" "Approval waiting: ${tk:-?}" "${qu:0:200}"
    done <<< "$cards"
  else
    prune=
  fi

  # 2. Q3's incident: a worker blocked, and the secretary's status, turn and screen unchanged for N minutes
  if j=$(term_json "$sec") && printf '%s' "$j" | grep -Eq '"status": *\{'; then
    ms=$(num "$j" status_ms)
    fp="$(num "$j" turn):${ms}:$(hc read --lines 0 "$sec" 2>/dev/null | cksum | cut -d' ' -f1)"
    # ponytail: "unchanged" is what this watcher saw, so one started mid-freeze waits N minutes more
    # before telling; a longer memory would need the core's events.
    if [ "$(cut -f1 "$seen" 2>/dev/null)" != "$fp" ]; then printf '%s\t%s\n' "$fp" "$now" > "$seen"; fi
    since=$(cut -f2 "$seen")
    if [ $((now - since)) -ge "$limit" ] && [ $((now - ${ms:-0} / 1000)) -ge "$limit" ]; then
      for n in $(printf '%s\n' "$terms" | cut -f1); do
        [ "$(term_status "$n")" = blocked ] || continue
        tell "incident:$sec" "Secretary not moving" "A worker is blocked and the secretary has not changed for $N minutes."
        break
      done
    fi
  else
    rm -f "$seen"
  fi

  # 3. a terminal that never reported a status N minutes after it was created
  for n in $(printf '%s\n' "$terms" | cut -f1) "$sec"; do
    j=$(term_json "$n") || continue
    printf '%s' "$j" | grep -Eq '"status": *\{' && continue
    cr=$(num "$j" created_ms); [ -n "$cr" ] || continue
    [ $((now - cr / 1000)) -ge "$limit" ] || continue
    tell "nostatus:$n" "No status from $n" "Terminal $n has reported no status for $N minutes (a startup dialog, or the agent never started)."
  done

  # Forget what is no longer waiting, so it is told afresh if it comes back.
  if [ -n "$prune" ] && [ -f "$told" ]; then
    A=$active awk -F'\t' 'BEGIN { n = split(ENVIRON["A"], a, "\n"); for (i = 1; i <= n; i++) k[a[i]] = 1 } $1 in k' "$told" > "$told.new" && mv "$told.new" "$told"
  fi
  return 0
}

if [ -n "$once" ]; then pass; exit $?; fi
while :; do pass || true; sleep "${PADDOCK_WATCH_INTERVAL:-30}"; done
