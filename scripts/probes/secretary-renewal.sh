#!/bin/sh
# Probe for Issue #116 (Q16, HND-2): does a secretary renewal work end to end?
# A real Claude Code secretary writes the secretary-handover document and starts
# one labelled worker; skills/secretary-handover/scripts/secretary-handover.sh ends
# its terminal and launches a fresh secretary with "resume from the handover" as
# the task; the new secretary should find the worker by its label and clear the
# document. The checklist of what to record is scripts/probes/secretary-renewal.md.
#
# Run from the repo root, on a host where herdr-core (hc) and claude run, in a
# plain login shell with NO agent above it (the handover script refuses otherwise):
#   sh scripts/probes/secretary-renewal.sh
#   sh scripts/probes/secretary-renewal.sh --dry-run    # stubbed hc, no core, no claude (CI)
# Takes about 3-8 minutes. Needs hc, claude (logged in), bash, POSIX sh, grep, tr, sleep.
#
# What it touches: it starts its OWN core (HC_SESSION=p116-<pid>, XDG_CONFIG_HOME under
# a private temp folder), so your real core, templates folder, org-state and secretary
# are not read or changed. Inside that core the terminals are named secretary (the name
# the layout mod looks for) and p116-w (a `sleep` stand-in worker, label task_id=p116-w,
# started by the secretary with --outlive-parent). The cleanup trap kills and removes
# both, stops ONLY that temp core, and deletes the temp folder.
#
# The secretary is a real Claude Code in default permission mode, so it will ask before
# running hc. The script says when it is blocked: answer in that terminal with
#   HC_SESSION=<printed> hc attach secretary
# (detach again), or the probe waits until SEC_WAIT seconds and reports FAIL.
#
# Environment: SEC_WAIT (default 600) seconds for the secretary to write the handover;
# RESUME_WAIT (default 240) seconds for the new secretary to clear it; KEEP=1 holds the
# core open after the checks (press Enter) so you can look at herdr-app's layout.
#
# Reading the output. Every verdict line starts with "RESULT <name>:". PASS / FAIL, or
# NO DATA when the probe could not see it. Then paste the whole output back.
set -u

DRY=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
  *) echo "secretary-renewal: unknown argument: $1" >&2; exit 2 ;;
esac

SEC=secretary
WK=p116-w
MARK=PROBE116-MARKER
VARS="CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN"
SEC_WAIT=${SEC_WAIT:-600}
RESUME_WAIT=${RESUME_WAIT:-240}
FAILS=0

ROOT=$(pwd)
HANDOVER="$ROOT/skills/secretary-handover/scripts/secretary-handover.sh"
[ -f "$HANDOVER" ] && [ -f "$ROOT/templates/secretary.md" ] || { echo "RESULT precondition-failed: run from the repo root"; exit 1; }
command -v bash >/dev/null 2>&1 || { echo "RESULT precondition-failed: bash not on PATH"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/probe116.XXXXXX") || exit 1 # private (0700)
CWD="$WORK/cwd"; XDG="$WORK/xdg"; mkdir -p "$CWD" "$XDG" || exit 1

if [ $DRY -eq 1 ]; then
  # A stand-in hc: files under $STUB say which terminals exist and what the document holds.
  STUB="$WORK/stub"; mkdir -p "$STUB/bin"; export STUB
  echo '{"jsonrpc":"2.0","id":1,"result":{"value":null,"version":0}}' > "$STUB/doc"
  echo 1000 > "$STUB/clock"
  cat > "$STUB/bin/hc" <<'EOF2'
#!/bin/sh
cmd=${1:-}; [ $# -gt 0 ] && shift
name=; prev=; task=
for a in "$@"; do
  case "$prev" in --name) name=$a ;; esac
  case "$a" in --*|-) ;; *) case "$prev" in --name|--cwd|--label) ;; *) task=$a ;; esac ;; esac
  prev=$a
done
last=$(for a in "$@"; do echo "$a"; done | tail -n 1)
case "$cmd" in
  --version) echo "hc stub" ;;
  connect) cat >/dev/null; cat "$STUB/doc" ;;
  ls) ls "$STUB" | sed -n 's/^term-//p' ;;
  get) n=$last; [ -f "$STUB/term-$n" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       printf '{"name":"%s","state":"live","created_ms":%s,"labels":%s,"status":{"app":"claude-code","state":"done"}}\n' \
         "$n" "$(cat "$STUB/term-$n")" "$([ "$n" = p116-w ] && echo '{"task_id":"p116-w"}' || echo '{}')" ;;
  run) c=$(( $(cat "$STUB/clock") + 1 )); echo $c > "$STUB/clock"; echo $c > "$STUB/term-$name"
       case "$name" in secretary)
         case "$last" in Resume*) echo '{"jsonrpc":"2.0","id":1,"result":{"value":null,"version":5}}' > "$STUB/doc" ;;
         *) echo $((c+500)) > "$STUB/term-p116-w"
            echo '{"jsonrpc":"2.0","id":1,"result":{"value":{"last_exchange":"PROBE116-MARKER"},"version":4}}' > "$STUB/doc" ;; esac ;; esac
       echo '{"first_message":{"sent":true,"started":true,"turn":0}}' ;;
  kill|rm) rm -f "$STUB/term-$last" 2>/dev/null; [ "$cmd" = rm ] || true; echo '{}' ;;
  read) echo "stub screen: back as secretary; found worker p116-w by label" ;;
  *) : ;;
esac
exit 0
EOF2
  chmod +x "$STUB/bin/hc"
  PATH="$STUB/bin:$PATH"; export PATH
  TICK=0; SEC_WAIT=20; RESUME_WAIT=20
else
  command -v hc >/dev/null 2>&1 || { echo "RESULT precondition-failed: hc not on PATH"; exit 1; }
  command -v claude >/dev/null 2>&1 || { echo "RESULT precondition-failed: claude not on PATH"; exit 1; }
  TICK=3
  HC_SESSION=p116-$$; export HC_SESSION
  XDG_CONFIG_HOME=$XDG; export XDG_CONFIG_HOME
fi

cleanup() {
  hc kill $SEC >/dev/null 2>&1; hc rm $SEC >/dev/null 2>&1
  hc kill $WK >/dev/null 2>&1; hc rm $WK >/dev/null 2>&1
  [ $DRY -eq 1 ] || hc server stop >/dev/null 2>&1 # HC_SESSION is the temp core's: yours is untouched
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

result() { # result <name> <PASS|FAIL|NO DATA> <detail>
  echo "RESULT $1: $2${3:+ ($3)}"
  [ "$2" = FAIL ] && FAILS=$((FAILS + 1))
  return 0
}
doc_get() { # the handover document's raw answer; hc has no document verb (input held open 1 s)
  { printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"doc.get","params":{"name":"secretary-handover"}}'; sleep 1; } | hc connect 2>/dev/null
}
one_line() { tr -d '\n'; }
field() { # field <json-on-stdin> <key>: the first value of "key": in the JSON
  one_line | grep -Eo "\"$1\": *(\"[^\"]*\"|[0-9]+)" | head -n 1 | sed "s/^[^:]*: *//"
}
trust_dialog() { # answer Claude Code's folder-trust dialog (Enter), like probe 52
  case "$(hc read $SEC 2>/dev/null)" in *"Quick safety check"*|*"trust this folder"*) echo "-- answering the folder-trust dialog"; hc keys $SEC enter >/dev/null 2>&1 ;; esac
}
state_of() { hc get --json "$1" 2>/dev/null | one_line | grep -Eo '"status": *\{[^{}]*"state": *"[a-z]*"' | grep -Eo '"[a-z]*"$' | tr -d '"'; }
quiet() { [ "$1" = idle ] || [ "$1" = done ]; } # a real Claude Code reports done between turns (Q12)

# The runner's own environment, names only. The handover script refuses (exit 4) in an agent.
RUNNER=
for v in $VARS; do [ -n "$(printenv "$v" 2>/dev/null)" ] && RUNNER="$RUNNER $v"; done
if [ -z "$RUNNER" ]; then result runner-env PASS "clean"; else result runner-env FAIL "agent variables set:$RUNNER; run from a login shell"; fi

echo "== versions"; hc --version 2>&1; [ $DRY -eq 1 ] || claude --version 2>&1
echo "== temp core session ${HC_SESSION:-stub}; terminals $SEC and $WK; private temp folders"
echo "== to look inside: HC_SESSION=${HC_SESSION:-stub} hc attach $SEC   (detach again)"

# 1. A real secretary from the template, with the whole test as its first task.
mkdir -p "$XDG/herdr-core/templates" && cp -f "$ROOT/templates/secretary.md" "$XDG/herdr-core/templates/secretary.md" \
  || { result setup FAIL "cannot place the template"; exit 1; }
TASK="This is probe 116 of the paddock organization; do exactly these steps, then stop and wait. 1) Start one worker stand-in: hc run --bg --outlive-parent --name $WK --label task_id=$WK -- sleep 3600 (check first_message is not needed here). 2) Write the core document org-state (doc.get then doc.set through hc connect) with a work list holding one entry {task_id: $WK, title: probe worker, since: <now, UTC ISO 8601>}, an empty approvals list and updated_at. 3) Write the core document secretary-handover with last_exchange \"$MARK: probe 116 asked for a handover test\", unrecorded_decisions an empty list, open_threads one entry {task_id: $WK, promised: nothing, expect: nothing}, and written_at. 4) Say 'handover ready' and stop. Do not end your own terminal and do not run any script from skills/."
echo "== start the secretary"
# hc run waits for the status before the first message, so the trust dialog is answered while it is pending.
( cd "$CWD" && hc run --bg --keep --name $SEC secretary "$TASK" > "$WORK/run.out" 2>&1; echo $? > "$WORK/run.rc" ) &
t=0; while [ ! -f "$WORK/run.rc" ] && [ $t -lt 120 ]; do trust_dialog; t=$((t + 2)); sleep $((TICK > 0 ? 2 : 0)); done
out=$(cat "$WORK/run.out" 2>/dev/null); [ "$(cat "$WORK/run.rc" 2>/dev/null)" = 0 ] || { result secretary-start FAIL "hc run failed or hung: $out"; exit 1; }
printf '%s' "$out" | one_line | grep -Eq '"sent": *true' && result secretary-start PASS "first_message.sent true" \
  || result secretary-start FAIL "first_message.sent is not true: $out"

# 2. Wait for the handover document (the secretary asks for permissions: say so once).
echo "== waiting up to ${SEC_WAIT}s for the secretary to write secretary-handover (answer its prompts: HC_SESSION=${HC_SESSION:-stub} hc attach $SEC)"
t=0; said=0; written=0
while [ $t -lt "$SEC_WAIT" ]; do
  trust_dialog
  if doc_get | grep -q "$MARK"; then written=1; break; fi
  if [ "$(state_of $SEC)" = blocked ] && [ $said -eq 0 ]; then said=1; echo "-- the secretary is blocked on a prompt: answer it with HC_SESSION=${HC_SESSION:-stub} hc attach $SEC"; fi
  t=$((t + TICK + 1)); sleep $TICK
done
[ $written -eq 1 ] && result handover-written PASS "document holds $MARK after ~${t}s" \
  || { result handover-written FAIL "no $MARK in secretary-handover after ${SEC_WAIT}s"; echo "== screen tail"; hc read $SEC 2>&1 | tail -n 15; exit 1; }
hc ls 2>&1 | grep -q "$WK" && hc get --json $WK 2>&1 | one_line | grep -Eq '"task_id": *"'$WK'"' \
  && result worker-started PASS "$WK live with label task_id=$WK" || result worker-started FAIL "$WK missing or unlabelled; see hc ls below"
echo "== hc ls (before)"; hc ls 2>&1

# The old secretary must be idle (the handover script refuses a turn in progress, Q18).
i=0; while [ $i -lt 30 ]; do s=$(state_of $SEC); quiet "$s" && break; i=$((i + 1)); sleep $TICK; done
result old-secretary-idle "$(quiet "${s:-}" && echo PASS || echo FAIL)" "state ${s:-none}"
OLD=$(hc get --json $SEC 2>&1 | field created_ms); OLDWK=$(hc get --json $WK 2>&1 | field created_ms)
echo "-- before: $SEC $OLD, $WK $OLDWK"

# 3. The renewal itself, run as the person would: from this login shell.
echo "== run secretary-handover.sh"
HOUT=$(cd "$CWD" && PADDOCK_SECRETARY_NAME=$SEC bash "$HANDOVER" 2>&1); HRC=$?
printf '%s\n' "$HOUT"
if [ "$HRC" = 0 ]; then result handover-exit PASS "0"; else result handover-exit FAIL "$HRC (code table: skills/secretary-handover/SKILL.md)"; fi
NEW=$(hc get --json $SEC 2>&1 | field created_ms)
if [ -n "$NEW" ] && [ "$NEW" != "$OLD" ]; then result new-terminal PASS "created_ms $OLD -> $NEW, a different terminal under the same name"
else result new-terminal FAIL "created_ms before '$OLD' after '$NEW'"; fi

# 4. The new secretary resumes: it clears the document (doc.set null) once it has read it.
echo "== waiting up to ${RESUME_WAIT}s for the new secretary to clear the document"
t=0; cleared=0
while [ $t -lt "$RESUME_WAIT" ]; do
  trust_dialog
  if doc_get | one_line | grep -Eq '"value": *null'; then cleared=1; break; fi
  t=$((t + TICK + 1)); sleep $TICK
done
[ $cleared -eq 1 ] && result document-cleared PASS "value null after ~${t}s" || result document-cleared FAIL "document still set after ${RESUME_WAIT}s (a prompt may be blocking the new secretary: hc attach $SEC)"
WKJ=$(hc get --json $WK 2>&1 | one_line)
if [ -n "$OLDWK" ] && [ "$(printf '%s' "$WKJ" | field created_ms)" = "$OLDWK" ] && printf '%s' "$WKJ" | grep -Eq '"state": *"live"'; then
  result worker-survived PASS "$WK is the same terminal and still live"
else result worker-survived FAIL "$WK gone, replaced or not live"; fi
hc get --json $WK 2>&1 | one_line | grep -Eq '"task_id": *"'$WK'"' && result worker-label PASS "task_id=$WK" || result worker-label FAIL "label lost"
LABELS=$(hc get --json $SEC 2>&1 | one_line | grep -Eo '"labels": *\{[^}]*\}')
echo "-- new secretary labels: ${LABELS:-none} (herdr.space / herdr.tab appear only once herdr-app has adopted it)"
sleep 2
SCREEN=$(hc read $SEC 2>&1)
case "$SCREEN" in *"$WK"*) result new-secretary-names-worker PASS "$WK is on its screen" ;; *) result new-secretary-names-worker NO DATA "read the screen tail below by eye" ;; esac
echo "== screen tail of the new secretary (by eye: did it say it is back and name $WK?)"
printf '%s\n' "$SCREEN" | tail -n 15
echo "== hc ls (after)"; hc ls 2>&1

# 5. The layout cannot be read by a script.
cat <<EOF
== LAYOUT (by eye, not scripted): with herdr-app attached to this probe's core (HC_SESSION=${HC_SESSION:-stub}) and the
   organization layout open, did $WK stay as a worker tile on the left, and did the new secretary take the centre block
   without a second empty block? Record yes / no / not observed (no app attached). Details: scripts/probes/secretary-renewal.md
EOF
if [ "${KEEP:-0}" = 1 ] && [ $DRY -eq 0 ]; then echo "== KEEP=1: the core stays up. Look at the layout, then press Enter to clean up."; read dummy; fi
echo "== done; paste everything above back"
[ $FAILS -eq 0 ]
