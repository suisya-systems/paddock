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
# Every outcome after the hook counted the round is recorded (Issue #253): the last line goes to
# `org --as codex-gate codex_round result` as codex_round_passed or codex_round_failed, with the
# round, so the result does not rest on the worker quoting it. The task is the worktree's folder
# name, as the hook reads it ($CLAUDE_PROJECT_DIR, else the repository's top folder).
set -uo pipefail

[ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = --design ]; } || {
  echo "usage: bash \"\$PADDOCK_CODEX_GATE\" [--design]" >&2; exit 2; }
mode=diff; [ "${1:-}" = --design ] && mode=design
# The base org-delegate recorded for this task (Issues #177, #323), else origin/main. It is the file
# <state>/bases/<task>, which only the secretary writes (the task is the worktree's folder name, as in end() below);
# a worktree made before #323 has it in git config (branch.<b>.paddockBase) instead.
pd=${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}; pd=${pd%/}
base=$(head -n 1 "${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}/bases/${pd##*/}" 2>/dev/null) || base=
[ -n "$base" ] || base=$(git config --get "branch.$(git rev-parse --abbrev-ref HEAD 2>/dev/null).paddockBase" 2>/dev/null) || base=
base=${base:-origin/main}
design=.worker-scratch/design.md
# end <status> <last line>: record the result, then print the last line and exit
end() {
  local pd task d= err
  pd=${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}; pd=${pd%/}; task=${pd##*/}
  [ "$mode" = design ] && d=--design
  if [ -z "${PADDOCK_ORG:-}" ]; then echo "result not recorded: PADDOCK_ORG is not set"
  elif ! err=$(bash "$PADDOCK_ORG" --as codex-gate codex_round result --task "$task" $d "$2" 2>&1 >/dev/null); then
    echo "result not recorded: $err"
  fi
  echo "$2"; exit "$1"
}

if [ "$mode" = design ]; then
  [ -s "$design" ] || end 2 "CODEX_GATE: not-established (no design to review: write it to $design first)"
else
  dirty=$(git status --porcelain --untracked-files=no) \
    || { end 1 "CODEX_GATE: not-established (git status failed)"; }
  if [ -n "$dirty" ]; then
    printf '%s\n' "$dirty"
    end 4 "CODEX_GATE: dirty-worktree (commit first; HEAD=$(git rev-parse --short HEAD 2>/dev/null))"
  fi
  git rev-parse --verify -q "$base^{commit}" >/dev/null && ! git diff --quiet "$base...HEAD" 2>/dev/null \
    || { end 1 "CODEX_GATE: not-established (no change against $base, or no $base: nothing to review)"; }
fi

# Issues #298, #364: this runs from the core's PATH, which may lack codex's folder, and may hold a
# different codex than the one the person set up. org-start recorded the stable path it found beside
# this script (codex-path); that one runs when it exists, else the one on PATH. prepare's codex-cli
# check uses the same order (scripts/probes/prototype-3.sh, codex_gate_lookup).
cp=$(head -n 1 "$(dirname "$0")/codex-path" 2>/dev/null)
if [ -n "$cp" ] && [ -x "$cp" ]; then PATH=$(dirname "$cp"):$PATH; codex_bin=$cp; else codex_bin=$(command -v codex 2>/dev/null); fi
[ -n "$codex_bin" ] || { end 3 "CODEX_GATE: unavailable (the reviewing CLI is not installed)"; }
codex_ver=$("$codex_bin" --version 2>/dev/null | head -n 1)
echo "reviewer: $codex_bin ${codex_ver:-unknown version}"

# The reviewer keeps its login and settings in CODEX_HOME. A worker's sandbox may not let it write
# there, and it refuses a home under a temp folder, so it gets a folder in the worktree that links
# the existing login. Do not commit it.
src=${CODEX_HOME:-$HOME/.codex}
export CODEX_HOME=$PWD/.codex-home
# This script runs outside the worker sandbox (Issue #177), in a folder the worker writes: write nothing
# through a path the worker could have turned into a link.
[ ! -L "$CODEX_HOME" ] || { end 1 "CODEX_GATE: not-established ($CODEX_HOME is a symlink)"; }
mkdir -p "$CODEX_HOME"
src=$(cd "$src" 2>/dev/null && pwd -P)
if [ -n "$src" ] && [ "$src" != "$(cd "$CODEX_HOME" && pwd -P)" ]; then
  ln -sfn "$src/auth.json" "$CODEX_HOME/auth.json"; ln -sfn "$src/config.toml" "$CODEX_HOME/config.toml"
fi

log=$(mktemp "${TMPDIR:-/tmp}/second-review-$mode.XXXXXX") || { end 1 "CODEX_GATE: not-established (cannot create the log)"; }
if [ "$mode" = design ]; then
  prompt="Read the design at $design and verify it against this repository: every file, function, flag, hook and path it relies on exists and works as assumed, and the design reaches its stated goal without gaps. List findings as Blocker / Major / Minor, each with evidence (file:line) and a concrete fix."
  "$codex_bin" exec -c model_reasoning_effort=high -c sandbox_mode='"read-only"' "$prompt" </dev/null 2>&1 | tee "$log"
else
  "$codex_bin" exec review --base "$base" -c model_reasoning_effort=medium -c sandbox_mode='"read-only"' </dev/null 2>&1 | tee "$log"
fi
status=${PIPESTATUS[0]}

ok=$(grep -cE '^ *succeeded in [0-9]+(ms|s|m)' "$log"); bad=$(grep -cE '^ *(failed|exited [0-9]+) in [0-9]+(ms|s|m)' "$log")
summary="succeeded=$ok failed=$bad status=$status codex=$codex_bin ${codex_ver:-unknown version} log=$log"
if [ "$ok" -ge 1 ] && [ "$bad" -eq 0 ] && [ "$status" -eq 0 ]; then end 0 "CODEX_GATE: passed ($summary)"; fi
end 1 "CODEX_GATE: not-established ($summary; HEAD=$(git rev-parse --short HEAD 2>/dev/null))"
