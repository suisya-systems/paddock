#!/bin/sh
# Probe for Issue #45 (Q12): is a rule given only in a template body still
# followed after the conversation is compacted?
#
# Run from the repo root, on a host where herdr core (hc) runs and Claude Code
# is logged in:
#   sh scripts/probes/q12-rule-after-compact.sh
# Takes about 10 to 25 minutes (reads FILES generated files, then /compact).
# Needs: hc, claude, awk, grep on PATH; POSIX sh. No network beyond Claude Code
# itself. Creates a folder under $HOME (NOT /tmp: trust), a temporary template
# p45-rule (copied from scripts/probes/q12-rule-after-compact.md), and
# terminal p45. Cleanup removes the terminal and the template; the folder is
# left (it holds only generated data). Optional: FILES=6 ROWS=600 (task size).
#
# The rule exists ONLY in the template body: codeword KESTREL-7, and "the last
# line of every reply is the codeword in double square brackets", i.e. the
# line [[KESTREL-7]]. The task text sent after it never mentions the rule.
#
# Steps and what each prints (CHECK lines are automatic, from `hc read`):
#   S0 launch    CHECK trust-dialog: seen|not-seen. If seen it is accepted and
#                the terminal is relaunched in a sibling folder (trust carries
#                down, Q13); the first message is then delivered as normal.
#   S1 control   after the first message (which asks for a 1-line reply):
#                CHECK s1-bracket-line: yes|no. "no" means the rule was not
#                followed even before any long task: the probe is void.
#   S2 long task the agent reads FILES files of ROWS lines each, one at a
#                time, with a summary after each. CHECK s2-bracket-line.
#   S3 /compact  typed with `hc send p45 /compact`. CHECK s3-compacted: yes|no
#                (screen mentions compaction). If "no", look at the printed
#                screen; the probe is void unless a compaction happened.
#   S4 unrelated question, no rule mentioned: CHECK s4-bracket-line: yes|no.
#                yes = the rule is still FOLLOWED after compaction.
#   S5 "state the rule": CHECK s5-codeword: yes|no (screen names KESTREL-7)
#                and s5-format: yes|no (mentions square brackets). yes/yes =
#                the rule is still KNOWN after compaction.
#   Verdict: followed = s1 yes and s4 yes; not followed = s1 yes and s4 no
#   (then s5 tells whether it is merely not applied or actually lost).
#   Also read the printed screens yourself: the CHECK greps are hints.
# Paste the whole output back, plus `hc --version` and `claude --version`
# (printed at the top).

FILES=${FILES:-6}
ROWS=${ROWS:-600}
NAME=p45
TPL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-core/templates"
TPL="$TPL_DIR/p45-rule.md"
SELF=$(cd "$(dirname "$0")" && pwd)
ROOT="$HOME/p45-compact-$(date +%Y%m%d-%H%M%S)"
BR='\[\[KESTREL-7\]\]'

has() { hc ls 2>&1 | grep -Eq "(^|[^A-Za-z0-9_-])$1([^A-Za-z0-9_-]|\$)"; }
if [ -e "$TPL" ]; then echo "RESULT precondition-failed: $TPL exists; remove it first"; exit 1; fi
if has $NAME; then echo "RESULT precondition-failed: terminal $NAME already exists"; exit 1; fi
[ -f "$SELF/q12-rule-after-compact.md" ] || { echo "RESULT precondition-failed: template file missing"; exit 1; }

cleanup() {
  hc kill $NAME >/dev/null 2>&1; hc rm $NAME >/dev/null 2>&1
  rm -f "$TPL"
  echo "CLEANUP done. Folder kept: $ROOT"
}
trap cleanup EXIT INT TERM
mkdir -p "$TPL_DIR" "$ROOT" || exit 1
cp "$SELF/q12-rule-after-compact.md" "$TPL" || exit 1

echo "== versions"; hc --version 2>&1; claude --version 2>&1
echo "== task size: FILES=$FILES ROWS=$ROWS"

gen() { # $1 = dir: FILES deterministic files, ROWS lines each, ~80 bytes a line
  mkdir -p "$1"
  n=1
  while [ $n -le "$FILES" ]; do
    awk -v f="$n" -v l="$ROWS" 'BEGIN{for(i=1;i<=l;i++) printf "rec-%02d-%05d alpha=%d beta=%d gamma=%d note=lorem ipsum dolor sit amet %d\n", f,i,(i*7+f)%1000,(i*13+f)%1000,(i*29+f)%1000,(i*i+f)%99991}' > "$1/data-0$n.txt"
    n=$((n + 1))
  done
  echo "-- generated: $(cat "$1"/data-0*.txt | wc -l) lines, $(cat "$1"/data-0*.txt | wc -c) bytes in $FILES files" >&2
}

screen() { hc read $NAME 2>&1; }
# Measured status vocabulary: "working", "done" (between turns), "blocked"; not "idle".
is_idle() { hc get --json $NAME 2>&1 | tr -d '\n' | grep -Eq '"state" *: *"(done|idle)"'; }
wait_idle() { # $1 = max seconds; waits 10 s first (status may lag a send)
  sleep 10; i=10
  while [ $i -lt "$1" ]; do is_idle && return 0; i=$((i + 5)); sleep 5; done
  echo "-- wait_idle timed out after $1 s"; return 1
}
check() { # $1 = name, $2 = ERE
  if screen | grep -Eq "$2"; then echo "CHECK $1: yes"; else echo "CHECK $1: no"; fi
}
show() { echo "-- screen ($1):"; screen | tail -${2:-25}; }

launch() { # $1 = dir
  gen "$1"
  hc run --bg --name $NAME --cwd "$1" p45-rule \
    "Reply with one short sentence saying you are ready. Files data-01.txt to data-0$FILES.txt are in the current folder." \
    || { echo "RESULT precondition-failed: hc run failed"; exit 1; }
  i=0; seen=no
  while [ $i -lt 120 ]; do
    case "$(screen)" in *"Quick safety check"*) seen=yes; break ;; esac
    hc get --json $NAME 2>&1 | tr -d '\n' | grep -Eq '"sent" *: *true' && break
    i=$((i + 3)); sleep 3
  done
  echo "$seen"
}

echo "== S0 launch"
seen=$(launch "$ROOT/run1" | tail -1)
if [ "$seen" = yes ]; then
  echo "CHECK trust-dialog: seen; accepting, then relaunching in a sibling folder"
  hc keys $NAME down enter; sleep 5
  hc kill $NAME >/dev/null 2>&1; hc rm $NAME >/dev/null 2>&1
  seen2=$(launch "$ROOT/run1/run2" | tail -1)
  [ "$seen2" = yes ] && { echo "RESULT void: dialog again in the sub folder"; exit 1; }
else
  echo "CHECK trust-dialog: not-seen"
fi
wait_idle 120
echo "-- hc get --json:"; hc get --json $NAME 2>&1

echo "== S1 control: first message answered, rule followed before any long task?"
show S1 15
check s1-bracket-line "^[[:space:]]*(.[[:space:]]*)?$BR"

echo "== S2 long task"
hc send $NAME "Read data-01.txt to data-0$FILES.txt in the current folder, one file at a time with the Read tool, whole file each. After each file write a two sentence summary of what its lines look like. After the last file write the number of files you read."
wait_idle 1500
show S2 25
check s2-bracket-line "$BR"

echo "== S3 /compact (hc send $NAME /compact)"
hc send $NAME /compact
wait_idle 300
show S3 25
check s3-compacted "[Cc]ompact"

echo "== S4 unrelated question after compaction, rule not mentioned"
hc send $NAME "What is 17 plus 25? Answer in one short sentence."
wait_idle 180
show S4 15
check s4-bracket-line "$BR"

echo "== S5 ask the agent to state the rule"
hc send $NAME "State the codeword and the formatting rule you were given at the start of this session, in one or two sentences."
wait_idle 180
show S5 15
check s5-codeword "KESTREL-7"
check s5-format "[Ss]quare bracket"

echo "== done; paste everything above back (versions are at the top)"
