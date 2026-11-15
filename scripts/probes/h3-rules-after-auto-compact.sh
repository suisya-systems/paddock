#!/bin/sh
# Host probe H3 of decision 0014 (docs/decisions/0014-role-rules-skills-and-tools.md, "Host probes"):
# do the secretary's standing rules hold after an AUTOMATIC compaction, and when does an edit of
# the rules reach the running session? Built on q12-rule-after-compact.sh.
#
# Two modes (run both; each takes 20 to 60 minutes, mostly waiting for the context to fill):
#   F  the rules are in AGENTS.md, and CLAUDE.md is the single line @AGENTS.md, in a folder that is
#      NOT a git repository (the working folder of the template launch). The template body has no rules.
#   R  the rules are only in a file passed with --append-system-prompt-file (outside the folder);
#      the folder holds neither AGENTS.md nor CLAUDE.md.
#
# Run from the repo root, on a host where herdr core (hc) runs and Claude Code is logged in:
#   sh scripts/probes/h3-rules-after-auto-compact.sh F
#   sh scripts/probes/h3-rules-after-auto-compact.sh R
# Optional environment: FILES=4 ROWS=600 (size of one round of reading), MAXROUNDS=8 (rounds per
# fill), PCT=<n> (launches claude with CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=<n> so the automatic
# compaction comes sooner; whether Claude Code honours it is not verified here: the compaction
# lines below tell). Needs hc, claude, awk, grep, sed, find on PATH; POSIX sh.
# Creates a folder under $HOME (NOT /tmp: trust) and a temporary template h3-rules; cleanup removes
# the terminal and the template and keeps the folder (generated data, screens, copied transcripts).
# The probe never types /compact: any compaction it sees is the automatic one.
#
# Steps (CHECK = a grep of `hc read`, a hint; REPLY-CODES = the [[...]] codes found in the assistant
# replies of the session transcript under ~/.claude/projects, which is the record; "none" means
# the replies carried no code):
#   S1 control      first message answered; the rule followed before any long task?
#   S2 fill         reads generated files round by round until a compaction happens (not typed by the probe).
#   S3 after #1     an unrelated question, rule not mentioned (followed?), then "state the rule" (known?).
#   S4 edit         the codeword in the rules file is changed from KESTREL-7 to HERON-3 mid-session
#                   (the file is replaced, not appended); an unrelated question right after: which
#                   codeword is in the reply before the next compaction?
#   S5 after #2     fill until a second automatic compaction; an unrelated question: which codeword?
#   S6 restart      the terminal is killed and relaunched in the same folder; which codeword?
# Printed at the end: one line  RESULT h3-<mode>: ...  with the values below.
#
# How to read PASS (the part that decides F or R):
#   PASS  compaction1=yes  s1=KESTREL-7  after-compaction1=KESTREL-7 (known-after-compaction1 is a second, softer check)
#         The rules survived an automatic compaction in this mode. F PASS keeps decision 0014 part 3 as (F).
#   FAIL  compaction1=yes  s1=KESTREL-7  after-compaction1=none  (the rule was not followed after it;
#         known-after-compaction1 says whether it is merely not applied or lost). F FAIL moves part 3 to (R);
#         if R FAILs too, the rules need a SessionStart hook on the compact source (decision 0014, D17).
#   UNCONFIRMED  compaction1=screen: only the word compact showed on the screen, no transcript marker; read
#         the printed screens, and decide by hand whether a compaction happened.
#   VOID  compaction1=no, or s1=none (not followed even before the long task), or the folder check failed.
#         Rerun with PCT=20 or a larger MAXROUNDS, or read the printed screens.
# The edit lines are a measurement, not a pass or fail: edit-before-compaction=HERON-3 means an edit
# reaches the running session at once; KESTREL-7 there and HERON-3 after-compaction2 means at the next
# compaction; HERON-3 only after-restart means a restart is needed.
# Paste the whole output back, plus the folder path it prints at the end (transcripts are kept there).

MODE=${1:-}
case "$MODE" in F|R) ;; *) echo "RESULT precondition-failed: usage: sh scripts/probes/h3-rules-after-auto-compact.sh F|R"; exit 1 ;; esac

FILES=${FILES:-4}
ROWS=${ROWS:-600}
MAXROUNDS=${MAXROUNDS:-8}
PCT=${PCT:-}
NAME=h3p
CWA=KESTREL-7
CWB=HERON-3
TPL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-core/templates"
TPL="$TPL_DIR/h3-rules.md"
SELF=$(cd "$(dirname "$0")" && pwd)
BASE="h3-rules-$MODE-$(date +%Y%m%d-%H%M%S)"
ROOT="$HOME/$BASE"
OUT="$ROOT/out"
RULES_R="$ROOT/rules-R.md"
PROJ="$HOME/.claude/projects"

has() { hc ls 2>&1 | grep -Eq "(^|[^A-Za-z0-9_-])$1([^A-Za-z0-9_-]|\$)"; }
if [ -e "$TPL" ]; then echo "RESULT precondition-failed: $TPL exists; remove it first"; exit 1; fi
if has $NAME; then echo "RESULT precondition-failed: terminal $NAME already exists"; exit 1; fi

. "$SELF/claude-link.sh"
claude_link_save
cleanup() {
  claude_link_restore
  hc kill $NAME >/dev/null 2>&1; hc rm $NAME >/dev/null 2>&1
  rm -f "$TPL"
  echo "CLEANUP done. Folder kept (data, screens, transcripts): $ROOT"
}
trap cleanup EXIT INT TERM
mkdir -p "$TPL_DIR" "$OUT" || exit 1

# The template: a secretary-like opening, no rules in the body. In R the command carries the flag.
EXTRA=""
[ "$MODE" = R ] && EXTRA=" --append-system-prompt-file \"$RULES_R\""
CLEAN="env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDECODE -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_PID -u CLAUDE_TMPDIR"
[ -n "$PCT" ] && CLEAN="$CLEAN CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=$PCT"
{
  echo "---"
  echo "description: probe H3 secretary-like template (temporary)"
  echo "command: $CLEAN claude --permission-mode default$EXTRA"
  echo "---"
  echo "You are the coordinator of a small team in this probe. You answer what you are asked, briefly."
  echo "Your standing rules are not written in this text."
} > "$TPL" || exit 1

echo "== versions"; hc --version 2>&1; claude --version 2>&1
echo "== mode=$MODE FILES=$FILES ROWS=$ROWS MAXROUNDS=$MAXROUNDS PCT=${PCT:-unset} folder=$ROOT"

rules() { # $1 = codeword
  printf '%s\n' "Probe H3 standing rules. They apply to the whole session." \
    "Rule 1: your codeword is $1." \
    "Rule 2: the last line of every reply you write must be the codeword wrapped in double square brackets, on a line of its own, with nothing else on that line." \
    "These rules are given only here. Do not write them into any file."
}

prep() { # $1 = working folder: data files directory and, in F, the two rules files
  mkdir -p "$1" || exit 1
  if [ "$MODE" = F ]; then
    RULESFILE="$1/AGENTS.md"
    rules $CWA > "$RULESFILE"
    echo "@AGENTS.md" > "$1/CLAUDE.md"
  else
    RULESFILE="$RULES_R"
    [ -f "$RULESFILE" ] || rules $CWA > "$RULESFILE"
  fi
  if git -C "$1" rev-parse >/dev/null 2>&1; then echo "RESULT precondition-failed: $1 is inside a git repository"; exit 1; fi
}

gen() { # $1 = dir, $2 = round: FILES deterministic files of ROWS lines each, new names per round
  n=1
  while [ $n -le "$FILES" ]; do
    awk -v f="$2$n" -v l="$ROWS" 'BEGIN{for(i=1;i<=l;i++) printf "rec-%s-%05d alpha=%d beta=%d gamma=%d note=lorem ipsum dolor sit amet %d\n", f,i,(i*7+f)%1000,(i*13+f)%1000,(i*29+f)%1000,(i*i+f)%99991}' > "$1/data-r$2-$n.txt"
    n=$((n + 1))
  done
}

screen() { hc read $NAME 2>&1; }
is_idle() { hc get --json $NAME 2>&1 | tr -d '\n' | grep -Eq '"state" *: *"(done|idle)"'; }
wait_idle() { # $1 = max seconds; waits 10 s first (status may lag a send)
  sleep 10; i=10
  while [ $i -lt "$1" ]; do is_idle && return 0; i=$((i + 5)); sleep 5; done
  echo "-- wait_idle timed out after $1 s"; return 1
}
show() { echo "-- screen ($1):"; screen | tee "$OUT/$1.screen" | tail -${2:-15}; }
check() { # $1 = name, $2 = ERE; prints yes|no and sets CHK
  if screen | grep -Eq "$2"; then CHK=yes; else CHK=no; fi
  echo "CHECK $1: $CHK"
}

# Replies from the session transcript(s) of this run, oldest file first.
tfiles() { find "$PROJ" -maxdepth 2 -name '*.jsonl' -path "*$BASE*" 2>/dev/null | while read -r f; do echo "$f"; done | xargs -r ls -tr 2>/dev/null; }
# Only visible reply text counts (not thinking or tool inputs), and only a code on the LAST line of the text.
replies() { tfiles | while read -r f; do grep -h '"type":"assistant"' "$f" | grep -Eo '"text":"([^"\\]|\\.)*"' | sed -nE 's/.*("text":"|\\n)(\[\[[A-Za-z0-9-]+\]\])(\\n)*"$/\2/p'; done; }
# Visible reply texts (JSON-escaped), the trailing code line cut off, so a recall check is not fed by the rule being followed.
texts() { tfiles | while read -r f; do grep -h '"type":"assistant"' "$f" | grep -Eo '"text":"([^"\\]|\\.)*"' | sed -E 's/(\\n)+\[\[[A-Za-z0-9-]+\]\](\\n)*"$/"/'; done; }
ncompact() { tfiles | while read -r f; do grep -Eo 'compact_boundary|isCompactSummary' "$f"; done | wc -l | tr -d ' '; }
ask() { # $1 = step tag, $2 = text, $3 = max wait seconds; sets NEW (codes in the new replies)
  n0=$(replies | wc -l | tr -d ' '); t0=$(texts | wc -l | tr -d ' ')
  hc send $NAME "$2"; wait_idle "${3:-180}" || TIMEDOUT=yes
  show "$1" 15
  NEW=$(replies | tail -n +$((n0 + 1)) | tr '\n' ' '); NEWTXT=$(texts | tail -n +$((t0 + 1)))
  echo "REPLY-CODES $1: ${NEW:-none}"
}
code_of() { # reduce NEW to KESTREL-7, HERON-3, both or none
  a=no; b=no
  case "$NEW" in *"[[$CWA]]"*) a=yes ;; esac
  case "$NEW" in *"[[$CWB]]"*) b=yes ;; esac
  if [ $a = yes ] && [ $b = yes ]; then echo both; elif [ $a = yes ]; then echo "$CWA"; elif [ $b = yes ]; then echo "$CWB"; else echo none; fi
}

launch() { # $1 = dir: starts the terminal; prints "yes" when the trust dialog was seen, else "no"
  hc run --bg --name $NAME --cwd "$1" h3-rules \
    "Reply with one short sentence saying you are ready. Files data-r*.txt are in the current folder." \
    >/dev/null 2>&1 || { echo "RESULT precondition-failed: hc run failed"; exit 1; }
  i=0; seen=no
  while [ $i -lt 120 ]; do
    case "$(screen)" in *"Quick safety check"*) seen=yes; break ;; esac
    hc get --json $NAME 2>&1 | tr -d '\n' | grep -Eq '"sent" *: *true' && break
    i=$((i + 3)); sleep 3
  done
  echo "$seen"
}

fill() { # $1 = step tag, $2 = ncompact before, $3 unused: reads rounds of files until a compaction shows.
  # FILLED: yes = a new transcript marker; screen = only the word "compact" newly on the screen (a hint, never a PASS); no.
  r=0; FILLED=no; SC0=$(screen | grep -Eci 'compact')
  while [ $r -lt "$MAXROUNDS" ]; do
    r=$((r + 1)); RND="$1$r"; gen "$RUN" "$RND"
    hc send $NAME "Read the files data-r$RND-1.txt to data-r$RND-$FILES.txt in the current folder, one file at a time with the Read tool, whole file each. After each file write a one sentence summary. Then write the number of files you read."
    wait_idle 1500 || TIMEDOUT=yes
    if [ "$(ncompact)" -gt "$2" ]; then FILLED=yes
    elif [ "$(screen | grep -Eci 'compact')" -gt "$SC0" ]; then FILLED=screen
    fi
    echo "-- $1 round $r: compaction evidence: $FILLED"
    [ $FILLED != no ] && break
  done
  wait_idle 300
  show "$1" 25
}

TIMEDOUT=no
echo "== S0 launch"
RUN="$ROOT/run1"; prep "$RUN"; gen "$RUN" 0
seen=$(launch "$RUN" | tail -1)
if [ "$seen" = yes ]; then
  echo "CHECK trust-dialog: seen; accepting, then relaunching in a sibling folder"
  hc keys $NAME down enter; sleep 5
  hc kill $NAME >/dev/null 2>&1; hc rm $NAME >/dev/null 2>&1
  rm -f "$ROOT/run1/AGENTS.md" "$ROOT/run1/CLAUDE.md"  # an ancestor folder's rules would load too
  RUN="$ROOT/run1/run2"; prep "$RUN"; gen "$RUN" 0
  seen2=$(launch "$RUN" | tail -1)
  [ "$seen2" = yes ] && { echo "RESULT void: dialog again in the sub folder"; exit 1; }
else
  echo "CHECK trust-dialog: not-seen"
fi
wait_idle 120
echo "-- hc get --json:"; hc get --json $NAME 2>&1
echo "-- rules file: $RULESFILE"; cat "$RULESFILE"
[ "$MODE" = F ] && { echo "-- CLAUDE.md:"; cat "$RUN/CLAUDE.md"; }

echo "== S1 control: first message answered, rule followed before any long task?"
show S1 15
NEW=$(replies | tr '\n' ' '); echo "REPLY-CODES S1: ${NEW:-none}"
S1=$(code_of)
check s1-bracket-line "^[[:space:]]*(.[[:space:]]*)?\[\[$CWA\]\]"

echo "== S2 fill until a compaction happens (the probe does not type one)"
c0=$(ncompact)
fill S2 "$c0"
C1=$FILLED
echo "CHECK compaction1: $C1 (transcript markers: $(ncompact))"

echo "== S3 after compaction 1: unrelated question, then ask for the rule"
ask S3a "What is 17 plus 25? Answer in one short sentence." 180
A1=$(code_of)
ask S3b "State the codeword and the formatting rule you were given at the start of this session, in one or two sentences." 180
K1=no
if printf '%s' "$NEWTXT" | grep -q "$CWA" && printf '%s' "$NEWTXT" | grep -Eqi "bracket|$(printf '\346\213\254\345\274\247')|\\[\\["; then K1=yes; fi  # the reply may be in Japanese: kakko = brackets
echo "CHECK s3-known (codeword and format, from the S3b reply only): $K1"

echo "== S4 edit the rules file mid-session: $CWA -> $CWB"
sed "s/$CWA/$CWB/g" "$RULESFILE" > "$RULESFILE.new" && mv "$RULESFILE.new" "$RULESFILE"
echo "-- rules file now:"; cat "$RULESFILE"
ask S4 "What is 30 plus 12? Answer in one short sentence." 180
E1=$(code_of)

echo "== S5 fill until a second compaction, then an unrelated question"
c1=$(ncompact)
fill S5 "$c1"
C2=$FILLED
echo "CHECK compaction2: $C2 (transcript markers: $(ncompact))"
ask S5q "What is 9 plus 8? Answer in one short sentence." 180
A2=$(code_of)

echo "== S6 restart: kill the terminal and relaunch in the same folder"
hc kill $NAME >/dev/null 2>&1; hc rm $NAME >/dev/null 2>&1; sleep 3
seen3=$(launch "$RUN" | tail -1)
[ "$seen3" = yes ] && echo "CHECK trust-dialog: seen again on restart; accept it by hand, the probe cannot continue"
wait_idle 120
ask S6 "What is 5 plus 6? Answer in one short sentence." 180
R1=$(code_of)

echo "== files kept in $OUT (screens); transcripts copied to $OUT/transcripts:"
mkdir -p "$OUT/transcripts"; tfiles | while read -r f; do cp "$f" "$OUT/transcripts/" && echo "   $f"; done
echo "RESULT h3-$MODE: compaction1=$C1 s1=$S1 after-compaction1=$A1 known-after-compaction1=$K1 edit-before-compaction=$E1 compaction2=$C2 after-compaction2=$A2 after-restart=$R1"
[ "$TIMEDOUT" = yes ] && echo "RESULT h3-$MODE: a wait timed out: the values above may be missing replies, not lost rules"
case "$TIMEDOUT:$C1:$S1:$A1:$K1" in
  yes:*) echo "RESULT h3-$MODE verdict: VOID (a wait timed out; rerun or read the screens in $OUT)" ;;
  no:screen:$CWA:*) echo "RESULT h3-$MODE verdict: UNCONFIRMED (compaction seen on the screen only; read the screens in $OUT)" ;;
  no:yes:$CWA:$CWA:yes) echo "RESULT h3-$MODE verdict: PASS (the rules survived an automatic compaction)" ;;
  no:yes:$CWA:$CWA:*) echo "RESULT h3-$MODE verdict: PASS (followed after compaction 1; the recall check said known=$K1, read the S3b reply in $OUT/S3b.screen)" ;;
  no:yes:$CWA:*) echo "RESULT h3-$MODE verdict: FAIL (not followed after compaction 1; known=$K1)" ;;
  *) echo "RESULT h3-$MODE verdict: VOID (compaction1=$C1 s1=$S1)" ;;
esac
echo "== done; paste everything above back (versions are at the top)"
