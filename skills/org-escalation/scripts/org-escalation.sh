#!/usr/bin/env bash
# org-escalation: the secretary's side of a worker's question or prompt. `ask` records an entry in
# org-state.approvals; `answer` forwards the person's answer to the worker through the
# mailbox (or, for a prompt, as one key after a fresh screen read) and removes the entry.
# `prompt` answers a prompt in the policy list itself (L-N3, Issue #260). Needs bash, awk, sed and tr; the documents go through
# scripts/org (hc connect). See ../SKILL.md. Run it from the secretary.
set -u
export LC_ALL=C

usage() {
  cat <<'USAGE'
Usage: org-escalation.sh prompt --task TASK_ID [--then-send TEXT]
       org-escalation.sh ask --task TASK_ID --question TEXT [--prompt TEXT]
                           [--background TEXT] [--if-yes TEXT] [--if-no TEXT]
                           [--recommend yes|no --why TEXT]
       org-escalation.sh answer --id APPROVAL_ID --text TEXT
       org-escalation.sh remove --id APPROVAL_ID
       org-escalation.sh list
       org-escalation.sh sweep

  prompt  read the screen of w-<task_id>. A prompt in the policy list (folder-trust: Claude
          Code's folder-trust dialog, on a terminal with no status yet) is answered here: down, read again, enter only with the
          cursor on "Yes, I trust this folder"; prints POLICY folder-trust w-<task_id>. With
          --then-send, once the terminal reports a status, TEXT is sent with hc send (the first
          message the dialog stopped). Any other screen: prints PROMPT=<the whole screen> and
          exits 3, nothing pressed; record it with ask --prompt
  ask     add an entry to org-state.approvals; prints APPROVAL_ID=<task_id>-<UTC time>
          --prompt: the PROMPT= text; the entry is a worker's prompt, answered by answer
          The card shows the context the person decides with; write all of it:
          --background  why this is asked, one or two sentences (at most 600 bytes)
          --if-yes      what happens on Yes (at most 300 bytes); --if-no likewise
          --recommend   your recommendation, yes or no, with --why (at most 400 bytes)
          A field left out is shown on the card as not written.
  answer  send "Answer to your question (<id>): <text>" to w-<task_id> through the mailbox,
          then remove the entry. A prompt entry takes yes or no: only while w-<task_id> is
          blocked and its screen still shows the recorded prompt, yes presses enter on
          "1. Yes" (once, never "don't ask again") and no presses esc
  remove  remove the entry only (answered in the worker's terminal, withdrawn, task dropped)
  list    print "<id><TAB><task_id><TAB><question>" per entry
  sweep   remove every prompt entry whose terminal w-<task_id> shows working, idle or
          done in hc get; no status (a dialog), a missing terminal or a failed lookup keeps it

Ids hold lowercase letters, digits, _ and -. $PADDOCK_NOW (UTC ISO 8601) fixes the clock.
The mailbox and the state folder are those of scripts/org (PADDOCK_STATE_DIR).

Exit codes: 0 ok, 2 bad argument, 5 org-state could not be read or written (or is not an
object), 6 no entry with that id, 7 an entry with that id exists, 8 the answer could not be
sent or the key not pressed (entry kept), 9 sent but the entry could not be removed (run
remove), 3 (prompt) not in the policy list, 10 the screen did not show what was expected:
nothing confirmed (entry kept), 11 (prompt) the screen could not be read, 12 (prompt) the
dialog was answered but --then-send failed.
USAGE
}

# Internal: _edit <add|remove|find|list|workers> [id] reads a document value on stdin. The new
# value (add, remove) or the answer (find, list) goes to stdout; the entry for add comes
# in $ESC_ENTRY. Exit 3 = the value is not a JSON object, 4 = id not found (add: id exists).
if [ "${1:-}" = _edit ]; then
  mode=${2:-}; id=${3:-}
  MODE=$mode ID=$id exec awk '
    { s = s $0 "\n" }
    END {
      mode = ENVIRON["MODE"]; id = ENVIRON["ID"]; entry = ENVIRON["ESC_ENTRY"]
      n = length(s); depth = 0; instr = 0; nobj = 0; astart = 0; aend = 0; top = 0
      haskey = 0; wantarr = 0; inarr = 0; lastkey = ""
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (instr) {
          if (c == "\\") { i++; continue }
          if (c != "\"") continue
          instr = 0
          str = substr(s, sstart + 1, i - sstart - 1)
          j = i + 1; while (substr(s, j, 1) ~ /[ \t\n\r]/) j++
          if (substr(s, j, 1) == ":") {
            lastkey = str
            if (depth == 1 && str == "approvals") { wantarr = 1; haskey = 1 }
          } else {
            if (inarr && depth == 3) {
              if (lastkey == "id") oid[nobj] = str
              if (lastkey == "task_id") otask[nobj] = str
              if (lastkey == "question") oq[nobj] = str
              if (lastkey == "prompt") hp[nobj] = 1
              if (lastkey == "prompt_sum") ops[nobj] = str
            }
            lastkey = ""
          }
          continue
        }
        if (wantarr && c !~ /[ \t\n\r:]/ && c != "[") wantarr = 0
        if (c == "\"") { instr = 1; sstart = i }
        else if (c == "{" || c == "[") {
          depth++
          if (top == 0 && depth == 1 && c == "{") top = i
          if (c == "[" && depth == 2 && wantarr) { astart = i; inarr = 1; wantarr = 0 }
          else if (c == "{" && inarr && depth == 3) { nobj++; ostart[nobj] = i }
        } else if (c == "}" || c == "]") {
          if (c == "}" && inarr && depth == 3) oend[nobj] = i
          if (c == "]" && inarr && depth == 2) { aend = i; inarr = 0 }
          depth--
        }
      }
      t = s; gsub(/[ \t\n\r]/, "", t)
      if (t == "null" && mode != "add") exit 4
      if (t == "null" && mode == "add") { printf "{\"approvals\":[%s]}", entry; exit 0 }
      if (top == 0 || depth != 0 || instr || (haskey && astart == 0) || (astart && aend == 0)) exit 3
      for (k = 1; k <= nobj; k++) if (oid[k] == id) found = k
      if (mode == "list") {
        for (k = 1; k <= nobj; k++) {
          q = oq[k]; gsub(/\\"/, "\"", q); gsub(/\\\\/, "\\", q)
          printf "%s\t%s\t%s\n", oid[k], otask[k], q
        }
        exit 0
      }
      if (mode == "workers") {
        for (k = 1; k <= nobj; k++) if (hp[k]) printf "%s\t%s\n", oid[k], otask[k]
        exit 0
      }
      if (mode == "find") { if (!found) exit 4; printf "%s\t%s\n", otask[found], ops[found]; exit 0 }
      if (mode == "remove") {
        if (!found) exit 4
        if (found < nobj) { from = ostart[found]; to = ostart[found + 1] - 1 }
        else if (found > 1) { from = oend[found - 1] + 1; to = oend[found] }
        else { from = ostart[found]; to = oend[found] }
        printf "%s%s", substr(s, 1, from - 1), substr(s, to + 1)
        exit 0
      }
      if (mode == "add") {
        if (found) exit 4
        if (astart && nobj == 0) printf "%s%s%s", substr(s, 1, astart), entry, substr(s, aend)
        else if (astart) printf "%s,%s%s", substr(s, 1, oend[nobj]), entry, substr(s, oend[nobj] + 1)
        else {
          j = top + 1; while (substr(s, j, 1) ~ /[ \t\n\r]/) j++
          ins = "\"approvals\":[" entry "]"; if (substr(s, j, 1) != "}") ins = ins ","
          printf "%s%s%s", substr(s, 1, top), ins, substr(s, top + 1)
        }
        exit 0
      }
      exit 2
    }'
fi

die() { code=$1; shift; echo "org-escalation: $*" >&2; exit "$code"; }

self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
org=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/scripts/org
secretary() { bash "$org" --as secretary "$@"; }

valid_id() { case "$1" in ''|-*|*[!a-z0-9_-]*) return 1 ;; esac; }
valid_aid() { case "$1" in ''|-*|*[!A-Za-z0-9_-]*) return 1 ;; esac; }  # approval ids hold the UTC time: T and Z are upper case
# clean: control characters (newline, tab ...) become spaces.
clean() { printf '%s' "$1" | tr '\000-\037\177' ' '; }
jstr() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
psum() { printf '%s' "$1" | cksum | tr ' ' -; }
# block <screen>: all its non-empty lines, trailing blanks cut, on one line. What a prompt entry
# records and what answer compares; the sum, not the text, so the document's escaping does not matter.
# ponytail: the whole screen, so any change on it (a timer, a redraw) refuses the relay, and a request
# taller than the screen is compared only where it shows; hc read --lines can widen it if a host run asks.
block() { clean "$(printf '%s\n' "$1" | sed 's/[[:space:]]*$//' | grep -v '^$')"; }
# ctx <key> <option> <max bytes> <value if set>: append ,"<key>":"<value>" to $ctx when the option
# was given; exit 2 when it is empty or too long.
ctx() {
  [ $# -ge 4 ] || return 0
  local v; v=$(clean "$4")
  [ -n "${v//[ ]/}" ] || die 2 "$2 is empty"
  [ "${#v}" -le "$3" ] || die 2 "$2 is over $3 bytes"
  ctx="$ctx,\"$1\":\"$(jstr "$v")\""
}

cmd=${1:-}; [ $# -eq 0 ] || shift
case $cmd in -h|--help|help) usage; exit 0 ;; esac
task=; question=; text=; id=
unset background if_yes if_no recommend why prompt then_send
while [ $# -gt 0 ]; do
  case $1 in
    --task|--question|--text|--id|--prompt|--then-send|--background|--if-yes|--if-no|--recommend|--why)
      [ $# -ge 2 ] || die 2 "$1 needs a value"
      case $1 in --task) task=$2 ;; --question) question=$2 ;; --text) text=$2 ;; --id) id=$2 ;; --prompt) prompt=$2 ;; --then-send) then_send=$2 ;;
        --background) background=$2 ;; --if-yes) if_yes=$2 ;; --if-no) if_no=$2 ;; --recommend) recommend=$2 ;; --why) why=$2 ;; esac
      shift 2 ;;
    *) echo "org-escalation: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# docval: print the org-state value; exit 5 when it cannot be read.
docval() { secretary doc get org-state 2>&1 || die 5 "cannot read org-state"; }
edit() { # edit <mode> <id> : run _edit on the current value; status 3 and 4 pass through
  docval | bash "$self" _edit "$1" "$2"
}
update() { # update <mode> <id>: re-read, apply, set (scripts/org retries on a version conflict)
  # Issue #77: the history line that lets `org rebuild` replay this change is written by the same
  # call, inside the document's lock. The task is the id without its UTC suffix
  # (the id is <task_id>-<UTC yyyymmddThhmmssZ>).
  local t k x; t=$(printf '%s' "$2" | sed 's/-[0-9]\{8\}T[0-9]\{6\}Z$//')
  if [ "$1" = add ]; then k=approval_asked; x=$ESC_ENTRY; else k=approval_removed; x=$2; fi
  secretary doc update org-state --record "$k" --task "$t" --text "$x" -- bash "$self" _edit "$1" "$2" >/dev/null \
    || die 5 "org-state was not written ($1 $2)"
}

case $cmd in
  ask)
    valid_id "$task" || die 2 "ask needs --task <task_id> (lowercase letters, digits, _ and -)"
    q=$(clean "$question")
    [ -n "${q//[ ]/}" ] || die 2 "ask needs a non-empty --question"
    [ "${#q}" -le 400 ] || die 2 "--question is over 400 bytes; one sentence the person can answer yes or no"
    now=${PADDOCK_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
    id=$task-$(printf '%s' "$now" | tr -d ':-')
    valid_aid "$id" || die 2 "cannot build an approval id from the clock: $now"
    case ${recommend-unset}:${why+set} in
      unset:|yes:set|no:set) ;;
      unset:set) die 2 "--why needs --recommend yes|no" ;;
      yes:|no:) die 2 "--recommend needs --why <reason>" ;;
      *) die 2 "--recommend is yes or no" ;;
    esac
    ctx=
    ctx background --background 600 ${background+"$background"}
    ctx if_yes --if-yes 300 ${if_yes+"$if_yes"}
    ctx if_no --if-no 300 ${if_no+"$if_no"}
    ctx recommend --recommend 3 ${recommend+"$recommend"}
    ctx why --why 400 ${why+"$why"}
    ctx prompt --prompt 16000 ${prompt+"$prompt"}
    [ -z "${prompt+set}" ] || ctx="$ctx,\"prompt_sum\":\"$(psum "$(clean "$prompt")")\""
    ESC_ENTRY="{\"id\":\"$id\",\"task_id\":\"$task\",\"question\":\"$(jstr "$q")\",\"asked_at\":\"$now\"$ctx}"
    export ESC_ENTRY
    edit find "$id" >/dev/null; st=$?
    case $st in 0) die 7 "an entry $id exists already" ;; 4) ;; *) die 5 "org-state is not a JSON object (or cannot be read)" ;; esac
    update add "$id"
    echo "APPROVAL_ID=$id" ;;

  answer)
    valid_aid "$id" || die 2 "answer needs --id <approval_id>"
    t=$(clean "$text")
    [ -n "${t//[ ]/}" ] || die 2 "answer needs --text <answer>"
    f=$(edit find "$id"); st=$?
    case $st in 0) ;; 4) die 6 "no approval with id $id in org-state" ;; *) die 5 "org-state is not a JSON object (or cannot be read)" ;; esac
    wtask=${f%%$'\t'*}; sum=${f#*$'\t'}
    valid_id "$wtask" || die 5 "entry $id has no usable task_id"
    if [ -n "$sum" ]; then
      # A worker's prompt (L-N3): one key, only while the same prompt is on a blocked terminal.
      w=w-$wtask
      case $(printf '%s' "$t" | tr 'A-Z' 'a-z' | tr -d ' ') in yes) key=enter ;; no) key=esc ;;
        *) die 2 "entry $id is a worker's prompt: the answer is yes or no; nothing pressed" ;; esac
      hc get --json "$w" 2>/dev/null | tr -d '\n' | grep -Eq '"status": *\{[^{}]*"state": *"blocked"' \
        || die 10 "$w is not blocked on a prompt; nothing pressed, entry $id kept (sweep or remove it)"
      scr=$(hc read "$w" 2>/dev/null) || die 10 "cannot read the screen of $w; nothing pressed, entry $id kept"
      [ "$(psum "$(block "$scr")")" = "$sum" ] \
        || die 10 "the screen of $w no longer shows the prompt recorded in $id; nothing pressed, entry kept. Read it with prompt --task $wtask"
      # One cursor line on the screen, and it is the one-time Yes as a whole line (not "Yes, and ...").
      [ "$key" = esc ] || { [ "$(printf '%s\n' "$scr" | grep -c '^ *❯')" = 1 ] \
        && printf '%s\n' "$scr" | grep -Eq '^ *❯ *1\. Yes *$'; } \
        || die 10 "the cursor of $w is not on '1. Yes' alone; nothing pressed, entry $id kept"
      hc keys "$w" "$key" >/dev/null 2>&1 || die 8 "hc keys $key failed on $w; entry $id kept"
      ( update remove "$id" ) || die 9 "answered $w but entry $id could not be removed; run: remove --id $id"
      echo "RELAYED $id $key -> $w"; exit 0
    fi
    secretary send_message "w-$wtask" "Answer to your question ($id): $t" >/dev/null \
      || die 8 "the answer could not be put in the mailbox of w-$wtask; entry $id kept"
    ( update remove "$id" ) || die 9 "answer sent to w-$wtask but entry $id could not be removed; run: remove --id $id"
    echo "ANSWERED $id -> w-$wtask" ;;

  prompt)
    valid_id "$task" || die 2 "prompt needs --task <task_id>"
    w=w-$task
    scr=$(hc read "$w" 2>/dev/null) || die 11 "cannot read the screen of $w; nothing pressed"
    # The policy list (L-N3): the only prompt answered without the person. Same steps as org-start (#254).
    # The folder-trust dialog comes before Claude Code reports any status, so a terminal with a status
    # (a tool prompt is blocked) never matches; its two choices must be whole lines, not text in output.
    # No status = hc get answered for the terminal and its status is null or absent; a failed lookup is not "no status".
    j=$(hc get --json "$w" 2>/dev/null) || j=
    nostatus=; case $j in *'"name"'*) printf '%s' "$j" | tr -d '\n' | grep -Eq '"status": *\{' || nostatus=1 ;; esac
    if [ -n "$nostatus" ] \
       && printf '%s\n' "$scr" | grep -Eq '^ *(❯ *)?[0-9]\. No, exit *$' \
       && printf '%s\n' "$scr" | grep -Eq '^ *(❯ *)?[0-9]\. Yes, I trust this folder *$' \
       && ! printf '%s\n' "$scr" | grep -q 'Do you want'; then
      hc keys "$w" down >/dev/null 2>&1; sleep 1
      hc read "$w" 2>/dev/null | grep -Eq '^ *❯ *[0-9]\. Yes, I trust this folder *$' \
        || die 10 "$w shows the folder-trust dialog and the cursor did not reach 'Yes, I trust this folder'; nothing confirmed. Read it with hc read $w"
      hc keys "$w" enter >/dev/null 2>&1 || die 8 "hc keys enter failed on $w"
      echo "POLICY folder-trust $w"
      [ -n "${then_send+set}" ] || exit 0
      i=0
      until hc get --json "$w" 2>/dev/null | tr -d '\n' | grep -Eq '"status": *\{'; do
        i=$((i + 1)); [ "$i" -lt "${PADDOCK_PROMPT_TRIES:-30}" ] || die 12 "$w reports no status after the dialog; the first message was not sent"
        sleep 1
      done
      hc send "$w" "$then_send" >/dev/null 2>&1 || die 12 "hc send to $w failed; the first message was not sent"
      echo "SENT $w"; exit 0
    fi
    b=$(block "$scr"); [ -n "${b//[ ]/}" ] || die 11 "the screen of $w is empty; nothing pressed"
    echo "PROMPT=$b"; exit 3 ;;

  remove)
    valid_aid "$id" || die 2 "remove needs --id <approval_id>"
    edit find "$id" >/dev/null; st=$?
    case $st in 0) ;; 4) die 6 "no approval with id $id in org-state" ;; *) die 5 "org-state is not a JSON object (or cannot be read)" ;; esac
    update remove "$id"
    echo "REMOVED $id" ;;

  list)
    edit list "" ; st=$?
    case $st in 0|4) ;; *) die 5 "org-state is not a JSON object (or cannot be read)" ;; esac ;;

  sweep)
    list=$(edit workers ""); st=$?
    case $st in 0|4) ;; *) die 5 "org-state is not a JSON object (or cannot be read)" ;; esac
    while IFS=$'\t' read -r aid wtask; do
      [ -n "$aid" ] || continue
      valid_aid "$aid" && valid_id "$wtask" || continue
      # only a status whose state is working, idle or done counts; anything else (no status, not found, hc failed) keeps it
      j=$(hc get --json "w-$wtask" 2>/dev/null | tr -d '\n') || continue
      printf '%s' "$j" | grep -Eq '"status": *\{[^{}]*"state": *"(working|idle|done)"' || continue
      update remove "$aid" || continue
      echo "SWEPT $aid"
    done <<< "$list" ;;

  *) echo "org-escalation: unknown command: ${cmd:-}" >&2; usage >&2; exit 2 ;;
esac
