#!/bin/sh
# Probe for Issue #177 (L-K10, GT-2, HK-14; G2): can the reviewing CLI run from inside a paddock
# worker's sandbox with the shipped settings (templates/worker-settings.json), through
# scripts/second-model-review.sh, or must the secretary run the review for the worker?
#
# Run from the repo root in a login shell on the host (not inside an agent), no argument:
#   sh scripts/probes/second-model-review-reach.sh
# Needs claude and the reviewing CLI (both logged in), git, timeout, mktemp, grep, sed. One `claude -p`
# run, up to PADDOCK_PROBE_WAIT s (default 400). It makes the folder $HOME/paddock-probe-177.XXXXXX
# (the exit trap removes it and restores the claude link, Issues #212, #213): a git repository with one commit ahead of a local origin/main ref. The
# round count and the history go to folders under it (PADDOCK_CODEX_DIR, PADDOCK_STATE_DIR), so the
# real counter is not touched. The reviewing CLI really runs once, on a one-line file.
# The run starts like a worker: `claude -p --settings <the template with the gate calls filled in, as
# org-delegate writes them: exact strings in sandbox.excludedCommands and permissions.allow> --tools Bash
# --allowedTools Bash`, with PADDOCK_ORG and PADDOCK_CODEX_GATE set as the worker template sets them,
# and is told to run exactly `bash "$PADDOCK_CODEX_GATE"`, keep the sandbox ON and not retry a refused
# call another way. A refusal is a valid result.
#
# Reading the output. Every verdict line starts with "RESULT <name>:".
#   env        INFO = versions.
#   run        INFO = exit code of claude -p (124 = timeout).
#   gate       the last line the gate printed, read from the run's log: passed = the CLI ran inside
#              the sandbox (REACHES); not-established, unavailable or dirty-worktree = it did not
#              run to a review there (the secretary must run it for the worker, or the settings need
#              an excluded command and the CLI's hosts); no such line = INCONCLUSIVE (the run did not
#              make the call, or a layer refused it: see the log tail).
#   count      INFO = codex_round_started lines in the probe's own counter (1 = the hook counted the call).
set -u
ROOT=$(pwd)
[ -f "$ROOT/templates/worker-settings.json" ] || { echo "RESULT precondition-failed: run from the repo root"; exit 1; }
[ $# -eq 0 ] || { echo "RESULT precondition-failed: no argument"; exit 1; }
for c in claude codex git node timeout mktemp grep sed; do command -v $c >/dev/null 2>&1 || { echo "RESULT precondition-failed: $c not on PATH"; exit 1; }; done
case "$HOME$ROOT" in *[[:space:]\"\'\\]*) echo "RESULT precondition-failed: HOME and the checkout path must have no whitespace, quote or backslash"; exit 1 ;; esac
WAIT=${PADDOCK_PROBE_WAIT:-400}
. "$(dirname "$0")/claude-link.sh"
claude_link_save
T=$(mktemp -d "$HOME/paddock-probe-177.XXXXXX") || { echo "RESULT precondition-failed: mktemp"; exit 1; }
trap 'claude_link_restore; rm -rf "$T"' EXIT; trap 'exit 130' INT TERM
echo "RESULT env: INFO claude=$(claude --version 2>/dev/null | head -n 1) os=$(uname -sr)"

W=$T/work; mkdir -p "$W" "$T/rounds" "$T/state" || exit 1
(cd "$W" && git init -q -b main . && git config user.email probe@example.com && git config user.name probe \
  && echo one > a.txt && git add a.txt && git commit -q -m one && git update-ref refs/remotes/origin/main HEAD \
  && echo two >> a.txt && git commit -q -am two) || { echo "RESULT precondition-failed: cannot build the probe repository"; exit 1; }

GATE=$ROOT/scripts/second-model-review.sh
SET=$T/settings.json
# the same four exact strings org-delegate fills in (quoted and unquoted path, with and without --design)
node -e '
  const [t, g, out] = process.argv.slice(1);
  const s = JSON.parse(require("fs").readFileSync(t, "utf8"));
  const c = ["bash \"" + g + "\"", "bash " + g, "bash \"" + g + "\" --design", "bash " + g + " --design"];
  s.sandbox.excludedCommands = c; s.permissions.allow = c.map(x => "Bash(" + x + ")");
  require("fs").writeFileSync(out, JSON.stringify(s));' "$ROOT/templates/worker-settings.json" "$GATE" "$SET" \
  || { echo "RESULT precondition-failed: cannot write the settings file (node needed)"; exit 1; }
TASK='Probe for paddock Issue #177. This is a permitted measurement of whether the review gate runs in your sandbox. Make exactly one Bash call, in the foreground, with this command text and nothing else (the path written out, no variable): bash "'"$GATE"'"   -- Keep the sandbox ON: never use the Bash option that skips the sandbox, and do not retry a refused call another way. A refusal or an error is a valid result. Then reply with the last line the command printed, verbatim, and the error text if it printed one.'
log=$T/log
(cd "$W" && env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
  -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_SESSION_ATTENDED \
  -u CLAUDE_PID -u CLAUDE_TMPDIR \
  PADDOCK_ORG="$ROOT/scripts/org" PADDOCK_CODEX_GATE="$ROOT/scripts/second-model-review.sh" \
  PADDOCK_CODEX_DIR="$T/rounds" PADDOCK_STATE_DIR="$T/state" \
  timeout "$WAIT" claude -p --settings "$SET" --tools Bash --allowedTools Bash \
    --strict-mcp-config --no-session-persistence --output-format stream-json --verbose "$TASK" \
  > "$log" 2>&1 < /dev/null)
echo "RESULT run: INFO claude -p exited $? (124 = timeout)"
line=$(grep -o 'CODEX_GATE: [a-z-]*' "$log" | tail -n 1)
case "$line" in
  "CODEX_GATE: passed") echo "RESULT gate: REACHES ($line: the reviewing CLI ran inside the worker sandbox)" ;;
  "") echo "RESULT gate: INCONCLUSIVE (no CODEX_GATE line in the log)"; tail -c 1500 "$log" | cut -c1-500 ;;
  *) echo "RESULT gate: DOES NOT REACH ($line)"; grep -o 'CODEX_GATE: [^"]*' "$log" | tail -n 1 | cut -c1-400 ;;
esac
echo "RESULT count: INFO $(cat "$T"/rounds/events/*/codex-gate.jsonl 2>/dev/null | grep -c codex_round_started) codex_round_started line(s)"
