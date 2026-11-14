#!/usr/bin/env bash
# org-down: suspend, then kill and remove only the terminals paddock started (task_id label).
# Needs only bash, coreutils, git and hc. See ../SKILL.md. Run it from the person's login shell.
set -u

usage() {
  cat <<'USAGE'
Usage: org-down.sh [--secretary] [--stop-core] [-h|--help]

Runs org-suspend, then hc kill and hc rm for every terminal that carries a task_id
label. Terminals without that label are never touched.
  --secretary  also end the secretary terminal (name PADDOCK_SECRETARY_NAME, default secretary)
  --stop-core  afterwards run hc server stop. Without it the core is never stopped
               (it is the person's: it holds every terminal on it, not only paddock's).

Exit codes: 0 done, 2 bad argument, 3 hc not found, 4 run inside an agent,
5 core unreachable or hc kill/rm/server stop failed; a failed suspend ends nothing.
USAGE
}

secretary=; stop_core=
for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --secretary) secretary=1 ;;
    --stop-core) stop_core=1 ;;
    *) echo "org-down: unknown argument: $a" >&2; usage >&2; exit 2 ;;
  esac
done

die() { code=$1; shift; echo "org-down: $*" >&2; exit "$code"; }
command -v hc >/dev/null 2>&1 || die 3 "hc not found on PATH (install herdr-core)"
here=$(dirname "${BASH_SOURCE[0]}")
. "$here/../../org-suspend/scripts/lib.sh"
refuse_in_agent

# 1. Suspend first. If it fails nothing is ended.
bash "$here/../../org-suspend/scripts/org-suspend.sh" || die 5 "org-suspend failed; nothing was ended"

# 2. Only terminals with a task_id label (and the secretary when asked).
terms=$(paddock_terminals) || die 5 "cannot reach the herdr core (hc ls failed)"
names=$(printf '%s\n' "$terms" | cut -f1)
[ -z "$secretary" ] || names=$(printf '%s\n%s\n' "$names" "${PADDOCK_SECRETARY_NAME:-secretary}")
wts=()
for n in $names; do
  hc kill "$n" >/dev/null 2>&1 || die 5 "hc kill $n failed; stopped there, the core was not stopped"
  hc rm "$n" >/dev/null 2>&1 || die 5 "hc rm $n failed; stopped there, the core was not stopped"
  echo "org-down: ended $n"
  l=$(printf '%s\n' "$terms" | awk -F'\t' -v n="$n" '$1==n {print $2; exit}')
  [ -z "$l" ] || wts+=("${PADDOCK_WORKERS_DIR:-$HOME/paddock-workers}/$l")
done

# 2b. The watcher (decision 0008) goes with the organization: only a terminal with the label
# paddock_role=watcher, never another terminal that happens to be called watcher.
wn=${PADDOCK_WATCHER_NAME:-watcher}
if term_json "$wn" | grep -Eq '"paddock_role": *"watcher"'; then
  hc kill "$wn" >/dev/null 2>&1 || die 5 "hc kill $wn failed; the core was not stopped"
  hc rm "$wn" >/dev/null 2>&1 || die 5 "hc rm $wn failed; the core was not stopped"
  echo "org-down: ended $wn"
fi
# Issue #324: only after every worker is ended, so none of them counts as a live worker of its clone.
[ "${#wts[@]}" -eq 0 ] || sweep_config_lock "${wts[@]}"

# 3. The person's core is stopped only when asked.
if [ -n "$stop_core" ]; then
  hc server stop >/dev/null 2>&1 || die 5 "hc server stop failed"
  echo "org-down: core stopped (--stop-core)"
fi
echo "org-down: done"
