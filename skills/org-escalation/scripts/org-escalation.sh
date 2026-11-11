#!/usr/bin/env bash
# org-escalation: the secretary's side of a worker's question. `ask` records an entry in
# org-state.approvals; `answer` forwards the person's answer to the worker through the
# mailbox and removes the entry. Needs bash, awk, sed and tr; the documents go through
# scripts/org (hc connect). See ../SKILL.md. Run it from the secretary.
set -u
export LC_ALL=C

usage() {
  cat <<'USAGE'
Usage: org-escalation.sh ask --task TASK_ID --question TEXT [--answer-in worker|secretary]
       org-escalation.sh answer --id APPROVAL_ID --text TEXT
       org-escalation.sh remove --id APPROVAL_ID
       org-escalation.sh list
       org-escalation.sh sweep

  ask     add an entry to org-state.approvals; prints APPROVAL_ID=<task_id>-<UTC time>
          --answer-in: who the person answers. worker = the worker's own permission prompt
          or dialog, in its terminal; secretary (default) = through you (card Yes / No, words)
  answer  send "Answer to your question (<id>): <text>" to w-<task_id> through the mailbox,
          then remove the entry
  remove  remove the entry only (answered in the worker's terminal, withdrawn, task dropped)
  list    print "<id><TAB><task_id><TAB><question>" per entry
  sweep   remove every answer_in worker entry whose terminal w-<task_id> shows working, idle or
          done in hc get; no status (a dialog), a missing terminal or a failed lookup keeps it

Ids hold lowercase letters, digits, _ and -. $PADDOCK_NOW (UTC ISO 8601) fixes the clock.
The mailbox and the state folder are those of scripts/org (PADDOCK_STATE_DIR).

Exit codes: 0 ok, 2 bad argument, 5 org-state could not be read or written (or is not an
object), 6 no entry with that id, 7 an entry with that id exists, 8 the answer could not be
sent (entry kept), 9 sent but the entry could not be removed (run remove).
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
              if (lastkey == "answer_in") oa[nobj] = str
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
        for (k = 1; k <= nobj; k++) if (oa[k] == "worker") printf "%s\t%s\n", oid[k], otask[k]
        exit 0
      }
      if (mode == "find") { if (!found) exit 4; print otask[found]; exit 0 }
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

cmd=${1:-}; [ $# -eq 0 ] || shift
case $cmd in -h|--help|help) usage; exit 0 ;; esac
task=; question=; text=; id=; answer_in=secretary
while [ $# -gt 0 ]; do
  case $1 in
    --task|--question|--text|--id|--answer-in)
      [ $# -ge 2 ] || die 2 "$1 needs a value"
      case $1 in --task) task=$2 ;; --question) question=$2 ;; --text) text=$2 ;; --id) id=$2 ;; --answer-in) answer_in=$2 ;; esac
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
    case $answer_in in worker|secretary) ;; *) die 2 "--answer-in is worker or secretary" ;; esac
    q=$(clean "$question")
    [ -n "${q//[ ]/}" ] || die 2 "ask needs a non-empty --question"
    [ "${#q}" -le 400 ] || die 2 "--question is over 400 bytes; one sentence the person can answer yes or no"
    now=${PADDOCK_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
    id=$task-$(printf '%s' "$now" | tr -d ':-')
    valid_aid "$id" || die 2 "cannot build an approval id from the clock: $now"
    qj=$(printf '%s' "$q" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    ESC_ENTRY="{\"id\":\"$id\",\"task_id\":\"$task\",\"question\":\"$qj\",\"asked_at\":\"$now\",\"answer_in\":\"$answer_in\"}"
    export ESC_ENTRY
    edit find "$id" >/dev/null; st=$?
    case $st in 0) die 7 "an entry $id exists already" ;; 4) ;; *) die 5 "org-state is not a JSON object (or cannot be read)" ;; esac
    update add "$id"
    echo "APPROVAL_ID=$id" ;;

  answer)
    valid_aid "$id" || die 2 "answer needs --id <approval_id>"
    t=$(clean "$text")
    [ -n "${t//[ ]/}" ] || die 2 "answer needs --text <answer>"
    wtask=$(edit find "$id"); st=$?
    case $st in 0) ;; 4) die 6 "no approval with id $id in org-state" ;; *) die 5 "org-state is not a JSON object (or cannot be read)" ;; esac
    valid_id "$wtask" || die 5 "entry $id has no usable task_id"
    secretary send_message "w-$wtask" "Answer to your question ($id): $t" >/dev/null \
      || die 8 "the answer could not be put in the mailbox of w-$wtask; entry $id kept"
    ( update remove "$id" ) || die 9 "answer sent to w-$wtask but entry $id could not be removed; run: remove --id $id"
    echo "ANSWERED $id -> w-$wtask" ;;

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
