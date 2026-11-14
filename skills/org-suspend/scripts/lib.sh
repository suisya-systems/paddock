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

# sweep_config_lock <worktree>...: Issue #324. Call it after the terminals of those workers are ended (hc kill, hc rm).
# Claude Code's sandbox leaves a 0-byte read-only <git-common-dir>/config.lock for the whole of every command a worker
# runs, and it stays when the terminal is killed mid-command (measured 2026-11-14, docs/design/worker-github-access.md D);
# every later git config write in that clone then fails. The file's attributes cannot tell a live command from a leftover,
# so it is removed only when (a) it is a regular file, 0 bytes, not writable (a real git lock is writable or has content),
# (b) no process has its cwd in the ended workers' worktrees (waits PADDOCK_LOCK_WAIT s, default 10, for a killed command
# to end) and (c) none has it in another linked worktree of the same clone. Otherwise it stays and is reported.
# ponytail: processes are found through /proc/*/cwd (hc get shows no pid); where /proc is missing nothing is removed.
# (d) A command that cd'd out of the worktree is still seen when its sandbox has the clone's .git or the lock mounted
# (/proc/*/mountinfo, as the sandbox's bind mounts show there); that signal is skipped when this very process has that
# mount (a sandboxed secretary), since it could not tell the ended worker from the caller.
# ponytail: a process with neither its cwd nor those mounts in the clone is not seen; hc exposing a pid would replace this scan.
_in_dirs() { # _in_dirs <dir>...: 0 when a process has its cwd in one of them, 1 none, 2 /proc unreadable
  local p c d
  [ -r /proc/self/cwd ] || return 2
  for p in /proc/[0-9]*; do
    c=$(readlink "$p/cwd" 2>/dev/null) || continue
    for d in "$@"; do case "$c" in "$d"|"$d"/*) return 0 ;; esac; done
  done
  return 1
}
_mounted() { # _mounted <path>...: 0 when a process (not this one) has a mount point at one of them
  local p
  for p in /proc/[0-9]*; do
    [ "$p" = "/proc/$$" ] && continue
    awk -v a="$1" -v b="$2" '$5==a||$5==b{f=1;exit}END{exit !f}' "$p/mountinfo" 2>/dev/null && return 0
  done
  return 1
}
_placeholder() { [ -f "$1" ] && [ ! -L "$1" ] && [ ! -s "$1" ] && [ ! -w "$1" ]; }
sweep_config_lock() {
  local state=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}
  local wait=${PADDOCK_LOCK_WAIT:-10} seen=' ' wt c lk ended other n r mnt
  for wt in "$@"; do
    [ -d "$wt" ] || continue
    c=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || continue
    case "$seen" in *" $c "*) continue ;; esac; seen="$seen$c "
    lk=$c/config.lock
    _placeholder "$lk" || continue
    ended=(); for r in "$@"; do
      [ "$(git -C "$r" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" = "$c" ] && ended+=("$(cd "$r" && pwd -P)")
    done
    mnt=1; awk -v a="$lk" -v b="$c" '$5==a||$5==b{f=1;exit}END{exit !f}' /proc/self/mountinfo 2>/dev/null || mnt=0
    busy() { _in_dirs "${ended[@]}"; r=$?; [ "$r" -eq 2 ] || [ "$mnt" -eq 1 ] || { [ "$r" -ne 0 ] && _mounted "$lk" "$c" && r=3; }; }
    n=0; busy
    while [ "$r" -eq 0 ] || [ "$r" -eq 3 ]; do [ "$n" -lt "$wait" ] || break; sleep 1; n=$((n + 1)); busy; done
    [ "$r" -ne 2 ] || { echo "NOT removed $lk: cannot tell whether a command of the ended worker still runs (no /proc); remove it by hand if none does" >&2; continue; }
    if [ "$r" -eq 3 ]; then
      echo "NOT removed $lk: a sandboxed process of this clone is still running (its sandbox has the clone's .git mounted); remove it by hand once it has ended" >&2; continue
    fi
    if [ "$r" -eq 0 ]; then
      echo "NOT removed $lk: a process of the ended worker is still running in its worktree (${ended[*]}); remove it by hand once it has ended" >&2; continue
    fi
    # Other linked worktrees of the clone (the first one listed is the clone itself): any process there is a live worker.
    other=(); while IFS= read -r r; do
      [ -d "$r" ] && r=$(cd "$r" && pwd -P); case " ${ended[*]} " in *" $r "*) ;; *) other+=("$r") ;; esac
    done < <(git -C "$wt" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | tail -n +2)
    if [ "${#other[@]}" -gt 0 ] && _in_dirs "${other[@]}"; then
      echo "NOT removed $lk: another worker of this clone is still running; remove it by hand when none runs" >&2; continue
    fi
    # The wait above can be long: a real git lock may have replaced the placeholder meanwhile, so look again just before rm.
    _placeholder "$lk" || { echo "NOT removed $lk: it changed while waiting and is no longer a leftover placeholder" >&2; continue; }
    if rm -f "$lk"; then
      echo "removed leftover $lk (0 bytes, read-only; the worker's terminal is ended and no command of it runs)"
      { mkdir -p "$state" && printf '%s removed %s after ending %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$lk" "${ended[*]}" >> "$state/removed-locks.log"; } 2>/dev/null \
        || echo "could not write $state/removed-locks.log" >&2
    else echo "NOT removed $lk: rm failed" >&2; fi
  done
}
