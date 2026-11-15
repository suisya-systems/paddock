#!/bin/sh
# Probe for decision 0014, H4 and H5: does a secretary-like Claude Code launched with
# --plugin-dir load paddock's skills as `paddock:` skills, see an edited SKILL.md and a new
# skill folder while it runs, and does `allowed-tools` pre-approve a skill's script call?
#
# Run from the repo root, on a host where herdr core (hc) runs and Claude Code is logged in:
#   sh scripts/probes/plugin-dir-skills.sh
# Takes about 5 to 12 minutes. Needs: hc, claude, grep, sed, tr on PATH; POSIX sh.
# Creates a folder under $HOME (NOT /tmp: trust) with a throwaway plugin (a COPY of the
# checkout's skills/ plus two probe skills, and a .claude-plugin/plugin.json named paddock,
# so the skills are paddock:<name> as in the decision). The checkout is never written.
# A temporary template p0014h4 and terminal p0014h4 are removed by the cleanup; the folder is
# kept (generated data only). The terminal runs Claude Code in default permission mode.
#
# What it sends and what is checked (CHECK lines come from `hc read`, RESULT lines sum up):
#   S0 launch   first message "What is 40 plus 2?". Screen is printed. A folder-trust dialog is
#               expected (it appears without a plugin too; it is accepted and the terminal is
#               relaunched in a sibling folder). Any OTHER dialog text mentioning a plugin is a
#               finding: RESULT H4-dialog FAIL. Look at the printed screen yourself.
#   S1 list     asks the agent to list the skills it has whose name starts with "paddock:".
#               RESULT H4-list PASS = paddock:h4-marker and paddock:org-issue named.
#   S2 situation sends the word ZEBRA-PLUM only. The probe skill's when_to_use names that word.
#               RESULT H4-invoke PASS = the reply carries SKILL-TEXT-V1 (text only the skill
#               has).
#               H5: the skill has allowed-tools: Bash(bash <plugin>/skills/h4-marker/scripts/marker.sh:*).
#               The probe watches `hc get` for state "blocked" during S2 (a permission prompt).
#               RESULT H5-allowed-tools PASS = marker.sh ran (file marker-ran exists) and the
#               terminal was never blocked. FAIL = it ran after a prompt (not pre-approved).
#   S3 edit     rewrites SKILL-TEXT-V1 to SKILL-TEXT-V2 in the plugin's SKILL.md while the
#               terminal runs, then asks for ZEBRA-PLUM again and to invoke the skill again.
#               RESULT H4-edit-live PASS = SKILL-TEXT-V2 appears in the reply.
#   S4 new      creates skills/h4-new/ while it runs and sends NARWHAL-3.
#               RESULT H4-new-skill PASS = SKILL-NEW-TEXT-N1 appears. If not, /reload-plugins is
#               typed and NARWHAL-3 sent again: RESULT H4-new-skill-after-reload says whether
#               that was enough (then a new skill needs a reload command, not a renewal).
#   S2b variants: the same script call under allowed-tools "bash <abs> *" (RESULT
#               H5-allowed-tools-b) and "bash ${CLAUDE_SKILL_DIR}/... *" (-c), the forms the docs
#               show; A (S2) uses the older "<abs>:*" form. Whichever PASSes is the form to use.
#               The permission prompt's text is printed when one appears.
#   S4b edit+reload  rewrites SKILL-TEXT-V2 to V3, types /reload-plugins, invokes again.
#               RESULT H4-edit-after-reload PASS = V3 appears (a reload picks up an edit).
#   S5 control  asks for a script call that allowed-tools does NOT cover (other.sh). It must be
#               blocked; RESULT H5-control PASS = it was. If it was not, the terminal is not
#               asking at all and H5-allowed-tools is void.
# Not measured: allowed-tools with a relative path (the decision's example) when the cwd is not
# the checkout, and ${CLAUDE_SKILL_DIR} in allowed-tools. This probe uses an absolute path.
# Paste the whole output back, plus `hc --version` and `claude --version` (printed at the top).
set -u

NAME=p0014h4
TPL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-core/templates"
TPL="$TPL_DIR/$NAME.md"
SELF=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SELF/../.." && pwd)
ROOT="$HOME/p0014-h4-$(date +%Y%m%d-%H%M%S)"
PLUG="$ROOT/plugin"

has() { hc ls 2>&1 | grep -Eq "(^|[^A-Za-z0-9_-])$1([^A-Za-z0-9_-]|\$)"; }
[ -d "$REPO/skills/org-issue" ] || { echo "RESULT precondition-failed: run from a paddock checkout"; exit 1; }
if [ -e "$TPL" ]; then echo "RESULT precondition-failed: $TPL exists; remove it first"; exit 1; fi
if has $NAME; then echo "RESULT precondition-failed: terminal $NAME already exists"; exit 1; fi

. "$SELF/claude-link.sh"
claude_link_save
cleanup() {
  claude_link_restore
  hc kill $NAME >/dev/null 2>&1; hc rm $NAME >/dev/null 2>&1
  rm -f "$TPL"
  echo "CLEANUP done. Folder kept: $ROOT"
}
trap cleanup EXIT; trap 'exit 130' INT TERM

echo "== versions"; hc --version 2>&1; claude --version 2>&1

# The throwaway plugin: a copy of the checkout's skills plus two probe skills.
mkdir -p "$TPL_DIR" "$ROOT/run1" "$PLUG/.claude-plugin" "$PLUG/skills/h4-marker/scripts" || exit 1
cp -R "$REPO"/skills/. "$PLUG/skills/" || exit 1
printf '{ "name": "paddock", "description": "probe copy of paddock skills (H4)" }\n' > "$PLUG/.claude-plugin/plugin.json"
cat > "$PLUG/skills/h4-marker/SKILL.md" <<EOF
---
name: h4-marker
description: Probe skill for H4 and H5. Prints a marker line by running its script.
when_to_use: When the message contains the word ZEBRA-PLUM.
allowed-tools: Bash(bash $PLUG/skills/h4-marker/scripts/marker.sh:*)
---
Run \`bash $PLUG/skills/h4-marker/scripts/marker.sh\` once. Then reply with one line: SKILL-TEXT-V1 followed by what the script printed.
EOF
cat > "$PLUG/skills/h4-marker/scripts/marker.sh" <<EOF
#!/bin/sh
echo ran > "$ROOT/marker-ran"
echo MARKER-OUT
EOF
# H5 variants: the same script call under other allowed-tools forms (A above: "<abs>:*").
#   h4-b: "bash <abs> *" (space-star, the form the docs show)   h4-c: "bash ${CLAUDE_SKILL_DIR}/... *"
for v in b c; do
  mkdir -p "$PLUG/skills/h4-$v/scripts"
  if [ $v = b ]; then W=KIWI-B1; AT="Bash(bash $PLUG/skills/h4-b/scripts/marker.sh *)"
  else W=MANGO-C1; AT='Bash(bash ${CLAUDE_SKILL_DIR}/scripts/marker.sh *)'; fi
  cat > "$PLUG/skills/h4-$v/SKILL.md" <<EOF2
---
name: h4-$v
description: Probe skill for H5, allowed-tools form $v. Prints a marker line by running its script.
when_to_use: When the message contains the word $W.
allowed-tools: $AT
---
Run \`bash $PLUG/skills/h4-$v/scripts/marker.sh\` once. Then reply with one line: SKILL-TEXT-$v followed by what the script printed.
EOF2
  printf '#!/bin/sh\necho ran > "%s/marker-ran-%s"\necho MARKER-OUT-%s\n' "$ROOT" $v $v > "$PLUG/skills/h4-$v/scripts/marker.sh"
done
cat > "$PLUG/skills/h4-marker/scripts/other.sh" <<EOF
#!/bin/sh
echo OTHER-OUT
EOF
cat > "$TPL" <<EOF
---
description: probe 0014 H4, a template launch with --plugin-dir (temporary)
command: env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN claude --permission-mode default --plugin-dir $PLUG
---
Probe working rules: answer in plain short sentences. Do not write any file yourself.
EOF

screen() { hc read $NAME 2>&1; }
state_is() { hc get --json $NAME 2>&1 | tr -d '\n' | grep -Eq "\"state\" *: *\"$1\""; }
is_idle() { state_is done || state_is idle; }
BLOCKED=no
# Waits for the terminal to be idle; sets BLOCKED=yes if it was ever blocked (a permission
# prompt) and answers it with Enter (yes) so the run goes on.
wait_idle() { # $1 = max seconds
  BLOCKED=no; sleep 10; i=10
  while [ $i -lt "$1" ]; do
    is_idle && return 0
    if state_is blocked; then
      [ $BLOCKED = no ] && { echo "-- BLOCKED, the prompt on screen (then answered with Enter):"; screen | tail -22; }
      BLOCKED=yes; hc keys $NAME enter >/dev/null 2>&1
    fi
    i=$((i + 3)); sleep 3
  done
  echo "-- wait_idle timed out after $1 s"; return 1
}
# Waits until blocked shows up (the control) or the terminal is idle.
# A turn that does not finish stops the probe: going on would send the next step into it.
must_idle() { wait_idle "$1" || { echo "RESULT void: a turn did not finish in $1 s; read the screen"; show timeout 30; exit 1; }; }
wait_blocked_or_idle() {
  BLOCKED=no; sleep 10; i=10
  while [ $i -lt "$1" ]; do
    if state_is blocked; then BLOCKED=yes; return 0; fi
    is_idle && return 0
    i=$((i + 3)); sleep 3
  done
  return 1
}
count() { screen | grep -c "$1"; } # lines on the screen holding the text
verdict() { # $1 = name, $2 = 0 for PASS
  if [ "$2" -eq 0 ]; then echo "$1: PASS"; else echo "$1: FAIL"; fi
}
show() { echo "-- screen ($1):"; screen | tail -${2:-25}; }

launch() { # $1 = dir; prints "yes" when the folder-trust dialog was seen
  mkdir -p "$1"
  hc run --bg --name $NAME --cwd "$1" $NAME "What is 40 plus 2? Answer with only the number." \
    || { echo "RESULT precondition-failed: hc run failed"; exit 1; }
  i=0; seen=no
  while [ $i -lt 120 ]; do
    case "$(screen)" in *"Quick safety check"*|*"trust this folder"*) seen=yes; break ;; esac
    hc get --json $NAME 2>&1 | tr -d '\n' | grep -Eq '"sent" *: *true' && break
    i=$((i + 3)); sleep 3
  done
  echo "$seen"
}

echo "== S0 launch with --plugin-dir $PLUG"
seen=$(launch "$ROOT/run1" | tail -1)
has $NAME || { echo "RESULT precondition-failed: terminal $NAME did not start"; exit 1; }
if [ "$seen" = yes ]; then
  echo "CHECK trust-dialog: seen (expected, not about the plugin); accepting, relaunching in a sibling folder"
  show S0-trust 20
  hc keys $NAME down enter; sleep 5
  hc kill $NAME >/dev/null 2>&1; hc rm $NAME >/dev/null 2>&1
  seen2=$(launch "$ROOT/run1/run2" | tail -1)
  has $NAME || { echo "RESULT precondition-failed: terminal $NAME did not restart"; exit 1; }
  [ "$seen2" = yes ] && { echo "RESULT void: trust dialog again in the sub folder"; exit 1; }
else
  echo "CHECK trust-dialog: not-seen"
fi
sleep 8
show S0-first-screen 30
# A dialog about the plugin would sit on screen and block the first message. Observe only:
# this wait never presses a key (wait_idle does), so a dialog is recorded, not accepted.
i=0; DLG=no
while [ $i -lt 120 ]; do
  is_idle && break
  if state_is blocked; then DLG=yes; break; fi
  i=$((i + 3)); sleep 3
done
# The answer to "40 plus 2" holds 42; the submitted prompt does not, so 42 is the assistant's.
if [ "$DLG" = yes ]; then
  echo "RESULT H4-dialog: FAIL (the terminal is blocked at launch; read the screen)"
  show S0-blocked 30
elif screen | grep -Eq '(^|[^0-9])42([^0-9]|$)'; then
  echo "RESULT H4-dialog: PASS (the first message was answered, no key was pressed)"
else
  echo "RESULT H4-dialog: NO DATA (no answer and not blocked; read the screen)"
fi

echo "== S1 skill list"
hc send $NAME "List the names of the skills you have whose name starts with the prefix paddock and a colon. One name per line, nothing else."
must_idle 180
show S1 30
a=$(count 'paddock:h4-marker'); b=$(count 'paddock:org-issue')
# The question itself holds neither name, so any line with both is the answer.
[ "$a" -ge 1 ] && [ "$b" -ge 1 ]; verdict "RESULT H4-list" $?

echo "== S2 situation match (ZEBRA-PLUM) and allowed-tools"
rm -f "$ROOT/marker-ran"
hc send $NAME "ZEBRA-PLUM"
must_idle 240
show S2 30
v1=$(count 'SKILL-TEXT-V1')
[ "$v1" -ge 1 ]; verdict "RESULT H4-invoke" $?
if [ -f "$ROOT/marker-ran" ] && [ "$BLOCKED" = no ]; then echo "RESULT H5-allowed-tools: PASS (script ran, never blocked)"
elif [ -f "$ROOT/marker-ran" ]; then echo "RESULT H5-allowed-tools: FAIL (script ran only after a permission prompt)"
else echo "RESULT H5-allowed-tools: NO DATA (the script did not run; was the skill invoked?)"; fi

echo "== S2b allowed-tools forms (H5 variants)"
for v in b c; do
  rm -f "$ROOT/marker-ran-$v"
  if [ $v = b ]; then W=KIWI-B1; else W=MANGO-C1; fi
  hc send $NAME "$W"
  must_idle 240
  show S2$v 20
  if [ -f "$ROOT/marker-ran-$v" ] && [ "$BLOCKED" = no ]; then echo "RESULT H5-allowed-tools-$v: PASS (script ran, never blocked)"
  elif [ -f "$ROOT/marker-ran-$v" ]; then echo "RESULT H5-allowed-tools-$v: FAIL (script ran only after a permission prompt)"
  else echo "RESULT H5-allowed-tools-$v: NO DATA (the script did not run)"; fi
done

echo "== S3 edit SKILL.md while the terminal runs"
f="$PLUG/skills/h4-marker/SKILL.md"
sed 's/SKILL-TEXT-V1/SKILL-TEXT-V2/' "$f" > "$f.new" && cat "$f.new" > "$f" && rm -f "$f.new"
grep -c 'SKILL-TEXT-V2' "$f" | sed 's/^/-- V2 lines in the edited file: /'
sleep 5
hc send $NAME "ZEBRA-PLUM again. Invoke the skill again now; do not reuse the text you already have."
must_idle 240
show S3 30
echo "-- SKILL-TEXT lines on screen:"; screen | grep 'SKILL-TEXT'
n2=$(count 'SKILL-TEXT-V2')
[ "$n2" -ge 1 ]; verdict "RESULT H4-edit-live" $?

echo "== S4 new skill folder while the terminal runs"
mkdir -p "$PLUG/skills/h4-new"
cat > "$PLUG/skills/h4-new/SKILL.md" <<EOF
---
name: h4-new
description: Probe skill for H4, added while the session runs.
when_to_use: When the message contains the word NARWHAL-3.
---
Reply with one line: SKILL-NEW-TEXT-N1.
EOF
sleep 5
hc send $NAME "NARWHAL-3"
must_idle 240
show S4 30
n3=$(count 'SKILL-NEW-TEXT-N1')
[ "$n3" -ge 1 ]; verdict "RESULT H4-new-skill" $?
if [ "$n3" -lt 1 ]; then
  echo "-- not picked up; typing /reload-plugins, then NARWHAL-3 again"
  hc send $NAME "/reload-plugins"
  must_idle 120
  show S4-reload 15
  hc send $NAME "NARWHAL-3 again"
  must_idle 240
  show S4-retry 30
  n3b=$(count 'SKILL-NEW-TEXT-N1')
  [ "$n3b" -ge 1 ]; verdict "RESULT H4-new-skill-after-reload" $?
fi

echo "== S4b edit SKILL.md again, then /reload-plugins, then invoke again"
sed 's/SKILL-TEXT-V2/SKILL-TEXT-V3/' "$f" > "$f.new" && cat "$f.new" > "$f" && rm -f "$f.new"
grep -c 'SKILL-TEXT-V3' "$f" | sed 's/^/-- V3 lines in the edited file: /'
hc send $NAME "/reload-plugins"
must_idle 120
show S4b-reload 15
hc send $NAME "ZEBRA-PLUM once more. Invoke the skill again now; do not reuse the text you already have."
must_idle 240
show S4b 30
echo "-- SKILL-TEXT lines on screen:"; screen | grep 'SKILL-TEXT'
n4=$(count 'SKILL-TEXT-V3')
[ "$n4" -ge 1 ]; verdict "RESULT H4-edit-after-reload" $?

echo "== S5 control: a script call allowed-tools does not cover"
hc send $NAME "Run bash $PLUG/skills/h4-marker/scripts/other.sh and tell me what it printed."
wait_blocked_or_idle 120
show S5 20
[ "$BLOCKED" = yes ]; verdict "RESULT H5-control" $?
hc keys $NAME escape >/dev/null 2>&1

echo "== done; paste everything above back (versions are at the top)"
