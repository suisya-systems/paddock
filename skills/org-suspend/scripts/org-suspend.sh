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

# org-state through hc connect (hc has no document verb; prototype 1: hold the input 1 s).
req='{"jsonrpc":"2.0","id":1,"method":"doc.get","params":{"name":"org-state"}}'
doc=$({ printf '%s\n' "$req"; sleep 1; } | hc connect 2>/dev/null | tr -d '\n') || die 5 "hc connect failed"
printf '%s' "$doc" | grep -Eq '"value": *\{' || doc=null

jf() { printf '%s' "$1" | sed -n 's/.*"'"$2"'": *"\(\([^"\\]\|\\.\)*\)".*/\1/p'; }
tmpf=$(mktemp "${TMPDIR:-/tmp}/org-suspend.XXXXXX") || die 5 "cannot create a temporary file"
{
  echo "# paddock suspend record (org-suspend)"
  echo "written_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "org_state=$doc"
  while IFS=$'\t' read -r n id; do
    [ -n "$n" ] && printf 'terminal\t%s\t%s\t%s\n' "$n" "$id" "$(term_status "$n" 2>/dev/null || echo none)"
  done <<<"$terms"
  # Work entries are flat objects with a worktree field (approvals have none).
  # ponytail: grep/sed JSON reading; assumes flat entries, no braces inside strings.
  printf '%s' "$doc" | grep -o '{[^{}]*"worktree"[^{}]*}' | while IFS= read -r e; do
    id=$(jf "$e" task_id); wt=$(jf "$e" worktree); tk=$(jf "$e" task); ti=$(jf "$e" title)
    if [ -n "$wt" ] && git -C "$wt" rev-parse HEAD >/dev/null 2>&1; then
      h=$(git -C "$wt" rev-parse HEAD); d=$(git -C "$wt" status --porcelain | wc -l | tr -d ' ')
    else h=missing; d=0; fi
    printf 'work\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id:--}" "${wt:--}" "$h" "$d" "${tk:--}" "${ti:--}"
  done
} > "$tmpf" && mkdir -p "$dir" && mv -f "$tmpf" "$dir/suspend.record" || die 5 "cannot write $dir/suspend.record"
echo "org-suspend: recorded to $dir/suspend.record; every terminal is still alive"
