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
  s=$(printf '%s' "$j" | grep -o '"status": *{[^{}]*}' | grep -o '"state": *"[^"]*"' | sed 's/.*: *"//; s/"$//')
  echo "${s:-none}"
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
