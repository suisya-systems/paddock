#!/bin/sh
# Probe for Issue #47 (Q17): can terminal.run's `env` remove an inherited
# variable, or only add and override?
#
# Run from the repo root, on a host where herdr core is reachable by `hc`:
#   sh scripts/probes/env-remove-var.sh
# Takes about 15 seconds. Needs only sh, hc, env, grep, sleep. Starts no
# long-lived process: each probe terminal runs `env > file` and exits.
#
# How it works: it calls terminal.run through `hc connect` five times with a
# different `env`, each time running `env` inside the terminal and saving the
# result to a file. The variable under test is HOME (always set in the core's
# own environment, so it is inherited by every terminal). If CLAUDE_CODE_CHILD_SESSION
# is set in the core's environment it is tested the same way.
#
# Reading the output (one block per case, "<case>: <result>"):
#   baseline    no env param.      Must show VAR=<value>, else the probe is void.
#   override    env {VAR:"x"}.     Expect VAR=x (control: override works).
#   add         env {NEW:"1"}.     Expect NEW=1 (control: add works).
#   empty       env {VAR:""}.      "VAR=" present  -> empty string sets, does not remove.
#                                  VAR absent      -> empty string removes.
#   null        env {VAR:null}.    VAR absent      -> null removes.
#                                  "VAR=" present  -> null is read as empty string.
#                                  VAR=<value>     -> null is ignored (inherited value stays).
#                                  rpc error       -> null is rejected (see the error line).
# Q17 option (c) can clear a variable without a shell wrapper only if the
# empty or null case shows the variable ABSENT. "VAR=" present is not enough
# for CLAUDE_CODE_CHILD_SESSION if Claude Code tests for presence.
#
# Null: the schema types env values as strings, so null is expected to be rejected (invalid_params).
# If every case prints "rpc error" about parameters, check terminal.run in hc schema and fix cmd_json.
set -u

OUT=$(mktemp -d "${TMPDIR:-/tmp}/probe47.XXXXXX") || exit 1 # private (0700): env dumps hold secrets
trap 'rm -rf "$OUT"' EXIT INT TERM

VAR=HOME
# terminal.run `line` (run by sh -c); params per hc schema: argv, line, env (string values only).
# $1 = output file.
cmd_json() { printf "\"env > %s\"" "$1"; }

echo "== hc schema: terminal.run is under .methods[] (name terminal.run); env values must be strings =="
echo "== hc version =="; hc --version 2>&1

call() { # $1 = case name, $2 = env JSON object or "" for none
  f="$OUT/$1.env"
  if [ -n "$2" ]; then envp=",\"env\":$2"; else envp=""; fi
  req="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"terminal.run\",\"params\":{\"line\":$(cmd_json "$f")$envp}}"
  echo "-- $1: $req"
  # Keep input open: hc connect can exit at end of input before answering.
  { printf '%s\n' "$req"; sleep 2; } | hc connect > "$OUT/$1.resp" 2>&1
  sleep 1
  grep -q '"error"' "$OUT/$1.resp" 2>/dev/null && { echo "$1: rpc error: $(cat "$OUT/$1.resp")"; return; }
  [ -f "$f" ] || { echo "$1: no output file (terminal did not run). response: $(cat "$OUT/$1.resp")"; return; }
}

show() { # $1 = case, $2 = variable
  [ -f "$OUT/$1.env" ] || return
  line=$(grep "^$2=" "$OUT/$1.env")
  if [ -n "$line" ]; then echo "$1: $line"; else echo "$1: $2 ABSENT"; fi
}

call baseline ""
call override "{\"$VAR\":\"x\"}"
call add '{"PROBE47_NEW":"1"}'
call empty "{\"$VAR\":\"\"}"
call null "{\"$VAR\":null}"

echo "== results for $VAR =="
show baseline $VAR; show override $VAR; show empty $VAR; show null $VAR
show add PROBE47_NEW

if grep -q '^CLAUDE_CODE_CHILD_SESSION=' "$OUT/baseline.env" 2>/dev/null; then
  V=CLAUDE_CODE_CHILD_SESSION
  call empty2 "{\"$V\":\"\"}"
  call null2 "{\"$V\":null}"
  echo "== results for $V (inherited by the core) =="
  show baseline $V; show empty2 $V; show null2 $V
else
  echo "== CLAUDE_CODE_CHILD_SESSION not in the core's environment; skipped =="
fi
echo "== done; paste everything above back =="
