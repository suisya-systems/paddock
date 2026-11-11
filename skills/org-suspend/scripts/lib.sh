# Shared by org-suspend, org-resume and org-down (sourced). Needs only bash, coreutils, hc.
# Assumptions, not measured against a real core: `hc ls --json` prints terminals with a
# "name" key; `hc get --json <name>` prints "labels": {"task_id": ...} and "status": {"state": ...}.

# Same start rule as org-start (Q17 d): never from inside an agent.
refuse_in_agent() {
  for v in CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID \
           CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN; do
    if [ -n "$(printenv "$v" 2>/dev/null)" ]; then
      die 4 "$v is set: this shell is inside an agent. Run it from your own login shell."
    fi
  done
}

# term_json <name>: the one-line get JSON; fails when the terminal is not found.
term_json() { local j; j=$(hc get --json "$1" 2>/dev/null) || return 1; printf '%s' "$j" | tr -d '\n'; }
# term_label <name>: its task_id label, empty when unlabelled.
term_label() { term_json "$1" | grep -o '"labels": *{[^{}]*}' | grep -o '"task_id": *"[^"]*"' | sed 's/.*: *"//; s/"$//'; }
# term_status <name>: the status state, "none" when it reports no status. Fails when not found.
term_status() {
  local j s; j=$(term_json "$1") || return 1
  # none only when the status is null or absent; a status object whose text has braces still counts as present.
  printf '%s' "$j" | grep -Eq '"status": *\{' || { echo none; return 0; }
  s=$(printf '%s' "$j" | grep -o '"status": *{[^{}]*"state": *"[^"]*"' | grep -o '"state": *"[^"]*"' | tail -1 | sed 's/.*: *"//; s/"$//')
  echo "${s:-present}"
}
# paddock_terminals: "name<TAB>task_id" for every terminal that carries a task_id label.
# Nothing without that label is listed, whatever its name. Fails when the core is unreachable.
paddock_terminals() {
  local out n l
  out=$(hc ls --json 2>/dev/null) || return 1
  for n in $(printf '%s' "$out" | grep -o '"name": *"[^"]*"' | sed 's/.*: *"//; s/"$//'); do
    l=$(term_label "$n")
    [ -z "$l" ] || printf '%s\t%s\n' "$n" "$l"
  done
}

# org_state_doc: the org-state document as one line (doc.get through hc connect; prototype 1: hold
# the input 1 s). "null" when it has no value. Fails (message on stderr) when it cannot be read.
org_state_doc() {
  local req doc
  req='{"jsonrpc":"2.0","id":1,"method":"doc.get","params":{"name":"org-state"}}'
  doc=$(set -o pipefail; { printf '%s\n' "$req"; sleep 1; } | hc connect 2>/dev/null | tr -d '\n') || { echo "hc connect failed" >&2; return 1; }
  printf '%s' "$doc" | grep -q '"result"' || { echo "org-state could not be read (no result in the answer)" >&2; return 1; }
  printf '%s' "$doc" | grep -Eq '"value": *\{' || doc=null
  printf '%s' "$doc"
}
# work_lines <doc>: a "work<TAB>id<TAB>worktree<TAB>head<TAB>dirty<TAB>task<TAB>title" line per work
# entry that has a worktree, head and dirty read from the worktree now. Fails when the work array
# or an entry in it is not closed. Entries are cut out with a scan that skips string contents
# (Issue #182), so braces, brackets and commas inside a task or title do not end an entry.
# Fields are read with sed from the one entry; flat entries are assumed.
work_lines() {
  local doc=$1 objs e id wt tk ti h d
  jf() { printf '%s' "$1" | sed -n 's/.*"'"$2"'": *"\(\([^"\\]\|\\.\)*\)".*/\1/p'; }
  objs=$(printf '%s' "$doc" | tr -d '\n' | awk '{
      if (!match($0, /"work": *\[/)) exit
      s = substr($0, RSTART + RLENGTH); q = 0; ob = 0; ok = 0
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1)
        if (q) { if (c == "\\") c = c substr(s, ++i, 1); else if (c == "\"") q = 0
                 if (ob) o = o c; continue }
        if (c == "\"") q = 1
        else if (c == "{") ob++
        else if (c == "}") ob--
        else if (c == "]" && ob == 0) { ok = 1; break }
        if (ob > 0 || c == "}") o = o c
        if (c == "}" && ob == 0) { print o; o = "" }
      }
      if (!ok || ob != 0) exit 1 }') || { echo "the work list in org-state cannot be read (not closed)" >&2; return 1; }
  printf '%s\n' "$objs" | grep '"worktree"' | while IFS= read -r e; do
    id=$(jf "$e" task_id); wt=$(jf "$e" worktree); tk=$(jf "$e" task); ti=$(jf "$e" title)
    if [ -n "$wt" ] && git -C "$wt" rev-parse HEAD >/dev/null 2>&1; then
      h=$(git -C "$wt" rev-parse HEAD); d=$(git -C "$wt" status --porcelain | wc -l | tr -d ' ')
    else h=missing; d=0; fi
    printf 'work\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id:--}" "${wt:--}" "$h" "$d" "${tk:--}" "${ti:--}"
  done
}
