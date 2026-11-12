#!/bin/sh
# Probe for Issue #260 (L-N3 revised): on a real host, (A) what a worker in auto mode still
# prompts for, (B, C) org-escalation relaying the person's Yes / No to a real permission prompt
# only after a fresh screen read, and (D) the folder-trust policy entry with --then-send.
#
# Run from the repo root, on a host where herdr core (hc) and claude run, outside any agent's
# sandbox (the secretary hands it to the person, or runs it with the person's consent):
#   sh scripts/probes/worker-prompt-relay.sh
# Takes about 5-8 minutes, no manual step. Needs: hc, claude (logged in, auto mode available to
# the account), git, POSIX sh. Starts four terminals w-p260a, w-p260r, w-p260n, w-p260t and two
# temporary templates (p260-auto, p260-default); the cleanup trap kills and removes them all.
# Side effects: cases B and C add one approval each to org-state (question text starts with
# "p260 probe") and remove it again; case D's launch makes Claude Code record trust for a
# temporary folder in ~/.claude.json, as any accepted dialog does.
#
# Reading the output (one RESULT line per check):
#   auto-start     INFO  the auto-mode terminal reached its prompt, or what blocked it
#   auto-prompts   INFO  the screen after the worker tried a few risky actions in auto mode:
#                        "prompt" (a permission prompt is open: its text follows) or "none"
#   relay-prompt   PASS  org-escalation prompt exited 3 and printed PROMPT= for a Bash prompt
#   relay-stable   PASS  a second read 3 s later gives the same text (else the checksum relay
#                        would refuse every real prompt; see the ponytail note in the script)
#   relay-yes      PASS  answer yes exited 0 (RELAYED) and the command then ran (file exists)
#   relay-no       PASS  answer no exited 0 and the command did not run (file absent)
#   trust          PASS  prompt exited 0 with POLICY folder-trust and the first message arrived
# Paste the whole output into the issue.

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ESC="$ROOT/skills/org-escalation/scripts/org-escalation.sh"
TPL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-core/templates"
NAMES="w-p260a w-p260r w-p260n w-p260t"

for n in $NAMES; do
  hc get "$n" >/dev/null 2>&1 && { echo "RESULT precondition-failed: terminal $n already exists"; exit 1; }
done
for t in p260-auto p260-default; do
  [ -e "$TPL_DIR/$t.md" ] && { echo "RESULT precondition-failed: $TPL_DIR/$t.md exists; remove it first"; exit 1; }
done

WORK=$(mktemp -d) || exit 1
mkdir -p "$WORK/a" "$WORK/r" "$WORK/n" "$WORK/t" "$TPL_DIR" || exit 1
. "$(dirname "$0")/claude-link.sh"
claude_link_save
cleanup() {
  claude_link_restore
  for n in $NAMES; do hc kill "$n" >/dev/null 2>&1; hc rm "$n" >/dev/null 2>&1; done
  rm -f "$TPL_DIR/p260-auto.md" "$TPL_DIR/p260-default.md"
  echo "== left for you to look at or delete: $WORK"
}
trap cleanup EXIT INT TERM

cat > "$TPL_DIR/p260-auto.md" <<'T'
---
description: probe 260, auto permission mode (temporary)
command: claude --permission-mode auto
---
Probe 260. Do only what the task says.
T
cat > "$TPL_DIR/p260-default.md" <<'T'
---
description: probe 260, default permission mode (temporary)
command: claude --permission-mode default
---
Probe 260. Do only what the task says.
T

state_of() { hc get --json "$1" 2>/dev/null | tr -d '\n' | sed -n 's/.*"status" *: *{[^}]*"state" *: *"\([a-z_]*\)".*/\1/p'; }
wait_state() { # wait_state <terminal> <regex> <seconds>
  i=0; while [ "$i" -lt "$3" ]; do state_of "$1" | grep -Eq "$2" && return 0; i=$((i + 1)); sleep 1; done; return 1
}
ready() { # ready <terminal>: up to 90 s for an empty prompt
  i=0; while [ "$i" -lt 90 ]; do
    hc read "$1" 2>/dev/null | grep -Eq 'for shortcuts|\? for|^❯' && return 0; i=$((i + 1)); sleep 1
  done; return 1
}

echo "== A. auto mode: what still prompts"
hc run --bg --name w-p260a --cwd "$WORK/a" p260-auto >/dev/null 2>&1 || echo "hc run w-p260a failed"
if ready w-p260a; then echo "RESULT auto-start: INFO reached the prompt"; else
  echo "RESULT auto-start: INFO no empty prompt after 90 s; screen:"; hc read w-p260a 2>&1 | tail -n 20; fi
sleep 3; hc send w-p260a "Probe task. Do these in order, each as its own tool call, and keep going if one is refused: (1) run: touch ok.txt (2) write the file .claude/settings.local.json with the content {} (3) run: curl -sI https://example.com (4) run: git push origin HEAD. Then say done." >/dev/null 2>&1
wait_state w-p260a 'blocked|idle|done' 120
s=$(state_of w-p260a); scr=$(hc read w-p260a 2>&1)
if printf '%s\n' "$scr" | grep -Eq 'Do you want|❯ *1\. Yes'; then
  echo "RESULT auto-prompts: INFO prompt (state $s); the prompt:"; printf '%s\n' "$scr" | tail -n 15
else
  echo "RESULT auto-prompts: INFO none (state $s); the screen's last lines:"; printf '%s\n' "$scr" | tail -n 25
fi

relay() { # relay <task> <dir> <yes|no>: start, reach a Bash prompt, record it, answer
  t=$1; w=w-$1; f=$2/p260-$3.txt
  hc run --bg --name "$w" --cwd "$2" p260-default >/dev/null 2>&1 || { echo "hc run $w failed"; return 1; }
  ready "$w" || { echo "-- $w: no prompt after 90 s"; hc read "$w" 2>&1 | tail -n 15; }
  sleep 3; hc send "$w" "Probe task. Run exactly this shell command with your Bash tool and nothing else: touch $f" >/dev/null 2>&1
  wait_state "$w" blocked 90 || { echo "-- $w never blocked; state $(state_of "$w")"; hc read "$w" 2>&1 | tail -n 15; }
  out=$(bash "$ESC" prompt --task "$t" 2>&1); rc=$?
  p=$(printf '%s\n' "$out" | sed -n 's/^PROMPT=//p')
  if [ "$3" = yes ]; then
    if [ "$rc" -eq 3 ] && [ -n "$p" ]; then echo "RESULT relay-prompt: PASS"; else echo "RESULT relay-prompt: FAIL rc=$rc $out"; fi
    sleep 3; p2=$(bash "$ESC" prompt --task "$t" 2>&1 | sed -n 's/^PROMPT=//p')
    if [ -n "$p" ] && [ "$p" = "$p2" ]; then echo "RESULT relay-stable: PASS"; else
      echo "RESULT relay-stable: FAIL"; echo "first : $p"; echo "second: $p2"; fi
  fi
  id=$(bash "$ESC" ask --task "$t" --question "p260 probe: let $w run touch?" --prompt "$p" \
         --background "Probe for Issue #260; answered by the probe itself." --if-yes "The file is made." \
         --if-no "Nothing runs." --recommend "$3" --why "probe" 2>&1 | sed -n 's/^APPROVAL_ID=//p')
  a=$(bash "$ESC" answer --id "$id" --text "$3" 2>&1); arc=$?
  if [ "$arc" -eq 10 ]; then # what changed between the recorded prompt and the screen now
    echo "-- recorded: $p"; echo "-- now     : $(bash "$ESC" prompt --task "$t" 2>&1 | sed -n 's/^PROMPT=//p')"
    echo "-- full screen now:"; hc read "$w" 2>&1
  fi
  sleep 8
  case $3 in
    yes) if [ "$arc" -eq 0 ] && [ -e "$f" ]; then echo "RESULT relay-yes: PASS ($a)"; else
           echo "RESULT relay-yes: FAIL rc=$arc ($a), file $( [ -e "$f" ] && echo exists || echo absent )"; fi ;;
    no)  if [ "$arc" -eq 0 ] && [ ! -e "$f" ]; then echo "RESULT relay-no: PASS ($a)"; else
           echo "RESULT relay-no: FAIL rc=$arc ($a), file $( [ -e "$f" ] && echo exists || echo absent )"; fi ;;
  esac
  [ -z "$id" ] || bash "$ESC" remove --id "$id" >/dev/null 2>&1
  echo "-- $w after the answer: state $(state_of "$w")"; hc read "$w" 2>&1 | tail -n 8
}
echo "== B. relay yes"; relay p260r "$WORK/r" yes
echo "== C. relay no";  relay p260n "$WORK/n" no

echo "== D. folder-trust (a fresh git repository, which shows the dialog)"
git init -q "$WORK/t" && git -C "$WORK/t" -c user.name=p -c user.email=p@p.invalid commit -q --allow-empty -m init
hc run --bg --name w-p260t --cwd "$WORK/t" p260-default >/dev/null 2>&1 || echo "hc run w-p260t failed"
i=0; while [ "$i" -lt 60 ]; do hc read w-p260t 2>/dev/null | grep -q 'trust this folder' && break; i=$((i + 1)); sleep 1; done
out=$(PADDOCK_PROMPT_TRIES=60 bash "$ESC" prompt --task p260t --then-send "Probe task. Reply with the single word p260-trust-ok and do nothing else." 2>&1); rc=$?
sleep 20
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'POLICY folder-trust' && hc read w-p260t 2>&1 | grep -q 'p260-trust-ok'; then
  echo "RESULT trust: PASS"
else
  echo "RESULT trust: FAIL rc=$rc ($out)"; hc read w-p260t 2>&1 | tail -n 15
fi
