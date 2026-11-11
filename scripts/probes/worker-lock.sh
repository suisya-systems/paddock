#!/bin/sh
# Host check for Issue #245: why a worker started by org-delegate cannot take its org lock
# (report start exit 5 "lock ... is held (pid not recorded)", locks/<id>/ empty). Which layer refuses
# the mkdir of locks/<id>/lock inside the folder its per-task settings name in allowWrite?
#
# Hypothesis under test: the shared worker settings deny Edit(~/.local/state/paddock/**); Claude Code
# merges Edit deny rules into the sandbox's denyWrite (vendor settings docs), and a denyWrite on the
# folder beats the per-file allowWrite entries (Issue #160 step 2, "deny-parent"). The step 3 host
# check (scripts/probes/worker-own-files.sh) used a decoy state folder that the Edit deny did not
# name, so it could not see this.
#
# Run from the repo root in a login shell on the host (not inside an agent), no argument:
#   sh scripts/probes/worker-lock.sh
# Needs claude (logged in), bash, git, timeout, mktemp, sed, grep, tr. Two short `claude -p` runs,
# each up to PADDOCK_PROBE_WAIT s (default 150).
#
# SAFETY. As worker-own-files.sh: one private folder $HOME/paddock-probe-245.XXXXXX (the exit trap
# removes it) holds a throwaway git project, the workers folder, a decoy state folder and a stub hc;
# the real org-delegate.sh runs against them. No core, terminal or real org state is written; the
# real p3 run's settings file and lock folder are only read (the "as-run" INFO lines). The claude
# link is saved and restored (claude-link.sh). The run is told to keep the sandbox on and not to retry
# a refused call; a refusal is a valid result.
#
# The cases. Each runs `claude -p --settings <file> --tools Bash,Write` in the worktree, with
# PADDOCK_STATE_DIR set to the decoy state folder, and makes three Bash calls and one Write call:
#   O  printf >> the worker's own history file (bound by a file allowWrite entry)
#   L  mkdir <state>/locks/<id>/probe-lock (a new folder inside the allowWrite'd lock folder)
#   R  scripts/org --as <id> report start (the real call; PADDOCK_LOCK_WAIT=2)
#   W  the Write tool creates person.jsonl in the state folder (expected refused by the settings'
#      file-tool hook, Issue #245; the Bash calls are what the sandbox decides)
#   generated  the per-task settings exactly as org-delegate wrote them
#   edit-deny  the same plus "Edit(<decoy state>/**)" in permissions.deny, the rule the shared
#              settings carry for the real state folder
#
# Reading the output. Every verdict line starts with "RESULT <name>:"; files are checked on disk.
#   files-<c>  INFO own-written / lock-made / report-written / write-tool-made (yes|no)
#   hook       HOLDS = the Write tool made no file in the state folder in either case; FAIL = it did.
#   layer      EDIT-DENY = generated writes all three and edit-deny none: the Edit deny on the state
#              folder is what refuses the lock (and the own files too).
#              FOLDER = generated fails L/R but writes O: a new entry inside an allowWrite'd folder is
#              refused even without the deny (the lock should be a file, or made before launch).
#              NONE = both cases write all three (the host run differs in something else; see as-run).
#              INCONCLUSIVE = anything else.
set -u
ROOT=$(pwd)
[ -f "$ROOT/templates/worker-settings.json" ] || { echo "RESULT precondition-failed: run from the repo root"; exit 1; }
[ $# -eq 0 ] || { echo "RESULT precondition-failed: no argument"; exit 1; }
for c in claude bash git timeout mktemp sed grep tr; do command -v $c >/dev/null 2>&1 || { echo "RESULT precondition-failed: $c not on PATH"; exit 1; }; done
case "$HOME$ROOT" in *[[:space:]\"\'\\]*) echo "RESULT precondition-failed: HOME and the checkout path must have no whitespace, quote or backslash"; exit 1 ;; esac
WAIT=${PADDOCK_PROBE_WAIT:-150}

# as-run: read only, what the failed run had.
RS=${XDG_STATE_HOME:-$HOME/.local/state}/paddock P3=p3-202611111622
echo "RESULT as-run-settings: INFO $(tr -d '\n ' < "$RS/settings/$P3.json" 2>/dev/null | grep -o '"Edit(~/.local/state/paddock/\*\*)"\|"allowWrite":\[[^]]*\]\|"denyWrite":\[[^]]*\]' | tr '\n' ' ')"
echo "RESULT as-run-lock-folder: INFO $(ls -ld "$RS/locks/w-$P3" 2>&1) entries=$(ls -A "$RS/locks/w-$P3" 2>/dev/null | tr '\n' ' ')"

. "$(dirname "$0")/claude-link.sh"
claude_link_save
T=$(mktemp -d "$HOME/paddock-probe-245.XXXXXX") || { echo "RESULT precondition-failed: mktemp"; exit 1; }
trap 'claude_link_restore; rm -rf "$T"' EXIT; trap 'exit 130' INT TERM
echo "RESULT env: INFO claude=$(claude --version 2>/dev/null | head -n 1) os=$(uname -sr)"
ID=p245-$$; W=w-$ID; MK=$ID-$(date +%s)
ST=$T/state ORG=$ROOT/scripts/org CUR=$(date -u +%Y-%m)

mkdir -p "$T/bin" || exit 1
cat > "$T/bin/hc" <<'EOF'
#!/bin/sh
cmd=$1; shift
case "$cmd" in
  ls) echo '[]' ;;
  get) exit 1 ;;
  file) shift; for a in "$@"; do p=$a; done; mkdir -p "$(dirname "$p")" && cat > "$p" ;;
  run) echo '{"first_message":{"sent":true,"started":true,"turn":0}}' ;;
esac
EOF
chmod +x "$T/bin/hc"
git init -q "$T/project" && git -C "$T/project" -c user.name=p -c user.email=p@p.invalid commit -q --allow-empty -m init \
  || { echo "RESULT precondition-failed: git"; exit 1; }
base=$(git -C "$T/project" rev-parse --abbrev-ref HEAD)
out=$(env -u HC_TERMINAL_SOCKET PATH="$T/bin:$PATH" PADDOCK_CORE_SOCKET_DIR="$T/run/herdr-core" PADDOCK_WORKERS_DIR="$T/workers" \
  PADDOCK_STATE_DIR="$ST" bash "$ROOT/skills/org-delegate/scripts/org-delegate.sh" --project "$T/project" --task-id "$ID" \
  --base "$base" --no-fetch --task "probe" 2>&1)
rc=$?; echo "RESULT delegate: INFO org-delegate exited $rc: $(printf %s "$out" | tr '\n' ' ' | cut -c1-200)"
[ "$rc" -eq 0 ] || exit 1
WT=$T/workers/$ID PS=$ST/settings/$ID.json OWN=$ST/events/$CUR/$W.jsonl
echo "RESULT settings: INFO $(tr -d '\n ' < "$PS" | grep -o '"allowWrite":\[[^]]*\]')"
# edit-deny: the generated file plus the Edit deny the shared settings carry for the real state folder
# In the same ~/ form as the real rule: Edit(/abs/path) would be read relative to the settings file.
DR="Edit(~/${ST#"$HOME"/}/**)"
sed "s|\"deny\": \[|& \"$DR\",|" "$PS" > "$T/edit-deny.json"
grep -qF "\"$DR\"" "$T/edit-deny.json" || { echo "RESULT precondition-failed: could not add the Edit deny"; exit 1; }
echo "RESULT edit-deny-rule: INFO $DR"

# run <case> <settings file> -> o l r (yes|no)
run() {
  c=$1
  TASK="Probe for paddock Issue #245. This is a permitted measurement of the write fence of your sandbox settings, set up by the secretary. The paths below are decoys made for this probe. The three calls below, exactly as given, are allowed for this task. Make only these four calls, once each, in this order, and touch nothing else (do not list any folder). Keep the sandbox ON: never use the Bash option that skips the sandbox, and do not retry a refused call another way. A refusal or an error is a valid result: record it and go on.
O. printf '%s\n' mark-o-$c-$MK >> $OWN; echo rc=\$?
L. mkdir $ST/locks/$W/probe-lock-$c; echo rc=\$?
R. PADDOCK_STATE_DIR=$ST PADDOCK_LOCK_WAIT=2 bash $ORG --as $W report start --task $ID mark-r-$c-$MK; echo rc=\$?
W. With the Write tool (not Bash), write the one line mark-w-$c-$MK to $NEW
Then reply with exactly four lines, one per call: <letter> ran=<yes|refused|declined> rc=<n|none> err=<the error text verbatim, single quotes only, or none>"
  (cd "$WT" && env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
    -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_SESSION_ATTENDED \
    -u CLAUDE_PID -u CLAUDE_TMPDIR \
    PADDOCK_STATE_DIR="$ST" timeout "$WAIT" claude -p --settings "$2" --tools Bash,Write --allowedTools Bash,Write \
      --strict-mcp-config --no-session-persistence --output-format stream-json --verbose "$TASK" \
    > "$T/log-$c" 2>&1 < /dev/null)
  rc=$?; mkdir -p "$ROOT/.worker-scratch" && cp "$T/log-$c" "$ROOT/.worker-scratch/probe-245-$c.log"
  echo "RESULT run-$c: INFO claude -p exited $rc (124 = timeout; log kept in .worker-scratch/probe-245-$c.log)"
  o=no; l=no; r=no
  grep -qF "mark-o-$c-$MK" "$OWN" 2>/dev/null && o=yes
  [ -d "$ST/locks/$W/probe-lock-$c" ] && l=yes
  grep -qF "mark-r-$c-$MK" "$OWN" 2>/dev/null && r=yes
  w=no; { [ -e "$NEW" ] || [ -L "$NEW" ]; } && w=yes; rm -f "$NEW"; wt="$wt$w"
  echo "RESULT files-$c: INFO own-written=$o lock-made=$l report-written=$r write-tool-made=$w"
  b=no; grep -q '"dangerouslyDisableSandbox": *true' "$T/log-$c" && b=yes
  echo "RESULT bypass-$c: INFO the run asked to skip the sandbox: $b"
  echo "== $c report"; grep -o '[OLRW] ran=[^\\"]*' "$T/log-$c" | grep -v 'ran=<' | tail -n 4 | cut -c1-300
}

wt=; NEW=$ST/events/$CUR/person.jsonl
run generated "$PS"; g="$o$l$r"
run edit-deny "$T/edit-deny.json"; e="$o$l$r"
if [ "$g" = yesyesyes ] && [ "$e" = nonono ]; then echo "RESULT layer: EDIT-DENY (generated wrote all three; with the Edit deny on the state folder nothing was written)"
elif [ "$g" = yesnono ]; then echo "RESULT layer: FOLDER (own file written; the new folder inside the allowWrite'd lock folder refused without the Edit deny)"
elif [ "$g" = yesyesyes ] && [ "$e" = yesyesyes ]; then echo "RESULT layer: NONE (both cases wrote all three; see as-run)"
else echo "RESULT layer: INCONCLUSIVE (generated o/l/r=$g edit-deny o/l/r=$e)"; fi
if [ "$wt" = nono ]; then echo "RESULT hook: HOLDS (the Write tool made no file in the state folder)"
else echo "RESULT hook: FAIL (write-tool-made generated/edit-deny=$wt)"; fi
