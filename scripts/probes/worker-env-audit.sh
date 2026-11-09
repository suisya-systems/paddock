#!/bin/sh
# Probe for Issue #34 (L-N4; absorbs #41, L-K2 environment half): does a worker
# launched the way the delegation flow launches it inherit none of the
# secretary's session secrets and no GitHub credentials, under the Q17 (d)
# arrangement (core started from a login shell + template command prefixed with
# `env -u` for the session-bound CLAUDE* variables)?
#
# Run from the repo root, on a host where herdr core (hc) and claude run, in the
# terminal that starts (or already runs) the core:
#   sh scripts/probes/worker-env-audit.sh
# Takes about 2-4 minutes (up to 240 s of polling). Needs: hc and claude on
# PATH, a logged-in claude, POSIX sh, env, cut, sort, grep, cksum. gh is
# optional (without it the gh-auth-status result is "gh-missing"). Starts four
# terminals named p34-* and four temporary templates (p34-*); the cleanup trap
# removes both. The script answers Claude Code's folder-trust and
# bypass-permissions dialogs in the probe terminals itself (the probe terminals
# run in a throw-away directory with --dangerously-skip-permissions). No
# manual step is expected; if "RESULT done: no" appears, attach to the named
# terminal (`hc attach p34-ccl`) and look for a dialog the script did not know.
#
# How the runner shell matters. Run it twice if you can:
#   A. from inside a Claude Code session that already has the CLAUDE_CODE_*
#      variables (the bad case: the core inherits them). Tests the template
#      prefix (Q17 b). The control terminal must show the variables, else the
#      core was already clean and (b) was not exercised (see "RESULT control").
#   B. from a plain login shell with no agent above it (Q17 a + b together).
# If the core is already running, its environment is whatever started it; stop
# it first only if it is yours alone (hc server stop affects every terminal).
#
# What it does:
#   1. Writes four temporary templates. Their prefix is read from the `command:`
#      line of templates/secretary.md (everything before the final word
#      `claude`), so the probe tests the list the secretary really uses.
#        p34-control       NO prefix. `sh dump.sh` only. Shows what a terminal
#                          gets from the core when nothing is removed.
#        p34-parent        secretary-like: <prefix> claude; its first message
#                          makes it dump its own environment and launch the two
#                          children below with `hc run --bg --outlive-parent`
#                          from inside its terminal (the delegation flow).
#        p34-child-sh      <prefix> sh dump.sh (no Claude Code in between).
#        p34-child-claude  <prefix> claude; its task is to run dump.sh.
#   2. Starts the control and the parent from here, answers dialogs, waits until
#      both children have written their dumps.
#   3. dump.sh writes, per terminal: variable names only (env | cut -d= -f1 |
#      sort), a checksum per CLAUDE*/GH_*/GITHUB_* variable (values are never
#      printed; the checksum only tells "same as the runner's" from "different"),
#      and the exit code of `gh auth status`. The script also reads the screen
#      of the parent and the claude child for "Transcript saving is off".
#
# Reading the output. Every line starting RESULT is one verdict:
#   RESULT control: yes|no          yes = a terminal with no prefix got the
#       session variables, so the test is meaningful. no = the core is clean
#       (the (b) half was not exercised; (a) held by construction).
#   RESULT <t> session-vars: PASS|FAIL      t = parent, child-sh, child-claude.
#       Per variable (CLAUDE_CODE_CHILD_SESSION, CLAUDE_CODE_SESSION_ID,
#       CLAUDE_CODE_MESSAGING_SOCKET, CLAUDE_CODE_MESSAGING_TOKEN) the detail
#       line says absent / same-as-baseline / differs-from-baseline.
#       PASS = every one absent, or (claude terminals only) present with a value
#       that differs from every baseline (Claude Code set its own).
#       FAIL = any one present with a baseline's value; for child-sh, any
#       present at all. INCONCLUSIVE = present but no baseline holds it.
#   RESULT transcript-notice <t>: absent|PRESENT   "Transcript saving is off"
#       on the screen of the parent / claude child. PASS = absent for both.
#   RESULT <t> gh-env: PASS|FAIL    FAIL = any of GH_TOKEN, GITHUB_TOKEN,
#       GH_ENTERPRISE_TOKEN, GITHUB_ENTERPRISE_TOKEN, GH_CONFIG_DIR is in the
#       terminal's environment.
#   RESULT <t> gh-auth-status: fails|SUCCEEDS|gh-missing   PASS (L-K2) =
#       fails. SUCCEEDS with gh-env PASS means the credentials come from outside
#       the environment (the gh config file under the person's home): record it
#       as a finding, it is not an environment leak.
#   LIST lines: CLAUDE* names seen in the control, those still present in
#       child-sh, and those that child-sh shares with the runner. The last list
#       is the candidates to add to the template's `env -u`; judge each name.
#   RESULT done: yes|no     yes = both children wrote their dumps in time.
# Overall pass for #34: control yes, session-vars PASS for all three, transcript
# notice absent for both, and for #41: gh-env PASS and gh-auth-status fails.
# Paste everything back. Output holds names and verdicts only, no values.
set -u

TPLSRC=templates/secretary.md
TPL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-core/templates"
NAMES="p34-parent p34-ccl p34-csh p34-ctl"
VARS4="CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN"
GHVARS="GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_CONFIG_DIR"

has() { hc ls 2>&1 | grep -Eq "(^|[^A-Za-z0-9_-])$1([^A-Za-z0-9_-]|\$)"; }

[ -f "$TPLSRC" ] || { echo "RESULT precondition-failed: run from the repo root ($TPLSRC not found)"; exit 1; }
CMD=$(sed -n 's/^command: //p' "$TPLSRC")
case "$CMD" in
  *" claude") PREFIX=${CMD% claude} ;;
  *) echo "RESULT precondition-failed: $TPLSRC command does not end in ' claude'"; exit 1 ;;
esac
for t in p34-control p34-parent p34-child-sh p34-child-claude; do
  [ -e "$TPL_DIR/$t.md" ] && { echo "RESULT precondition-failed: $TPL_DIR/$t.md exists; remove it first"; exit 1; }
done
for n in $NAMES; do
  has $n && { echo "RESULT precondition-failed: terminal $n already exists"; exit 1; }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/probe34.XXXXXX") || exit 1 # private (0700): dumps hold secrets
OUT="$WORK/out"; CWD="$WORK/cwd"
mkdir -p "$OUT" "$CWD" "$TPL_DIR" || exit 1
cleanup() {
  for n in $NAMES; do hc kill $n >/dev/null 2>&1; hc rm $n >/dev/null 2>&1; done
  for t in p34-control p34-parent p34-child-sh p34-child-claude; do rm -f "$TPL_DIR/$t.md"; done
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# dump.sh: usage sh dump.sh <path-prefix>. Names, checksums (never values), gh exit code; .rc written last.
cat > "$OUT/dump.sh" <<'D'
p=$1
env | cut -d= -f1 | sort > "$p.names"
env | grep -E '^(CLAUDE|GH_|GITHUB_)' | while IFS== read -r k v; do
  printf '%s %s\n' "$k" "$(printf %s "$v" | cksum | cut -d' ' -f1)"
done > "$p.vars"
if command -v gh >/dev/null 2>&1; then gh auth status > "$p.gh" 2>&1; echo $? > "$p.gh.rc"; else echo 127 > "$p.gh.rc"; fi
echo done > "$p.rc"
D

mk() { # $1 = template name, $2 = command
  printf -- '---\ndescription: probe 34 (temporary)\ncommand: %s\n---\nProbe 34. Ignore.\n' "$2" > "$TPL_DIR/$1.md"
}
mk p34-control "sh $OUT/dump.sh $OUT/ctl"
mk p34-child-sh "$PREFIX sh $OUT/dump.sh $OUT/csh"
mk p34-child-claude "$PREFIX claude --dangerously-skip-permissions"
mk p34-parent "$PREFIX claude --dangerously-skip-permissions"

echo "== versions"; hc --version 2>&1; claude --version 2>&1
echo "== prefix under test (from $TPLSRC): $PREFIX"
sh "$OUT/dump.sh" "$OUT/run" # the runner's own environment, for comparison

CHILD_TASK="Run this one shell command with your Bash tool: sh $OUT/dump.sh $OUT/ccl   Then reply with the single word done and nothing else."
PARENT_MSG="Probe 34, environment audit. Run these three shell commands with your Bash tool, one at a time, in this order, and do nothing else. 1) sh $OUT/dump.sh $OUT/par   2) hc run --bg --outlive-parent --name p34-csh --cwd $CWD --label task_id=p34 p34-child-sh   3) hc run --bg --outlive-parent --name p34-ccl --cwd $CWD --label task_id=p34 p34-child-claude \"$CHILD_TASK\"   Then reply with the single word done."

echo "== start control and parent"
hc run --bg --name p34-ctl --cwd "$CWD" p34-control || { echo "RESULT precondition-failed: control launch failed"; exit 1; }
hc run --bg --name p34-parent --cwd "$CWD" p34-parent "$PARENT_MSG" || { echo "RESULT precondition-failed: parent launch failed"; exit 1; }

PNOTE=absent; CNOTE=absent
settle() { # $1 = terminal; answers known dialogs, sets the note flag via the caller
  has "$1" || return 1
  screen=$(hc read "$1" 2>&1)
  case "$screen" in
    *"Quick safety check"*|*"Bypass Permissions mode"*) echo "-- $1: answering dialog"; hc keys "$1" down enter >/dev/null 2>&1 ;;
  esac
  case "$screen" in *"Transcript saving is off"*) return 2 ;; esac
  return 0
}
echo "== wait for both children to write their dumps (up to 240 s)"
t=0
while [ $t -lt 240 ]; do
  settle p34-parent; [ $? -eq 2 ] && PNOTE=PRESENT
  settle p34-ccl; [ $? -eq 2 ] && CNOTE=PRESENT
  [ -f "$OUT/csh.rc" ] && [ -f "$OUT/ccl.rc" ] && [ -f "$OUT/par.rc" ] && break
  t=$((t + 3)); sleep 3
done
sleep 2
settle p34-parent; [ $? -eq 2 ] && PNOTE=PRESENT
settle p34-ccl; [ $? -eq 2 ] && CNOTE=PRESENT

ck() { grep "^$2 " "$OUT/$1.vars" 2>/dev/null | cut -d' ' -f2; } # checksum of variable $2 in dump $1

# verdict <dump> <label> <strict> [extra]: strict=1 means any presence fails (no Claude Code in between).
# Baselines for "inherited": the control dump (what the core hands out), the runner, and, when given,
# the dump <extra> (the parent, for the Claude child).
verdict() {
  [ -f "$OUT/$1.rc" ] || { echo "RESULT $2 session-vars: NO DATA"; return; }
  res=PASS
  for v in $VARS4; do
    mine=$(ck "$1" $v); c=$(ck ctl $v); r=$(ck run $v); x=; [ -n "${4:-}" ] && x=$(ck "$4" $v)
    if [ -z "$mine" ]; then d=absent
    elif [ "$mine" = "$c" ] || [ "$mine" = "$r" ] || { [ -n "$x" ] && [ "$mine" = "$x" ]; }; then d=same-as-baseline; res=FAIL
    elif [ "$3" = 1 ]; then d=present; res=FAIL
    elif [ -n "$c$r$x" ]; then d=differs-from-baseline
    else d="present (no baseline has it; cannot tell inherited from own)"; [ $res = PASS ] && res=INCONCLUSIVE; fi
    echo "   $2 $v: $d"
  done
  echo "RESULT $2 session-vars: $res"
  g=PASS; for v in $GHVARS; do grep -qx "$v" "$OUT/$1.names" && { echo "   $2 $v: present"; g=FAIL; }; done
  echo "RESULT $2 gh-env: $g"
  case "$(cat "$OUT/$1.gh.rc" 2>/dev/null)" in
    0) echo "RESULT $2 gh-auth-status: SUCCEEDS" ;;
    127) echo "RESULT $2 gh-auth-status: gh-missing" ;;
    "") echo "RESULT $2 gh-auth-status: NO DATA" ;;
    *) echo "RESULT $2 gh-auth-status: fails" ;;
  esac
}

echo "== results"
if [ -f "$OUT/csh.rc" ] && [ -f "$OUT/ccl.rc" ] && [ -f "$OUT/par.rc" ]; then echo "RESULT done: yes"; else echo "RESULT done: no (missing: $(for f in par csh ccl; do [ -f "$OUT/$f.rc" ] || printf '%s ' $f; done))"; fi
if [ -f "$OUT/ctl.rc" ]; then
  n=0; for v in $VARS4; do [ -n "$(ck ctl $v)" ] && n=$((n + 1)); done
  if [ $n -gt 0 ]; then echo "RESULT control: yes ($n of 4 session variables present in a terminal with no prefix)"; else echo "RESULT control: no (the core is clean; the env -u prefix was not exercised)"; fi
  g=; for v in $GHVARS; do grep -qx "$v" "$OUT/ctl.names" && g="$g $v"; done
  echo "   control GitHub variables present:${g:- none}"
  case "$(cat "$OUT/ctl.gh.rc" 2>/dev/null)" in 0) echo "   control gh auth status: succeeds" ;; 127) echo "   control gh auth status: gh-missing" ;; *) echo "   control gh auth status: fails" ;; esac
else echo "RESULT control: NO DATA"; fi
verdict par parent 0
verdict csh child-sh 1
verdict ccl child-claude 0 par
[ -f "$OUT/par.rc" ] || PNOTE="NO DATA (parent never ran its dump)"
[ -f "$OUT/ccl.rc" ] || CNOTE="NO DATA (child never ran its dump)"
echo "RESULT transcript-notice parent: $PNOTE"
echo "RESULT transcript-notice child-claude: $CNOTE"

claude_names() { grep '^CLAUDE' "$OUT/$1.names" 2>/dev/null | tr '\n' ' '; }
echo "LIST CLAUDE* names in control: $(claude_names ctl)"
echo "LIST CLAUDE* names still in child-sh: $(claude_names csh)"
echo "LIST candidates (in child-sh and in the runner): $(grep '^CLAUDE' "$OUT/csh.names" 2>/dev/null | grep -Fxf "$OUT/run.names" | tr '\n' ' ')"
echo "== final screens (parent, child-claude) for a manual look"
hc read p34-parent 2>&1 | tail -n 15
hc read p34-ccl 2>&1 | tail -n 15
echo "== done; paste everything above back (cleanup runs now)"
