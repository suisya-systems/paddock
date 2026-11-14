#!/usr/bin/env bash
# org-escalation: the secretary's side of a worker's question or prompt. `ask` records an entry in
# org-state.approvals; `answer` forwards the person's answer to the worker through the
# mailbox (or, for a prompt, as one key after a fresh screen read) and removes the entry.
# `prompt` answers a prompt in the policy list itself (L-N3). Needs bash, awk, sed and tr; the documents go through
# scripts/org (hc connect). See ../SKILL.md. Run it from the secretary.
set -u
export LC_ALL=C

usage() {
  cat <<'USAGE'
Usage: org-escalation.sh prompt --task TASK_ID [--then-send TEXT]
       org-escalation.sh ask --task TASK_ID --question TEXT [--prompt TEXT]
                           [--background TEXT] [--if-yes TEXT] [--if-no TEXT]
                           [--recommend yes|no --why TEXT] [--lang CODE]
       org-escalation.sh lang --lang CODE
       org-escalation.sh answer --id APPROVAL_ID --text TEXT
       org-escalation.sh remove --id APPROVAL_ID
       org-escalation.sh list
       org-escalation.sh sweep

  prompt  read the screen of w-<task_id>. A prompt in the policy list is answered here (down,
          read again, enter only with the cursor on the expected line): folder-trust (Claude
          Code's folder-trust dialog, on a terminal with no status yet) -> "Yes, I trust this
          folder"; auto-mode-setup ("Teach auto mode about your environment?") -> "Don't show
          again". Prints POLICY <entry> w-<task_id>. When org-delegate stopped at the dialog (exit 10) it
          saved the first message and the work entry: they are sent and written here, after the dialog,
          without --then-send (and so are they after answer yes). With
          --then-send, once the terminal reports a status, TEXT is sent with hc send (the first
          message the dialog stopped). Any other screen: prints PROMPT=<the dialog> and
          exits 3, nothing pressed; record it with ask --prompt
  ask     add an entry to org-state.approvals; prints APPROVAL_ID=<task_id>-<UTC time>
          --prompt: the PROMPT= text; the entry is a worker's prompt, answered by answer
          The card shows the context the person decides with; write all of it:
          --background  why this is asked, one or two sentences (at most 600 bytes)
          --if-yes      what happens on Yes (at most 300 bytes); --if-no likewise
          --recommend   your recommendation, yes or no, with --why (at most 400 bytes)
          --lang        the language code of the conversation (ja, en); the card's own words follow it
          A field left out is shown on the card as not written.
  lang    record the conversation language (ja, en) in org-state, for the cockpit's own words when
          no approval is open (the consult band); run it when you settle the language
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
nothing confirmed (entry kept), 11 (prompt) the screen could not be read, 12 the dialog was
answered but the first message was not sent (a card says so), 13 sent, but the work entry
was not written (a card says so).
USAGE
}

# Internal: _edit <add|remove|find|list|workers> [id] reads a document value on stdin. The new
# value (add, remove) or the answer (find, list) goes to stdout; the entry for add comes
# in $ESC_ENTRY. Exit 3 = the value is not a JSON object, 4 = id not found (add: id exists).
if [ "${1:-}" = _edit ]; then
  mode=${2:-}; id=${3:-}
  if [ "$mode" = setlang ]; then # $id is the code: set the top-level conversation_lang
    v=$(cat | tr -d '\n'); case $v in ''|null|[[:space:]]null*) printf '{"conversation_lang":"%s"}\n' "$id"; exit 0 ;; esac
    case $v in [[:space:]]*|'{'*) ;; *) exit 3 ;; esac
    case $v in *'"conversation_lang"'[[:space:]]:*|*'"conversation_lang":'*) printf '%s\n' "$v" | sed -E "s/\"conversation_lang\" *: *(null|\"[^\"]*\")/\"conversation_lang\":\"$id\"/" ;;
      *) printf '%s\n' "$v" | sed -E "s/^ *\{ *\}/{\"conversation_lang\":\"$id\"}/; t; s/^ *\{/{\"conversation_lang\":\"$id\",/" ;; esac
    exit 0
  fi
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
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
org=$root/scripts/org
secretary() { bash "$org" --as secretary "$@"; }

valid_id() { case "$1" in ''|-*|*[!a-z0-9_-]*) return 1 ;; esac; }
valid_aid() { case "$1" in ''|-*|*[!A-Za-z0-9_-]*) return 1 ;; esac; }  # approval ids hold the UTC time: T and Z are upper case
# clean: control characters (newline, tab ...) become spaces.
clean() { printf '%s' "$1" | tr '\000-\037\177' ' '; }
jstr() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
psum() { printf '%s' "$1" | cksum | tr ' ' -; }
# block <screen>: the dialog, on one line: its non-empty lines from the last rule line (only ─) to the end,
# trailing blanks cut; with no rule line, the whole screen. What a prompt entry records and what answer
# compares; the sum, not the text, so the document's escaping does not matter. The host check saw
# the transcript above the dialog change between two reads, so it is left out.
# ponytail: a request taller than the screen is compared only where it shows; hc read --lines can widen it.
dialog() { printf '%s\n' "$1" | sed 's/[[:space:]]*$//' | grep -v '^$' \
  | awk '{ l[NR] = $0 } /^ *(─)+ *$/ { s = NR } END { for (i = (s ? s : 1); i <= NR; i++) print l[i] }'; }
block() { clean "$(dialog "$1")"; }
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
unset background if_yes if_no recommend why lang prompt then_send
while [ $# -gt 0 ]; do
  case $1 in
    --task|--question|--text|--id|--prompt|--then-send|--background|--if-yes|--if-no|--recommend|--why|--lang)
      [ $# -ge 2 ] || die 2 "$1 needs a value"
      case $1 in --task) task=$2 ;; --question) question=$2 ;; --text) text=$2 ;; --id) id=$2 ;; --prompt) prompt=$2 ;; --then-send) then_send=$2 ;;
        --background) background=$2 ;; --if-yes) if_yes=$2 ;; --if-no) if_no=$2 ;; --recommend) recommend=$2 ;; --why) why=$2 ;; --lang) lang=$2 ;; esac
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
  # the history line that lets `org rebuild` replay this change is written by the same
  # call, inside the document's lock. The task is the id without its UTC suffix
  # (the id is <task_id>-<UTC yyyymmddThhmmssZ>).
  local t k x; t=$(printf '%s' "$2" | sed 's/-[0-9]\{8\}T[0-9]\{6\}Z$//')
  if [ "$1" = add ]; then k=approval_asked; x=$ESC_ENTRY; else k=approval_removed; x=$2; fi
  secretary doc update org-state --record "$k" --task "$t" --text "$x" -- bash "$self" _edit "$1" "$2" >/dev/null \
    || die 5 "org-state was not written ($1 $2)"
}

# The policy list (L-N3): the only prompts answered without the person, each by its whole option
# lines, never with a "Do you want" question on the screen. Keys as org-start: read, down,
# read again, enter only with the cursor on the expected line. These helpers use $w (the terminal)
# and, in pick, $policy.
# opt <screen> <line ERE>: the line is an option line of its own (cursor or not, numbered or not).
opt() { printf '%s\n' "$1" | grep -Eq "^ *(❯ *)?([0-9]\\. *)?$2 *\$"; }
# policy_of <screen>: the policy entry the screen shows, or nothing. Never with a "Do you want" question.
policy_of() {
  ! printf '%s\n' "$1" | grep -q 'Do you want' || return 0
  # folder-trust: comes before Claude Code reports any status, so a terminal with a status (a tool
  # prompt is blocked) never matches. No status = hc get answered for the terminal and its status is
  # null or absent; a failed lookup is not "no status".
  local j nostatus=
  j=$(hc get --json "$w" 2>/dev/null) || j=
  case $j in *'"name"'*) printf '%s' "$j" | tr -d '\n' | grep -Eq '"status": *\{' || nostatus=1 ;; esac
  if [ -n "$nostatus" ] && opt "$1" 'No, exit' && opt "$1" 'Yes, I trust this folder'; then echo folder-trust
  # auto-mode-setup: Claude Code's "Teach auto mode about your environment?" (Yes / Not now /
  # Don't show again), shown once to an auto-mode worker; answered "Don't show again" (owner).
  elif printf '%s\n' "$1" | grep -Eq '^ *Teach auto mode about your environment\? *$' \
       && opt "$1" 'Not now' && opt "$1" "Don't show again"; then echo auto-mode-setup
  fi
}
# pick <target line ERE> <max downs>: before every key, a fresh read must succeed and still show the
# same policy entry; enter only with the cursor on the target line. Anything else: return 1, no key.
pick() {
  local n=0 s
  while :; do
    s=$(hc read "$w" 2>/dev/null) || return 1
    [ "$(policy_of "$s")" = "$policy" ] || return 1
    if printf '%s\n' "$s" | grep -Eq "^ *❯ *([0-9]\\. *)?$1 *\$"; then
      hc keys "$w" enter >/dev/null 2>&1 || die 8 "hc keys enter failed on $w"; return 0
    fi
    [ "$n" -lt "$2" ] || return 1
    hc keys "$w" down >/dev/null 2>&1; sleep 1; n=$((n + 1))
  done
}
# trust_marker <task_id>: prints the marker org-clone leaves in the git folder of a fresh clone
# (paddock-trust-pending) when the worktree $PADDOCK_WORKERS_DIR/<task_id> belongs to such a clone.
trust_marker() {
  local c; c=$(git -C "${PADDOCK_WORKERS_DIR:-$HOME/paddock-workers}/$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -e "$c/paddock-trust-pending" ] && printf '%s\n' "$c/paddock-trust-pending"
}
# send_first: once $w reports a status, send --then-send text (the first message the dialog stopped).
send_first() {
  local i=0
  until hc get --json "$w" 2>/dev/null | tr -d '\n' | grep -Eq '"status": *\{'; do
    i=$((i + 1)); [ "$i" -lt "${PADDOCK_PROMPT_TRIES:-30}" ] || die 12 "$w reports no status after the dialog; the first message was not sent"
    sleep 1
  done
  hc send "$w" "$then_send" >/dev/null 2>&1 || die 12 "hc send to $w failed; the first message was not sent"
  echo "SENT $w"
}

# finish_resend <task_id>: org-delegate stopped at the dialog (exit 10) and saved its first message and work entry
# (skills/org-delegate/scripts/resend.sh). With the dialog answered, send and write them. A failure leaves the terminal and
# the saved files, puts a card in front of the person and exits with resend.sh's code (12 not sent, 13 entry not written).
rdir() { printf '%s/resend/%s' "${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}" "$1"; }
finish_resend() {
  local o rc
  o=$(bash "$root/skills/org-delegate/scripts/resend.sh" "$1" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || { echo "RESENT w-$1"; return 0; }
  bash "$self" ask --task "$1" --question "Trust was answered, but the first message or work entry of w-$1 is not finished: finish it?" \
    --background "$(clean "$o" | cut -c1-500)" --if-yes "The secretary runs resend.sh $1 and removes this card." \
    --if-no "The terminal is left as it is." >/dev/null 2>&1 || echo "org-escalation: the card could not be recorded" >&2
  die "$rc" "$o"
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
    case ${lang-ok} in ok|[a-z][a-z]|[a-z][a-z]-[A-Za-z][A-Za-z]) ;; *) die 2 "--lang is a language code such as en or ja" ;; esac
    ctx lang --lang 8 ${lang+"$lang"}
    ctx prompt --prompt 16000 ${prompt+"$prompt"}
    [ -z "${prompt+set}" ] || ctx="$ctx,\"prompt_sum\":\"$(psum "$(clean "$prompt")")\""
    ESC_ENTRY="{\"id\":\"$id\",\"task_id\":\"$task\",\"question\":\"$(jstr "$q")\",\"asked_at\":\"$now\"$ctx}"
    export ESC_ENTRY
    edit find "$id" >/dev/null; st=$?
    case $st in 0) die 7 "an entry $id exists already" ;; 4) ;; *) die 5 "org-state is not a JSON object (or cannot be read)" ;; esac
    update add "$id"
    echo "APPROVAL_ID=$id" ;;

  lang)
    case ${lang-} in [a-z][a-z]|[a-z][a-z]-[A-Za-z][A-Za-z]) ;; *) die 2 "lang needs --lang <code> such as en or ja" ;; esac
    secretary doc update org-state -- bash "$self" _edit setlang "$lang" >/dev/null || die 5 "org-state was not written (lang $lang)"
    echo "LANG=$lang" ;;

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
      # The folder-trust dialog comes before any status, so it is not "blocked": yes moves the cursor to
      # "Yes, I trust this folder" as the policy does (the default is "No, exit"), once the person said so.
      scr=$(hc read "$w" 2>/dev/null) || die 10 "cannot read the screen of $w; nothing pressed, entry $id kept"
      policy=$(policy_of "$scr")
      if [ "$policy" = folder-trust ]; then
        [ "$(psum "$(block "$scr")")" = "$sum" ] \
          || die 10 "the screen of $w no longer shows the prompt recorded in $id; nothing pressed, entry kept. Read it with prompt --task $wtask"
        if [ "$key" = esc ]; then hc keys "$w" esc >/dev/null 2>&1 || die 8 "hc keys esc failed on $w; entry $id kept"
          rm -f "$(rdir "$wtask")/message" "$(rdir "$wtask")/entry"; rmdir "$(rdir "$wtask")" 2>/dev/null # declined: nothing is resent
        else
          pick 'Yes, I trust this folder' 1 \
            || die 10 "$w: the folder-trust dialog did not stay on a fresh read with the cursor reaching 'Yes, I trust this folder'; nothing confirmed, entry $id kept"
          m=$(trust_marker "$wtask") && rm -f "$m" # the person trusted this clone: later workers are not held
        fi
        ( update remove "$id" ) || die 9 "answered $w but entry $id could not be removed; run: remove --id $id"
        echo "RELAYED $id $key -> $w"
        [ "$key" = esc ] && exit 0
        if [ -d "$(rdir "$wtask")" ]; then finish_resend "$wtask" # --then-send is not needed: org-delegate saved the message
        elif [ -n "${then_send+set}" ]; then send_first; fi
        exit 0
      fi
      hc get --json "$w" 2>/dev/null | tr -d '\n' | grep -Eq '"status": *\{[^{}]*"state": *"blocked"' \
        || die 10 "$w is not blocked on a prompt; nothing pressed, entry $id kept (sweep or remove it)"
      scr=$(hc read "$w" 2>/dev/null) || die 10 "cannot read the screen of $w; nothing pressed, entry $id kept"
      [ "$(psum "$(block "$scr")")" = "$sum" ] \
        || die 10 "the screen of $w no longer shows the prompt recorded in $id; nothing pressed, entry kept. Read it with prompt --task $wtask"
      # One cursor line in the dialog, and it is the one-time Yes as a whole line (not "Yes, and ...").
      # The transcript above the dialog shows sent messages with the same ❯ (host check).
      [ "$key" = esc ] || { [ "$(dialog "$scr" | grep -c '^ *❯')" = 1 ] \
        && dialog "$scr" | grep -Eq '^ *❯ *1\. Yes *$'; } \
        || die 10 "the cursor of $w is not on '1. Yes' alone; nothing pressed, entry $id kept"
      hc keys "$w" "$key" >/dev/null 2>&1 || die 8 "hc keys $key failed on $w; entry $id kept"
      ( update remove "$id" ) || die 9 "answered $w but entry $id could not be removed; run: remove --id $id"
      echo "RELAYED $id $key -> $w"; exit 0
    fi
    secretary send_message "w-$wtask" "Answer to your question ($id): $t" >/dev/null \
      || die 8 "the answer could not be put in the mailbox of w-$wtask; entry $id kept"
    # a worker that ended its turn never reads its mailbox. --if idle: a working worker
    # is not interrupted (it reads the mail itself), and a refused nudge does not fail the answer.
    # ponytail: only status "idle"; a worker with no status or blocked is left to the secretary's wait.
    hc get --json "w-$wtask" 2>/dev/null | tr -d '\n' | grep -Eq '"status": *\{[^{}]*"state": *"idle"' \
      && hc send --if idle "w-$wtask" "Your question was answered. Run check_messages and go on." >/dev/null 2>&1
    ( update remove "$id" ) || die 9 "answer sent to w-$wtask but entry $id could not be removed; run: remove --id $id"
    echo "ANSWERED $id -> w-$wtask" ;;

  prompt)
    valid_id "$task" || die 2 "prompt needs --task <task_id>"
    w=w-$task
    scr=$(hc read "$w" 2>/dev/null) || die 11 "cannot read the screen of $w; nothing pressed"
    policy=$(policy_of "$scr")
    # A fresh clone made by org-clone for a repository a request named: its folder-trust dialog is the
    # person's to answer (card, then answer), never the policy's (decision 0011).
    if [ "$policy" = folder-trust ] && trust_marker "$task" >/dev/null; then
      echo "org-escalation: $w is in a fresh clone made for a named repository: its folder-trust dialog is not answered automatically. Ask the person (ask --task $task --prompt <the PROMPT= text>); answer --text yes presses it" >&2
      policy=
    fi
    case $policy in
      folder-trust) pick 'Yes, I trust this folder' 1 \
        || die 10 "$w: the folder-trust dialog did not stay on a fresh read with the cursor reaching 'Yes, I trust this folder'; nothing confirmed. Read it with hc read $w" ;;
      auto-mode-setup) pick "Don't show again" 2 \
        || die 10 "$w: the auto mode setup dialog did not stay on a fresh read with the cursor reaching \"Don't show again\"; nothing confirmed. Read it with hc read $w" ;;
    esac
    if [ -n "$policy" ]; then
      echo "POLICY $policy $w"
      if [ -d "$(rdir "$task")" ]; then finish_resend "$task"; exit 0; fi
      [ -n "${then_send+set}" ] || exit 0
      send_first; exit 0
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
