#!/usr/bin/env bash
# org-watch: tells the person, outside the window, about a waiting approval card, the secretary's
# incident and a terminal that never reported a status. Since decision 0013 (stage 1) it also writes
# worker events into the secretary's mailbox as watcher, wakes an idle or done secretary or worker
# that has unread mail with one constant line, and watches CI for each ci_requested record
# (ci-watch.sh). Run by org-start as a kept terminal named watcher. Needs bash, awk, sed, grep,
# coreutils and hc; gh for the CI watch. See ../SKILL.md.
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
Decision 0013: worker events (blocked, done with no report, gone, no status) become one line
each in the secretary's mailbox, written as watcher; a background ci-watch.sh per open
ci_requested record writes ci_completed or ci_watch_failed and a mailbox line. The secretary
and each worker with unread mail are woken with one constant line, only when idle or done,
never over typed input, at most once per unread batch per PADDOCK_WATCH_WAKE seconds; each
wake, skip and mailbox line is logged to watcher/woke.
  --once  one pass, then exit (0 done, 5 core unreachable); without it, loop until killed
Environment: PADDOCK_WATCH_N (minutes, default 10), PADDOCK_WATCH_INTERVAL (seconds, default 30),
PADDOCK_SECRETARY_NAME (default secretary), PADDOCK_POWERSHELL (powershell.exe path),
PADDOCK_STATE_DIR (the ledger is in its watcher folder), PADDOCK_WATCH_WAKE (seconds between
wakes for one unread batch, default 60).

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
told=$wdir/told; seen=$wdir/secretary.seen; woke=$wdir/woke; wakes=$wdir/wake; cidir=$wdir/ci
WAKE=${PADDOCK_WATCH_WAKE:-60}
mkdir -p "$cidir" || die 5 "cannot create $cidir"
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
$n = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app)
if ($n.Setting -ne "Enabled") { exit 3 }
$n.Show([Windows.UI.Notifications.ToastNotification]::new($x))'
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

# --- decision 0013: mailbox lines, wakes and CI watches ---
# wlog <kind> <target> <key> <status> <input> <rc>: one line on the terminal and in watcher/woke
# (kind mail, wake or skip; rc "rate" for a skip by the rate limit, "-" when nothing was sent)
wlog() {
  printf 'org-watch: %s %s %s status=%s input=%s rc=%s\n' "$1" "$2" "$3" "$4" "$5" "$6"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$1" "$2" "$3" "$4" "$5" "$6" >> "$woke"
}
# mail_once <key> <text>: one line to the secretary's mailbox as watcher, once while the item holds
mail_once() {
  active="$active$1
"
  K=$1 awk -F'\t' '$1 == ENVIRON["K"] { f = 1 } END { exit !f }' "$told" 2>/dev/null && return 0
  local rc; "$BASH" "$org" --as watcher send_message secretary "$2" >/dev/null 2>&1; rc=$?
  wlog mail secretary "$1" - - "$rc"
  [ "$rc" -ne 0 ] || mark "$1"
}
# bare: each line with NBSP made a space and the leading spaces and box (│ or |) cut.
# Alternation, not a bracket, for the multibyte box and marker: the kept terminal may run in the C locale.
nbsp=$(printf '\302\240')
bare() { sed -E "s/$nbsp/ /g; s/^([[:space:]]|│|\|)*//"; }
# prompt_line <screen>: the last line whose first mark (after bare) is the prompt marker ❯ or >.
prompt_line() { printf '%s\n' "$1" | bare | grep -E '^(❯|>)' | tail -1; }
# typed <line>: the prompt line holds input after the marker (open question 3 of 0013).
# ponytail: measured on the host (#396): the prompt is "❯" + NBSP + input, between two rule lines,
# above the status bar, so the last screen line is not it; a newer Claude Code screen may move it again.
typed() { printf '%s\n' "$1" | bare | grep -Eq '^(❯|>)[[:space:]]+[^[:space:]│|]'; }
# wake <terminal> <org id>: the one constant line when <org id> has unread mail and <terminal> is
# idle or done, its screen shows a prompt line with no typed input, and this batch was not woken in WAKE s.
# A batch is the highest unread seq per sender.
wake() {
  local t=$1 oid=$2 peek batch last st line rc msg
  peek=$("$BASH" "$org" --as "$oid" check_messages --peek 2>/dev/null) || return 0
  batch=$(printf '%s\n' "$peek" | sed -n 's/^\[\([a-z0-9_-]*\)#\([0-9]*\) .*/\1 \2/p' \
    | awk '{ if ($2 + 0 > m[$1] + 0) m[$1] = $2 + 0 } END { for (s in m) print s "#" m[s] }' | sort | tr '\n' ',')
  batch=${batch%,}; [ -n "$batch" ] || return 0
  last=$(T=$t B=$batch awk -F'\t' '$1 == ENVIRON["T"] && $2 == ENVIRON["B"] { l = $3 } END { print l }' "$wakes" 2>/dev/null)
  if [ -n "$last" ] && [ $((now - last)) -lt "$WAKE" ]; then wlog skip "$t" "$batch" - - rate; return 0; fi
  st=$(term_status "$t") || st=not_found
  case "$st" in idle|done) ;; *) wlog skip "$t" "$batch" "$st" - -; return 0 ;; esac
  # a screen that cannot be read is not a screen without input: no wake this pass
  line=$(hc read "$t" 2>/dev/null) || { wlog skip "$t" "$batch" "$st" unreadable -; return 0; }
  # no prompt line found is not a prompt without input either
  line=$(prompt_line "$line"); [ -n "$line" ] || { wlog skip "$t" "$batch" "$st" noprompt -; return 0; }
  if typed "$line"; then wlog skip "$t" "$batch" "$st" yes -; return 0; fi
  if [ "$oid" = secretary ]; then msg="You have mail: run bash scripts/org --as secretary check_messages and act on it."
  else msg="You have mail: run bash \"\$PADDOCK_ORG\" --as $oid check_messages and act on it."; fi
  # hc has no --if done: done was read just above, so it is a plain send
  if [ "$st" = idle ]; then hc send --if idle "$t" "$msg" >/dev/null 2>&1; rc=$?
  else hc send "$t" "$msg" >/dev/null 2>&1; rc=$?; fi
  wlog wake "$t" "$batch" "$st" no "$rc"
  [ "$rc" -eq 0 ] || return 0
  { T=$t awk -F'\t' '$1 != ENVIRON["T"]' "$wakes" 2>/dev/null; printf '%s\t%s\t%s\n' "$t" "$batch" "$now"; } > "$wakes.new" && mv "$wakes.new" "$wakes"
}
# ci_lines: "open|super<TAB>pr<TAB>sha<TAB>repo<TAB>task" per ci_requested of the secretary with no
# ci_completed or ci_watch_failed of the watcher at or after it for the same repo, pr and sha (stage 1:
# the skill's own ci_completed does not count). open: the newest request of its repo and PR; super:
# an older one with another head. This and the last calendar month of the history.
ci_lines() {
  local ev=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}/events d cur y m
  # this calendar month and the last, as scripts/org's window (own_files makes next month's folder early)
  cur=$(date -u -d "@$now" +%Y-%m 2>/dev/null) || cur=$(date -u +%Y-%m)
  y=${cur%-*}; m=$((10#${cur#*-} - 1)); [ "$m" -gt 0 ] || { m=12; y=$((10#$y - 1)); }
  for d in "$ev/$(printf '%04d-%02d' "$((10#$y))" "$m")" "$ev/$cur"; do
    [ ! -f "$d/secretary.jsonl" ] || grep -h '"kind":"ci_requested"' "$d/secretary.jsonl" | sed 's/^/R /'
    [ ! -f "$d/watcher.jsonl" ] || grep -hE '"kind":"(ci_completed|ci_watch_failed)"' "$d/watcher.jsonl" | sed 's/^/D /'
  done | awk '
    function v(k) { if (match($0, "\"" k "\":\"[^\"]*\"")) return substr($0, RSTART + length(k) + 4, RLENGTH - length(k) - 5)
                    if (match($0, "\"" k "\":[0-9]+")) return substr($0, RSTART + length(k) + 3, RLENGTH - length(k) - 3); return "" }
    $1 == "R" { n++; ts[n] = v("ts"); pr[n] = v("pr"); sh[n] = v("sha"); rp[n] = v("repo"); tk[n] = v("task_id")
                p = rp[n] " " pr[n]; if (ts[n] >= nt[p]) { nt[p] = ts[n]; ns[p] = sh[n] } next }
    $1 == "D" { k = v("repo") " " v("pr") " " v("sha"); t = v("ts"); if (t > dt[k]) dt[k] = t }
    END { for (i = n; i >= 1; i--) { p = rp[i] " " pr[i]; k = p " " sh[i]; if ((k in dt) && dt[k] >= ts[i]) continue
            if (k in seen) continue; seen[k] = 1
            printf "%s\t%s\t%s\t%s\t%s\n", (ns[p] == sh[i] ? "open" : "super"), pr[i], sh[i], rp[i], tk[i] } }'
}
# ci_alive <pid>: that pid runs ci-watch.sh (after a restart a recorded pid may be another process)
ci_alive() { kill -0 "$1" 2>/dev/null && tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q 'ci-watch\.sh'; }
# ckey <repo> <pr>: the file key of one PR's watch, <owner>_<name>-<pr>
ckey() { printf '%s-%s' "${1//\//_}" "$2"; }
ci_run() { # ci_run <bg|fg> <reason|-> <pr> <sha> <repo> <task>: ci-watch.sh, its output in its log
  local log ta=() fa=()
  log=$cidir/$(ckey "$5" "$3")-${4:0:7}.log
  [ -z "$6" ] || ta=(--task "$6"); [ "$2" = - ] || fa=(--fail "$2")
  if [ "$1" = fg ]; then "$BASH" "$here/ci-watch.sh" --pr "$3" --sha "$4" --repo "$5" "${ta[@]}" "${fa[@]}" >> "$log" 2>&1; return; fi
  "$BASH" "$here/ci-watch.sh" --pr "$3" --sha "$4" --repo "$5" "${ta[@]}" </dev/null >> "$log" 2>&1 &
  printf '%s %s %s %s\n' "$!" "$4" "$5" "$3" > "$cidir/$(ckey "$5" "$3").pid"
}
ci_pass() {
  local pf pid psha prepo ppr dead= lines kind pr sha repo tk
  # first the watches that ended, then the records: a line written as a watch ended is seen
  for pf in "$cidir"/*.pid; do
    [ -f "$pf" ] || continue
    read -r pid psha prepo ppr < "$pf"
    ci_alive "$pid" || dead="$dead$pf$tab$psha$tab$prepo$tab$ppr
"
  done
  lines=$(ci_lines)
  # a watch gone with no line of its own (SIGKILL, no trap ran): vanished
  while IFS="$tab" read -r pf psha prepo ppr; do  # tabs: the state path may hold spaces
    [ -n "$pf" ] || continue
    rm -f "${pf:?}"
    IFS="$tab" read -r kind pr sha repo tk <<< "$(printf '%s\n' "$lines" | awk -F'\t' -v p="$ppr" -v s="$psha" -v r="$prepo" '$2 == p && $3 == s && $4 == r' | head -1)"
    [ -n "$sha" ] || continue
    ci_run fg vanished "$pr" "$sha" "$repo" "$tk"
    lines=$(ci_lines)
  done <<< "$dead"
  while IFS="$tab" read -r kind pr sha repo tk; do
    [ -n "$pr" ] || continue
    pf=$cidir/$(ckey "$repo" "$pr").pid; psha=; pid=; [ ! -f "$pf" ] || read -r pid psha _ < "$pf"
    if [ "$kind" = super ]; then
      # a newer head of the same PR: its live watch is ended (USR1, it writes superseded), else the line is written here
      if [ "$psha" = "$sha" ] && ci_alive "$pid"; then kill -USR1 "$pid" 2>/dev/null
      else ci_run fg superseded "$pr" "$sha" "$repo" "$tk"; fi
      continue
    fi
    [ -z "$pid" ] || continue   # one watch per repo and PR; a superseded one clears its pid file as it ends
    ci_run bg - "$pr" "$sha" "$repo" "$tk"
  done <<< "$lines"
}
# listed <json> <member>: the task ids of a work_check member, space separated
listed() { printf '%s' "$1" | sed -n "s/.*\"$2\":\[\([^]]*\)\].*/\1/p" | tr -d '"' | tr ',' ' '; }

pass() {
  now=${PADDOCK_WATCH_NOW:-$(date +%s)}; active=; local prune=1
  local terms n j doc cards id tk qu ms cr fp since wc_out
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
    [ "$n" = "$sec" ] || mail_once "mail:nostatus:$n" "$n has reported no status for $N minutes"
  done

  # 4. decision 0013: worker events as lines in the secretary's mailbox, once per item
  while IFS="$tab" read -r n tk; do
    [ -n "$n" ] || continue
    [ "$(term_status "$n")" != blocked ] || mail_once "mail:blocked:$n" "$n is blocked"
  done <<< "$terms"
  wc_out=$("$BASH" "$org" --as watcher work_check 2>/dev/null) || wc_out='{"watch_error":""}'
  case "$wc_out" in *'"watch_error"'*|*'"unreadable"'*) prune= ;; esac
  for tk in $(listed "$wc_out" unreported); do mail_once "mail:unreported:w-$tk" "w-$tk is done and sent no report"; done
  for tk in $(listed "$wc_out" gone); do mail_once "mail:gone:w-$tk" "w-$tk has no terminal and sent no done report"; done

  # 5. CI: one background ci-watch.sh per open ci_requested record
  ci_pass

  # 6. the wake: the secretary and each live worker with unread mail
  wake "$sec" secretary
  while IFS="$tab" read -r n tk; do
    [ -n "$n" ] || continue
    wake "$n" "w-$tk"
  done <<< "$terms"

  # Forget what is no longer waiting, so it is told afresh if it comes back.
  if [ -n "$prune" ] && [ -f "$told" ]; then
    A=$active awk -F'\t' 'BEGIN { n = split(ENVIRON["A"], a, "\n"); for (i = 1; i <= n; i++) k[a[i]] = 1 } $1 in k' "$told" > "$told.new" && mv "$told.new" "$told"
  fi
  return 0
}

if [ -n "$once" ]; then pass; exit $?; fi
while :; do pass || true; sleep "${PADDOCK_WATCH_INTERVAL:-30}"; done
