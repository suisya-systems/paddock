#!/usr/bin/env bash
# The review by a second model (Issue #177, inventory L-K10 / GT-2). The worker runs it, alone, from
# its worktree, in the foreground:
#   bash "$PADDOCK_CODEX_GATE"            review of the commits ahead of origin/main
#   bash "$PADDOCK_CODEX_GATE" --design   review of .worker-scratch/design.md against the repository
# No other argument: the round counter's hook (scripts/org codex_round hook) counts only these two
# exact calls, so a round cannot be taken in any other form. The hook counts the round; this script
# does not. The last line says what happened, and only "passed" lets the worker read the findings
# as a review that happened:
#   0 CODEX_GATE: passed           a command ran, none failed, the reviewer exited 0
#   1 CODEX_GATE: not-established  an empty pass (no command ran), a failure, or nothing to review
#   2 usage error (an argument, or no / empty design file)
#   3 CODEX_GATE: unavailable      the reviewing CLI is not installed
#   4 CODEX_GATE: dirty-worktree   tracked files differ from HEAD; the reviewer would read a stale diff
# An "empty pass": when the reviewer cannot place its helpers it runs no command and prints a
# no-findings text with exit 0. So success is judged by a recorded command run ("succeeded in <time>"
# at a line start), not by the absence of an error.
set -uo pipefail

[ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = --design ]; } || {
  echo "usage: bash \"\$PADDOCK_CODEX_GATE\" [--design]" >&2; exit 2; }
mode=diff; [ "${1:-}" = --design ] && mode=design
# The base org-delegate recorded for this branch (Issue #177), else origin/main.
base=$(git config --get "branch.$(git rev-parse --abbrev-ref HEAD 2>/dev/null).paddockBase" 2>/dev/null) || base=
base=${base:-origin/main}
design=.worker-scratch/design.md

if [ "$mode" = design ]; then
  [ -s "$design" ] || { echo "no design to review: write it to $design first" >&2; exit 2; }
else
  dirty=$(git status --porcelain --untracked-files=no) \
    || { echo "CODEX_GATE: not-established (git status failed)"; exit 1; }
  if [ -n "$dirty" ]; then
    printf '%s\n' "$dirty"
    echo "CODEX_GATE: dirty-worktree (commit first; HEAD=$(git rev-parse --short HEAD 2>/dev/null))"; exit 4
  fi
  git rev-parse --verify -q "$base^{commit}" >/dev/null && ! git diff --quiet "$base...HEAD" 2>/dev/null \
    || { echo "CODEX_GATE: not-established (no change against $base, or no $base: nothing to review)"; exit 1; }
fi

command -v codex >/dev/null 2>&1 || { echo "CODEX_GATE: unavailable (the reviewing CLI is not installed)"; exit 3; }

# The reviewer keeps its login and settings in CODEX_HOME. A worker's sandbox may not let it write
# there, and it refuses a home under a temp folder, so it gets a folder in the worktree that links
# the existing login. Do not commit it.
src=${CODEX_HOME:-$HOME/.codex}
export CODEX_HOME=$PWD/.codex-home
# This script runs outside the worker sandbox (Issue #177), in a folder the worker writes: write nothing
# through a path the worker could have turned into a link.
[ ! -L "$CODEX_HOME" ] || { echo "CODEX_GATE: not-established ($CODEX_HOME is a symlink)"; exit 1; }
mkdir -p "$CODEX_HOME"
src=$(cd "$src" 2>/dev/null && pwd -P)
if [ -n "$src" ] && [ "$src" != "$(cd "$CODEX_HOME" && pwd -P)" ]; then
  ln -sfn "$src/auth.json" "$CODEX_HOME/auth.json"; ln -sfn "$src/config.toml" "$CODEX_HOME/config.toml"
fi

log=$(mktemp "${TMPDIR:-/tmp}/second-review-$mode.XXXXXX") || { echo "CODEX_GATE: not-established (cannot create the log)"; exit 1; }
if [ "$mode" = design ]; then
  prompt="Read the design at $design and verify it against this repository: every file, function, flag, hook and path it relies on exists and works as assumed, and the design reaches its stated goal without gaps. List findings as Blocker / Major / Minor, each with evidence (file:line) and a concrete fix."
  codex exec -c model_reasoning_effort=high -c sandbox_mode='"read-only"' "$prompt" </dev/null 2>&1 | tee "$log"
else
  codex exec review --base "$base" -c model_reasoning_effort=medium -c sandbox_mode='"read-only"' </dev/null 2>&1 | tee "$log"
fi
status=${PIPESTATUS[0]}

ok=$(grep -cE '^ *succeeded in [0-9]+(ms|s|m)' "$log"); bad=$(grep -cE '^ *(failed|exited [0-9]+) in [0-9]+(ms|s|m)' "$log")
summary="succeeded=$ok failed=$bad status=$status log=$log"
if [ "$ok" -ge 1 ] && [ "$bad" -eq 0 ] && [ "$status" -eq 0 ]; then echo "CODEX_GATE: passed ($summary)"; exit 0; fi
echo "CODEX_GATE: not-established ($summary; HEAD=$(git rev-parse --short HEAD 2>/dev/null))"; exit 1
