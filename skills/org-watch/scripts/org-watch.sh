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
ci_requested record writes ci_completed or ci_watch_failed and a mailbox line. N minutes after
a green ci_completed whose task has no card and is still in org-state.work, and N minutes after a
card's ANSWER reached the person's history while the card is still up, one line each.
The secretary and each worker with unread mail are woken with one constant line, only when idle or done,
never over typed input, at most once per unread batch per PADDOCK_WATCH_WAKE seconds; each
wake, skip and mailbox line is logged to watcher/woke.
When watcher/reload-plugins exists (org-start leaves it after a SKILL.md landing), /reload-plugins
is typed into the idle secretary once; a Reloaded: line clears it, none in N minutes tells the person.
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
told=$wdir/told; seen=$wdir/secretary.seen; reload=$wdir/reload-plugins; woke=$wdir/woke; wakes=$wdir/wake; cidir=$wdir/ci
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

# approval_lines <org-state doc> [array]: "id<TAB>task_id<TAB>question" per entry of the top-level
# approvals array (or of [array], such as work). A scanner that knows strings, escapes and nesting:
# a word like "approvals" or a brace inside a question or a task is data.
approval_lines() {
  printf '%s' "$1" | tr -d '\n' | A=${2:-approvals} awk '{
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
      else if (t == "S" && !inapp && d == 1 && tv[i] == ENVIRON["A"] && tt[i+1] == ":" && tt[i+2] == "[") inapp = 1
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
# ponytail: measured on the host: the prompt is "❯" + NBSP + input, between two rule lines,
# above the status bar, so the last screen line is not it; a newer Claude Code screen may move it again.
typed() { printf '%s\n' "$1" | bare | grep -Eq '^(❯|>)[[:space:]]+[^[:space:]│|]'; }
# jstate <json>: term_status's state of a get already read (term_json answered from it in a subshell,
# so the parse stays lib.sh's)
jstate() { local J=$1; ( term_json() { printf '%s' "$J"; }; term_status - ); }
# sendline <terminal> <key> <kind> <text>: types <text> into <terminal> only when it is idle or done and
# its screen shows a prompt line with no typed input; logs the send as <kind> (or the skip) with <key>.
# 0 when the text was delivered.
sendline() {
  local t=$1 key=$2 kind=$3 msg=$4 st line rc j j2 st2
  j=$(term_json "$t") && st=$(jstate "$j") || st=not_found
  case "$st" in idle|done) ;; *) wlog skip "$t" "$key" "$st" - -; return 1 ;; esac
  # a screen that cannot be read is not a screen without input: no send this pass
  line=$(hc read "$t" 2>/dev/null) || { wlog skip "$t" "$key" "$st" unreadable -; return 1; }
  # no prompt line found is not a prompt without input either
  line=$(prompt_line "$line"); [ -n "$line" ] || { wlog skip "$t" "$key" "$st" noprompt -; return 1; }
  if typed "$line"; then wlog skip "$t" "$key" "$st" yes -; return 1; fi
  # hc has no --if done, so done is a plain send, after a last get: still done, same turn and
  # status_ms as the first read, else skip (moved) and retry next pass.
  # ponytail: a turn that starts between this get and the send's paste is still typed into.
  if [ "$st" = idle ]; then hc send --if idle "$t" "$msg" >/dev/null 2>&1; rc=$?
  else
    j2=$(term_json "$t") && st2=$(jstate "$j2") || st2=not_found
    if [ "$st2" != done ] || [ "$(num "$j2" turn):$(num "$j2" status_ms)" != "$(num "$j" turn):$(num "$j" status_ms)" ]; then
      wlog skip "$t" "$key" "$st2" moved -; return 1
    fi
    hc send "$t" "$msg" >/dev/null 2>&1; rc=$?
  fi
  wlog "$kind" "$t" "$key" "$st" no "$rc"
  return "$rc"
}
# wake <terminal> <org id>: the one constant line when <org id> has unread mail, by sendline, unless
# this batch was woken in WAKE s. A batch is the highest unread seq per sender.
wake() {
  local t=$1 oid=$2 peek batch last msg
  peek=$("$BASH" "$org" --as "$oid" check_messages --peek 2>/dev/null) || return 0
  batch=$(printf '%s\n' "$peek" | sed -n 's/^\[\([a-z0-9_-]*\)#\([0-9]*\) .*/\1 \2/p' \
    | awk '{ if ($2 + 0 > m[$1] + 0) m[$1] = $2 + 0 } END { for (s in m) print s "#" m[s] }' | sort | tr '\n' ',')
  batch=${batch%,}; [ -n "$batch" ] || return 0
  last=$(T=$t B=$batch awk -F'\t' '$1 == ENVIRON["T"] && $2 == ENVIRON["B"] { l = $3 } END { print l }' "$wakes" 2>/dev/null)
  if [ -n "$last" ] && [ $((now - last)) -lt "$WAKE" ]; then wlog skip "$t" "$batch" - - rate; return 0; fi
  if [ "$oid" = secretary ]; then msg="You have mail: run bash \"\$PADDOCK_HOME/scripts/org\" --as secretary check_messages and act on it."
  else msg="You have mail: run bash \"\$PADDOCK_ORG\" --as $oid check_messages and act on it."; fi
  sendline "$t" "$batch" wake "$msg" || return 0
  { T=$t awk -F'\t' '$1 != ENVIRON["T"]' "$wakes" 2>/dev/null; printf '%s\t%s\t%s\n' "$t" "$batch" "$now"; } > "$wakes.new" && mv "$wakes.new" "$wakes"
}
# reload_pass: org-start writes a request id into watcher/reload-plugins when a landing changed a
# SKILL.md. A request not yet in watcher/reload-sent ("<epoch> <id>"): type /reload-plugins into the
# secretary once (sendline) and record it there. A sent request: a "Reloaded:" line below the last
# /reload-plugins on the screen removes the marker (only if it still holds that id: a newer landing
# is a new request); none N minutes after the send tells the person (as a stuck card), every N minutes.
# 0 when it typed this pass (the secretary is then not woken in the same pass).
reload_pass() {
  local id sid sent scr
  [ -f "$reload" ] || { rm -f "$reload-sent"; return 1; }
  id=$(cat "$reload" 2>/dev/null)
  read -r sent sid < "$reload-sent" 2>/dev/null || sent= sid=
  if [ "$sid" != "$id" ] || [ -z "$sent" ]; then
    sendline "$sec" reload-plugins reload /reload-plugins || return 1
    printf '%s %s\n' "$now" "$id" > "$reload-sent"; return 0
  fi
  # ponytail: the anchor is the last /reload-plugins on screen; if this send's echo has not shown by the
  # next pass, an older pair still visible confirms it. A per-send screen baseline if that is seen.
  if scr=$(hc read "$sec" 2>/dev/null) && printf '%s\n' "$scr" \
      | awk '/\/reload-plugins/ { r = NR; ok = 0 } r && NR > r && /Reloaded:/ { ok = 1 } END { exit !ok }'; then
    # ponytail: a landing between this read and the rm is lost; a lock shared with org-start if it bites
    [ "$(cat "$reload" 2>/dev/null)" != "$id" ] || rm -f "$reload" "$reload-sent"
    wlog reloaded "$sec" reload-plugins - - -; return 1
  fi
  [ $((now - sent)) -lt "$limit" ] && { active="${active}reload:$sec
"; return 1; }
  tell "reload:$sec" "Plugin reload not confirmed" "/reload-plugins was typed into $sec $N minutes ago and no Reloaded: line shows; type /reload-plugins into it."
  return 1
}
# ci_lines: "open|super<TAB>pr<TAB>sha<TAB>repo<TAB>task" per ci_requested of the secretary with no
# ci_completed or ci_watch_failed of the watcher at or after it for the same repo, pr and sha (stage 1:
# the skill's own ci_completed does not count). open: the newest request of its repo and PR; super:
# an older one with another head. This and the last calendar month of the history.
# hist <org id> <ERE>: the lines of <org id>'s history that match, this calendar month and the
# last, as scripts/org's window (own_files makes next month's folder early)
hist() {
  local ev=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}/events d cur y m
  cur=$(date -u -d "@$now" +%Y-%m 2>/dev/null) || cur=$(date -u +%Y-%m)
  y=${cur%-*}; m=$((10#${cur#*-} - 1)); [ "$m" -gt 0 ] || { m=12; y=$((10#$y - 1)); }
  for d in "$ev/$(printf '%04d-%02d' "$((10#$y))" "$m")" "$ev/$cur"; do
    [ ! -f "$d/$1.jsonl" ] || grep -hE "$2" "$d/$1.jsonl"
  done
}
# AWK_V: v(k), the string or number value of key k on the line
AWK_V='function v(k) { if (match($0, "\"" k "\":\"[^\"]*\"")) return substr($0, RSTART + length(k) + 4, RLENGTH - length(k) - 5)
                    if (match($0, "\"" k "\":[0-9]+")) return substr($0, RSTART + length(k) + 3, RLENGTH - length(k) - 3); return "" }'
# ci_hist: the secretary's ci_requested lines as "R <line>", the watcher's ci_completed and
# ci_watch_failed as "D <line>"
ci_hist() {
  hist secretary '"kind":"ci_requested"' | sed 's/^/R /'
  hist watcher '"kind":"(ci_completed|ci_watch_failed)"' | sed 's/^/D /'
}
ci_lines() {
  ci_hist | awk "$AWK_V"'
    $1 == "R" { n++; ts[n] = v("ts"); pr[n] = v("pr"); sh[n] = v("sha"); rp[n] = v("repo"); tk[n] = v("task_id")
                p = rp[n] " " pr[n]; if (ts[n] >= nt[p]) { nt[p] = ts[n]; ns[p] = sh[n] } next }
    $1 == "D" { k = v("repo") " " v("pr") " " v("sha"); t = v("ts"); if (t > dt[k]) dt[k] = t }
    END { for (i = n; i >= 1; i--) { p = rp[i] " " pr[i]; k = p " " sh[i]; if ((k in dt) && dt[k] >= ts[i]) continue
            if (k in seen) continue; seen[k] = 1
            printf "%s\t%s\t%s\t%s\t%s\n", (ns[p] == sh[i] ? "open" : "super"), pr[i], sh[i], rp[i], tk[i] } }'
}
# green_lines: "pr<TAB>sha<TAB>repo<TAB>task<TAB>ts" per PR whose newest requested head's latest
# watcher result at or after that request is a ci_completed success (ts is that line's)
green_lines() {
  ci_hist | awk "$AWK_V"'
    $1 == "R" { p = v("repo") " " v("pr"); if (v("ts") >= nt[p]) { nt[p] = v("ts"); ns[p] = v("sha"); nk[p] = v("task_id") } next }
    $1 == "D" { k = v("repo") " " v("pr") " " v("sha"); if (v("ts") >= dt[k]) { dt[k] = v("ts"); ok[k] = /"conclusion":"success"/ } }
    END { for (p in nt) { k = p " " ns[p]; if (!ok[k] || dt[k] < nt[p]) continue; split(p, a, " ")
            printf "%s\t%s\t%s\t%s\t%s\n", a[2], ns[p], a[1], nk[p], dt[k] } }'
}
# answer_lines: "approval id<TAB>ts of its first answer" per ANSWER line in the person's history
answer_lines() {
  hist person '"text":"ANSWER ' | awk "$AWK_V"'
    match($0, /"text":"ANSWER [^ ";\\]+/) { i = substr($0, RSTART + 15, RLENGTH - 15); t = v("ts"); if (!(i in f) || t < f[i]) f[i] = t }
    END { for (i in f) printf "%s\t%s\n", i, f[i] }'
}
# older <iso ts>: that time is N minutes ago or more
older() { local t; t=$(date -u -d "$1" +%s 2>/dev/null) && [ $((now - t)) -ge "$limit" ]; }
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
  local terms n j doc= cards= id tk qu ms cr fp since wc_out pr sha repo ts works ans
  terms=$(paddock_terminals) || { echo "org-watch: cannot reach the core (hc ls failed)" >&2; return 5; }

  # 1. approval cards (org-state.approvals), once per card
  if doc=$("$BASH" "$org" --as watcher doc get org-state 2>/dev/null); then
    cards=$(approval_lines "$doc")
    while IFS="$tab" read -r id tk qu; do
      [ -n "$id" ] || continue
      tell "approval:$id" "Approval waiting: ${tk:-?}" "${qu:0:200}"
    done <<< "$cards"
  else
    prune=; doc=
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

  # 5b. after N minutes: a green PR head with no card for its task and no landing (its
  # task still in org-state.work), and a card whose answer is in the person's history
  if [ -n "$doc" ]; then
    works=$(approval_lines "$doc" work | cut -f2)
    while IFS="$tab" read -r pr sha repo tk ts; do
      # ponytail: a request with no task cannot be matched to a card or a landing, so it is left out
      [ -n "$tk" ] && grep -qxF -- "$tk" <<< "$works" && older "$ts" || continue
      # a card for the task keeps the key, so the head is not told again once the card is gone
      if printf '%s\n' "$cards" | cut -f2 | grep -qxF -- "$tk"; then active="${active}mail:green:$repo#$pr@$sha
"; continue; fi
      mail_once "mail:green:$repo#$pr@$sha" "PR #$pr is green and no card asks about it"
    done <<< "$(green_lines)"
    ans=$(answer_lines)
    while IFS="$tab" read -r id tk qu; do
      [ -n "$id" ] || continue
      ts=$(printf '%s\n' "$ans" | awk -F'\t' -v i="$id" '$1 == i { print $2 }')
      [ -n "$ts" ] && older "$ts" || continue
      mail_once "mail:answered:$id" "answer for $id arrived; the card is still up"
    done <<< "$cards"
  fi

  # 6. /reload-plugins into the secretary after a skill landing; then the wake: the secretary
  # (not in the pass that typed the reload) and each live worker with unread mail
  : > "$wdir/reload-ready"   # tells org-start this watcher acts on watcher/reload-plugins
  reload_pass || wake "$sec" secretary
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
