#!/usr/bin/env bash
# org-suspend: record the organization's state and leave every terminal alive.
# Needs only bash, coreutils, git and hc. See ../SKILL.md. Run it from the person's login shell.
set -u

usage() {
  cat <<'USAGE'
Usage: org-suspend.sh [-h|--help]

Records the org-state document and the terminals that carry a task_id label (with each
worker's worktree git state) in one local file. Ends nothing, starts nothing, types
nothing into any agent and does not stop the core.

Environment overrides:
  PADDOCK_STATE_DIR  folder of the record (default ${XDG_STATE_HOME:-~/.local/state}/paddock)

Exit codes: 0 recorded, 2 bad argument, 3 hc not found, 4 run inside an agent,
5 core unreachable or the record could not be written.
USAGE
}

case "${1:-}" in
  "") ;;
  -h|--help) usage; exit 0 ;;
  *) echo "org-suspend: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

die() { code=$1; shift; echo "org-suspend: $*" >&2; exit "$code"; }
command -v hc >/dev/null 2>&1 || die 3 "hc not found on PATH (install herdr-core)"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
refuse_in_agent

dir=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}
terms=$(paddock_terminals) || die 5 "cannot reach the herdr core (hc ls failed)"

doc=$(org_state_doc 2>&1) || die 5 "$doc; the previous record is kept"
works=$(work_lines "$doc" 2>&1) || die 5 "$works; the previous record is kept"
tmpf=$(mktemp "${TMPDIR:-/tmp}/org-suspend.XXXXXX") || die 5 "cannot create a temporary file"
{
  echo "# paddock suspend record (org-suspend)"
  echo "written_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "org_state=$doc"
  while IFS=$'\t' read -r n id; do
    [ -n "$n" ] && printf 'terminal\t%s\t%s\t%s\n' "$n" "$id" "$(term_status "$n" 2>/dev/null || echo none)"
  done <<<"$terms"
  [ -z "$works" ] || printf '%s\n' "$works"
} > "$tmpf" && mkdir -p "$dir" && mv -f "$tmpf" "$dir/suspend.record" || die 5 "cannot write $dir/suspend.record"
echo "org-suspend: recorded to $dir/suspend.record; every terminal is still alive"
