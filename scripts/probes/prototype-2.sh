#!/bin/sh
# Host runbook for Prototype 2 (Issue #59): one task from the secretary to a pull request, with
# the worker's question answered on the card. What the run is, its steps and pass criteria:
# docs/design/prototype-2.md. Run from the paddock repository root, on the host where hc,
# herdr-app, claude and gh run. Phases, in order:
#
#   sh scripts/probes/prototype-2.sh prepare --project <git repo> --repo OWNER/NAME [--base main] [--task-id T]
#   sh scripts/probes/prototype-2.sh watch   --task-id T [--timeout 3600]
#   sh scripts/probes/prototype-2.sh note    --task-id T [--touch] "<what a person saw or did>"
#   sh scripts/probes/prototype-2.sh collect --task-id T
#   sh scripts/probes/prototype-2.sh cleanup --task-id T
#
# prepare: from a plain login shell (no agent above it; its first hc call may start the core,
#   which inherits this shell's environment). Checks the fixture, saves the run, prints the setup
#   commands and the request the person types. It runs no setup itself and starts nothing.
# watch: start it BEFORE typing the request and keep it running. Polls every 5 s and prints one
#   RESULT line per step as it holds, and "NOW:" lines when the person must act. Re-runnable;
#   what happened while it was not running is NO DATA.
# note: records an observation by eye (--touch: a person touched a terminal; it counts as a finding).
# collect: writes the evidence into the run folder and prints it. cleanup: removes only what
#   this run made (terminals by recorded created_ms, the worktree and local branch), puts the
#   saved org-state back when only this run's task is in it, and prints the gh command that
#   closes the PR; it never touches GitHub itself.
#
# The pull request goes to a throwaway branch work/<T> of the repository named with --repo, which
# must be the project's origin for both fetch and push. Never this repository (suisya-systems/paddock).
# Run folder: ${XDG_STATE_HOME:-~/.local/state}/paddock-proto2/<T>. Exit: 0 ok, 1 a FAIL or timeout,
# 2 bad argument, 3 a tool is missing, 4 prepare run inside an agent, 6 a precondition failed.
set -u

die() { c=$1; shift; echo "prototype-2: $*" >&2; exit "$c"; }
usage() { sed -n '2,32p' "$0"; }

phase=${1:-}; [ $# -gt 0 ] && shift
case "$phase" in
  prepare|watch|note|collect|cleanup) ;;
  -h|--help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
  *) die 2 "unknown phase: $phase" ;;
esac

project= repo= base=main T= timeout=3600 touch=0 text=
while [ $# -gt 0 ]; do
  case "$1" in
    --project|--repo|--base|--task-id|--timeout) [ $# -ge 2 ] || die 2 "$1 needs a value" ;;
  esac
  case "$1" in
    --project) project=$2; shift 2 ;;
    --repo) repo=$2; shift 2 ;;
    --base) base=$2; shift 2 ;;
    --task-id) T=$2; shift 2 ;;
    --timeout) timeout=$2; shift 2 ;;
    --touch) touch=1; shift ;;
    -*) die 2 "unknown option: $1" ;;
    *) [ "$phase" = note ] || die 2 "unexpected argument: $1"; text="$text${text:+ }$1"; shift ;;
  esac
done
case "$timeout" in ""|*[!0-9]*) die 2 "--timeout must be a number of seconds" ;; esac

ROOT=$(pwd)
[ -f "$ROOT/scripts/org" ] && [ -f "$ROOT/templates/worker.md" ] || die 2 "run from the paddock repository root"
ORG="$ROOT/scripts/org"
STATE=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}
# Mailbox lines and org-pull-request's ci_completed are both under $STATE (scripts/org, Issue #168).
evdirs() { printf '%s\n' "$STATE/events"; }
RUNS=${XDG_STATE_HOME:-$HOME/.local/state}/paddock-proto2
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
one_line() { tr -d '\n'; }
lc() { tr 'A-Z' 'a-z'; }

# owner/name of a GitHub URL, lowercase; empty for anything else.
gh_name() { printf '%s' "$1" | sed -n 's#^\(https://github\.com/\|git@github\.com:\|ssh://git@github\.com/\)\([^/]*/[^/]*\)$#\2#p' | sed 's#\.git$##; s#/$##' | lc; }

if [ "$phase" = prepare ]; then
  # Before any hc call (org-start's rule, Q17): the first hc command may start the core.
  for v in CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN; do
    [ -z "$(printenv "$v" 2>/dev/null)" ] || die 4 "$v is set: run prepare from a plain login shell, not inside an agent"
  done
  [ -n "$project" ] && [ -n "$repo" ] || die 2 "prepare needs --project and --repo"
  case "$project${PADDOCK_WORKERS_DIR:-}" in *"'"*) die 2 "a path with an apostrophe is not supported (the run file quotes paths with it)" ;; esac
  [ -n "$T" ] || T=p2-$(date -u +%Y%m%d%H%M)
  repo=$(printf '%s' "$repo" | lc)
  case "$repo" in */*) ;; *) die 2 "--repo must be OWNER/NAME" ;; esac
  [ "$repo" != suisya-systems/paddock ] || die 6 "never this repository: name a throwaway repository"
fi
[ -n "$T" ] || die 2 "$phase needs --task-id"
case "$T" in -*|*[!a-z0-9_-]*) die 2 "task id: lowercase letters, digits, _ and - only" ;; esac
[ ${#T} -le 30 ] || die 2 "task id: at most 30 characters"
RUN="$RUNS/$T"
W=w-$T

if [ "$phase" != prepare ]; then
  [ -f "$RUN/run.env" ] || die 6 "no run $T (no $RUN/run.env); run prepare first"
  . "$RUN/run.env"
fi

if [ "$phase" = note ]; then
  [ -n "$text" ] || die 2 "note needs a text"
  k=note; [ $touch -eq 1 ] && k=touch
  printf '%s\t%s\t%s\n' "$(now)" "$k" "$text" >> "$RUN/notes.tsv" || die 6 "cannot write $RUN/notes.tsv"
  echo "recorded ($k)"; exit 0
fi

for c in hc git gh bash awk sed grep; do command -v "$c" >/dev/null 2>&1 || die 3 "$c not found on PATH"; done
hcj() { hc get --json "$1" 2>/dev/null | one_line; }
field() { grep -Eo "\"$1\": *(\"[^\"]*\"|[0-9]+)" | head -n 1 | sed 's/^[^:]*: *//; s/"//g'; }
state_of() { hcj "$1" | grep -Eo '"status": *\{[^{}]*"state": *"[a-z]*"' | grep -Eo '"state": *"[a-z]*"' | tail -n 1 | sed 's/.*: *"//; s/"$//'; } # up to the state key: a status text may hold braces (org-suspend lib)
orgstate() { bash "$ORG" --as secretary doc get org-state 2>/dev/null | one_line; }

if [ "$phase" = prepare ]; then
  # The fixture: a git repository whose origin (fetch AND push) is the named throwaway repository.
  project=$(cd "$project" 2>/dev/null && pwd) || die 6 "no such folder: --project"
  git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || die 6 "$project is not a git repository"
  urls=$( { git -C "$project" remote get-url --all origin; git -C "$project" remote get-url --push --all origin; } 2>/dev/null)
  [ -n "$urls" ] || die 6 "$project has no origin"
  for u in $urls; do [ "$(gh_name "$u")" = "$repo" ] || die 6 "origin URL $u is not github.com/$repo (fetch and push must both be it)"; done
  git -C "$project" rev-parse --verify -q "$base^{commit}" >/dev/null || die 6 "base $base is not a commit in $project"
  for p in .claude .claude/settings.local.json paddock-proto2.txt; do
    git -C "$project" cat-file -e "$base:$p" 2>/dev/null && die 6 "base $base already has $p (org-delegate refuses .claude files; the task adds paddock-proto2.txt)"
  done
  workers=${PADDOCK_WORKERS_DIR:-$HOME/paddock-workers}
  WT=$workers/$T; BR=work/$T
  [ ! -e "$WT" ] || die 6 "$WT exists; pick another --task-id"
  ! git -C "$project" rev-parse --verify -q "refs/heads/$BR" >/dev/null || die 6 "branch $BR exists in $project; pick another --task-id"
  [ -z "$(git -C "$project" ls-remote --heads origin "$BR" 2>/dev/null)" ] || die 6 "branch $BR exists on origin; pick another --task-id"
  hc ls >/dev/null 2>&1 || die 6 "hc ls failed: the core is not reachable"
  hc get --json secretary >/dev/null 2>&1 && die 6 "a terminal named secretary exists; the run starts the secretary fresh from the template (hc kill / hc rm it, if it is yours to end)"
  hc get --json "$W" >/dev/null 2>&1 && die 6 "a terminal named $W exists"
  hc ls 2>/dev/null | grep -q "task_id=$T" && die 6 "a terminal labelled task_id=$T exists"
  os=$(bash "$ORG" --as secretary doc get org-state 2>&1) || die 6 "cannot read org-state, so the run cannot know it is free: $os"
  os=$(printf '%s' "$os" | one_line)
  printf '%s' "$os" | grep -Eq '"task_id"' && die 6 "org-state holds other work or approvals; the run needs the organization to itself (org-state: $os)"
  [ -d "$workers" ] || echo "prototype-2: note: $workers does not exist yet; org-delegate creates it, and its first worker meets the folder-trust dialog once (Q13)" >&2
  mkdir -p "$RUN" || die 6 "cannot create $RUN"
  [ ! -f "$RUN/run.env" ] || die 6 "run $T was prepared already ($RUN)"
  START=$(now)
  cat > "$RUN/run.env" <<EOF
PROJECT='$project'
REPO='$repo'
BASE='$base'
WT='$WT'
BR='$BR'
START='$START'
EOF
  printf '%s\n' "${os:-null}" > "$RUN/org-state.before"
  echo "RESULT preconditions: PASS (project origin = github.com/$repo for fetch and push; base $base; no secretary, no $W, org-state free)" | tee "$RUN/prepare.txt"
  # Core child notes must be off (decision 0002, Q2): a note typed into the secretary would move the loop.
  cfg=${APPDATA:-${XDG_CONFIG_HOME:-$HOME/.config}}/herdr-core
  nl=$(grep -rhs -E '^[[:space:]]*notes[[:space:]]*=' "$cfg" 2>/dev/null | head -n 1)
  case "$nl" in *false*) echo "RESULT notes-off: PASS ($nl)" | tee -a "$RUN/prepare.txt" ;;
    *) echo "RESULT notes-off: FAIL (no 'notes = false' under $cfg; set it before the run, decision 0002; a note typed into the secretary counts as a touch)" | tee -a "$RUN/prepare.txt" ;; esac
  # Role file paths, read from the worker template now (Issue #129 moved them once; read, do not assume).
  echo "== worker template names these role files (checked again by watch once org-start has placed them):"
  grep -Eo -- '--(append-system-prompt-file|settings) "[^"]*"' "$ROOT/templates/worker.md" | sed 's/^/   /'
  { [ -s "${PADDOCK_WORKER_GH_TOKEN_FILE:-$cfg/../paddock/worker-gh-token}" ] \
    && echo "RESULT worker-token: PASS (file exists, not read)" || echo "RESULT worker-token: FAIL (no read-only token file; see skills/org-start/SKILL.md, Worker token)"; } | tee -a "$RUN/prepare.txt"
  tee "$RUN/steps.txt" <<EOF

== Run $T prepared ($RUN). Do these in order:

1. In this login shell (not inside an agent): start the organization and the screen.
     bash skills/org-start/scripts/org-start.sh            # expect: ready, exit 0
     (org-start places the layout and mods/org-cockpit/ on the app's host and runs herdr-app check)
     run the layout.switch command org-start printed (herdr-app by its Windows path on WSL)
   Then look at the window: the secretary is in the centre. Record it:
     sh scripts/probes/prototype-2.sh note --task-id $T "layout open, secretary in the centre"
2. Start the watcher and keep it running (another shell is fine; an agent may run it):
     sh scripts/probes/prototype-2.sh watch --task-id $T
3. Type this request into the secretary's pane in herdr-app (one paragraph, as it is):

Delegate one task to a worker with the org-delegate skill: project $project, task id $T, base $base, branch $BR. The task text: "Add a file paddock-proto2.txt at the repository root holding the one line 'paddock prototype 2, task $T', and commit it on your branch. Before you create the file, report blocked with the question 'May I add paddock-proto2.txt at the repository root?'. Then wait for the answer: run check_messages every 15 seconds for up to 15 minutes, staying in your turn. Go on only if the answer is yes; on no, report done without changes." When the worker asks its question, do not answer it yourself: put it on the card with org-escalation ask --answer-in secretary, and when the ANSWER from the card is in your mailbox, forward it with org-escalation answer. When the worker reports done, open the pull request with the org-pull-request skill, --mode human --base $base --task-id $T, title "paddock prototype 2 run $T", and tell me its URL and the skill's exit code. Do not merge. This is a test run; the pull request goes to the throwaway repository $repo.

4. When watch prints "NOW: click Yes", click Yes on the card. Answer nothing else in any terminal;
   if you have to, do it, and record it: note --task-id $T --touch "<what and why>".
5. When watch ends: collect, then cleanup (both with --task-id $T).
EOF
  exit 0
fi

# ---- helpers on the mailbox (all months; only lines since the run started)
lines() {
  evdirs | while IFS= read -r d; do
    for id in secretary person "$W"; do cat "$d"/*/"$id".jsonl 2>/dev/null; done
  done | awk -v s="$START" 'match($0, /"ts":"[^"]*"/) { if (substr($0, RSTART + 6, RLENGTH - 7) >= s) print }'
}
has() { lines | grep -E "$1" | grep -q .; }
seq_of() { lines | grep -E "$1" | head -n 1 | sed -n 's/^{"seq":\([0-9]*\),.*/\1/p'; }
# acked <sender> <seq>: the secretary's ack line says it read <sender> up to at least <seq>.
acked() {
  [ -n "$2" ] || return 1
  lines | grep -E '"from":"secretary","kind":"ack"' | sed -n 's/.*"text":"\([^"]*\)".*/\1/p' \
    | awk -v w="$1" -v s="$2" '$1 == w && $2 + 0 >= s + 0 { f = 1 } END { exit !f }'
}

if [ "$phase" = watch ]; then

  res() { # res <step> <PASS|FAIL|NO DATA> <detail>: once per step and run
    [ -f "$RUN/res.$1" ] && return 0
    echo "RESULT $1: $2${3:+ ($3)}" | tee "$RUN/res.$1"
    return 0
  }
  once() { [ -f "$RUN/said.$1" ] || { : > "$RUN/said.$1"; echo "$2"; }; }
  log() { printf '%s\t%s\n' "$(now)" "$1" >> "$RUN/watch.log"; }
  hc events --json >> "$RUN/hc-events.jsonl" 2>/dev/null & EVPID=$!
. "$(dirname "$0")/claude-link.sh"
claude_link_save
  trap 'kill $EVPID 2>/dev/null; claude_link_restore' EXIT
  trap 'exit 130' INT TERM
  echo "== watching run $T (log: $RUN/watch.log; Ctrl-C stops, rerun resumes)"
  t=0; prev_s=; prev_w=; prev_os=; AID=$(cat "$RUN/approval.id" 2>/dev/null)
  while [ "$t" -lt "$timeout" ]; do
    # status of the two terminals, logged on change
    s=$(state_of secretary); w=$(state_of "$W")
    sb=0; wb=0; [ "$s" = blocked ] && [ "$prev_s" != blocked ] && sb=1; [ "$w" = blocked ] && [ "$prev_w" != blocked ] && wb=1
    [ "$s" = "$prev_s" ] || { log "secretary ${s:-none}"; prev_s=$s; }
    [ "$w" = "$prev_w" ] || { log "$W ${w:-none} $(hcj "$W" | grep -Eo '"status": *\{.*' | cut -c1-300)"; prev_w=$w; }
    os=$(orgstate)
    [ "$os" = "$prev_os" ] || { log "org-state $os"; printf '%s\t%s\n' "$(now)" "$os" >> "$RUN/org-state.log"; prev_os=$os; }

    # 1. the secretary from the template
    if [ -n "$s" ] && [ ! -f "$RUN/secretary.created" ]; then
      hcj secretary | field created_ms > "$RUN/secretary.created"
      res 1-secretary PASS "status $s"
      # role files, read from the template org-start placed: its $td (templates) and $bd (bin folder) expanded here
      td=${PADDOCK_CORE_TEMPLATES_DIR:-${APPDATA:-${XDG_CONFIG_HOME:-$HOME/.config}}/herdr-core/templates}
      bd=${PADDOCK_BIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/paddock/bin}
      miss=; for p in $(grep -Eo -- '--(append-system-prompt-file|settings) "[^"]*"' "$td/worker.md" 2>/dev/null | sed 's/^[^"]*"//; s/"$//; s#\$td#'"$td"'#; s#\$bd#'"$bd"'#'); do
        [ -f "$p" ] && echo "$p $(cksum < "$p")" >> "$RUN/role-files.txt" || miss="$miss $p"; done
      [ -s "$RUN/role-files.txt" ] && [ -z "$miss" ] && res 1-role-files PASS "$(wc -l < "$RUN/role-files.txt" | tr -d ' ') files placed" \
        || res 1-role-files FAIL "missing or unresolved:${miss:- none found in $td/worker.md}"
    fi
    # 3. worktree and settings
    if [ -d "$WT" ] && git -C "$PROJECT" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $WT"; then
      [ -f "$WT/.claude/settings.local.json" ] && [ "$(git -C "$WT" symbolic-ref --short HEAD 2>/dev/null)" = "$BR" ] && res 3-worktree PASS "$WT on $BR, settings.local.json written"
    fi
    # 4. worker started, labelled; its own start report shows the template command ran ($PADDOCK_ORG)
    if [ -n "$w" ] && [ ! -f "$RUN/worker.created" ]; then
      hcj "$W" | field created_ms > "$RUN/worker.created"
      hcj "$W" | grep -Eq "\"task_id\": *\"$T\"" && res 4-worker PASS "$W, label task_id=$T" || res 4-worker FAIL "$W has no label task_id=$T"
    fi
    has "\"from\":\"$W\",\"kind\":\"run_started\"" && res 4-worker-report PASS "$W wrote run_started through \$PADDOCK_ORG"
    printf '%s' "$os" | grep -Eq "\"work\": *\[[^]]*\"$T\"" && res 4-work-entry PASS "org-state.work holds $T"
    # 5. the question on the card
    has "\"from\":\"$W\",\"kind\":\"run_blocked\"" && res 5-blocked PASS "$W reported blocked"
    if [ -z "$AID" ]; then
      AID=$(printf '%s' "$os" | grep -Eo "\"id\": *\"$T-[0-9TZ]*\"" | head -n 1 | sed 's/.*: *"//; s/"$//')
      [ -n "$AID" ] && { echo "$AID" > "$RUN/approval.id"; res 5-approval PASS "org-state.approvals holds $AID"
        once click "NOW: click Yes on the card ($AID). Then record what the card showed: note --task-id $T \"card showed ...\""; }
    fi
    # 6. answered on the card; 7. the answer reaches the worker
    if [ -n "$AID" ]; then
      aq="\"from\":\"person\",\"kind\":\"[a-z_]*\",\"to\":\"secretary\".*\"text\":\"ANSWER $AID "
      if has "$aq"; then
        res 6-card-answer PASS "ANSWER $AID in the person's mailbox"
        if acked person "$(seq_of "$aq")"; then res 7-secretary-read PASS "the secretary read the ANSWER"
        elif [ "$s" = done ] || [ "$s" = idle ]; then
          once idle140 "NOW: the secretary is $s with the card's ANSWER unread. It should be waiting in 'org wait', which returns on mail within seconds (Issue #140); this is a finding. Give it 90 s (one 60 s check-in and a turn); if it does not move, type 'check your mailbox' into its conversation and record: note --task-id $T --touch \"nudged the secretary, #140\""
        fi
        has "\"from\":\"secretary\",.*\"to\":\"$W\".*Answer to your question \\($AID\\)" && res 7-forwarded PASS "answer sent to $W"
        printf '%s' "$os" | grep -q "$AID" || { [ -f "$RUN/res.7-forwarded" ] && res 7-approval-removed PASS "$AID left org-state"; }
      fi
    fi
    # blocked status is Claude Code's own prompt or dialog: the worker waits for its answer by polling,
    # in its turn (working). A prompt is answered in that terminal (Issue #127), so each one is a finding.
    if [ $wb -eq 1 ]; then
      echo "NOW: $W is blocked on a prompt or dialog in its own terminal (Issue #127). The card's button for it opens that terminal if the secretary recorded it with --answer-in worker. Answer it there, then: note --task-id $T --touch \"answered $W's prompt: <what it asked>\""
      log "finding: $W blocked on its own prompt"
    fi
    if [ $sb -eq 1 ]; then
      echo "NOW: the secretary is blocked on a prompt in its pane. Answer it there, then: note --task-id $T --touch \"answered the secretary's prompt: <what it asked>\""
      log "finding: secretary blocked on its own prompt"
    fi
    # 8. done, read by the secretary, committed
    dq="\"from\":\"$W\",\"kind\":\"run_completed\""
    if has "$dq"; then
      git -C "$PROJECT" log --format=%H -n 1 "$BR" -- paddock-proto2.txt 2>/dev/null | grep -q . \
        && res 8-done PASS "$W reported done; $BR has the commit" || res 8-done FAIL "$W reported done; no commit with paddock-proto2.txt on $BR"
      acked "$W" "$(seq_of "$dq")" && res 8-secretary-read PASS "the secretary read the completion"
    fi
    # 9. the pull request (gh read-only), and the CI record
    if [ ! -f "$RUN/pr.number" ] && [ -f "$RUN/res.8-done" ]; then
      n=$(gh pr list --repo "$REPO" --head "$BR" --state all --json number --jq '.[0].number' 2>/dev/null)
      [ -n "$n" ] && { echo "$n" > "$RUN/pr.number"; res 9-pull-request PASS "PR #$n on $BR"; }
    fi
    if [ -f "$RUN/pr.number" ]; then
      has "\"kind\":\"ci_completed\".*\"task_id\":\"$T\"" && res 9-ci-record PASS "ci_completed for $T"
      [ -f "$RUN/res.9-ci-record" ] && break
      [ -f "$RUN/pr.seen" ] || date +%s > "$RUN/pr.seen"
      [ $(( $(date +%s) - $(cat "$RUN/pr.seen") )) -gt 600 ] && break # no CI record 10 min after the PR
    fi
    t=$((t + 5)); sleep 5
  done
  # The summary is recomputed on every run of watch: only PASS and FAIL of a step are kept.
  {
  echo "== summary of run $T"
  rc=0
  for st in 1-secretary 1-role-files 3-worktree 4-worker 4-worker-report 4-work-entry 5-blocked 5-approval \
    6-card-answer 7-secretary-read 7-forwarded 7-approval-removed 8-done 8-secretary-read 9-pull-request 9-ci-record; do
    if [ -f "$RUN/res.$st" ]; then cat "$RUN/res.$st"; grep -q ': PASS' "$RUN/res.$st" || rc=1
    else echo "RESULT $st: NO DATA (not seen while watch ran, or not reached)"; [ "$st" = 9-ci-record ] || rc=1; fi
  done
  touches=$(grep -c "$(printf '\ttouch\t')" "$RUN/notes.tsv" 2>/dev/null); found=$(grep -c "finding:" "$RUN/watch.log" 2>/dev/null)
  if [ "${touches:-0}" -eq 0 ] && [ "${found:-0}" -eq 0 ]; then echo "RESULT 10-no-touch: PASS (no touch noted, no prompt seen)"
  else echo "RESULT 10-no-touch: FAIL (${touches:-0} touch notes, ${found:-0} prompts in the status log; see notes.tsv, watch.log)"; rc=1; fi
  echo "== watch ended; next: collect --task-id $T"
  echo $rc > "$RUN/watch.rc"
  } | tee "$RUN/watch-summary.txt"
  exit "$(cat "$RUN/watch.rc")"
fi

if [ "$phase" = collect ]; then
  E="$RUN/evidence"; mkdir -p "$E" || die 6 "cannot create $E"
  { echo "== versions"; hc --version 2>&1; herdr-app --version 2>&1; claude --version 2>&1; gh --version 2>&1 | head -n 1
    echo "== results (prepare, then the last watch summary)"; cat "$RUN/prepare.txt" "$RUN/watch-summary.txt" 2>/dev/null
    echo "== notes"; cat "$RUN/notes.tsv" 2>/dev/null
    echo "== hc ls"; hc ls 2>&1
    echo "== hc get secretary"; hcj secretary; echo
    echo "== hc get $W"; hcj "$W"; echo
    echo "== list_runs"; bash "$ORG" --as secretary list_runs 2>&1
    echo "== mailbox lines since $START (secretary, person, $W; acks and ci_completed included)"; lines
    echo "== org-state now"; orgstate; echo
    echo "== org-state changes"; cat "$RUN/org-state.log" 2>/dev/null
    echo "== status log"; cat "$RUN/watch.log" 2>/dev/null
    echo "== role files (path, cksum)"; cat "$RUN/role-files.txt" 2>/dev/null
    echo "== $BR"; git -C "$PROJECT" log --oneline "$BASE..$BR" 2>&1
    echo "== pull request"; [ -f "$RUN/pr.number" ] && gh pr view "$(cat "$RUN/pr.number")" --repo "$REPO" --json number,url,state,headRefName,baseRefName,createdAt 2>&1
    echo "== hc events lines: $(wc -l < "$RUN/hc-events.jsonl" 2>/dev/null || echo 0) (in $RUN/hc-events.jsonl)"
  } > "$E/summary.txt" 2>&1
  cat "$E/summary.txt"
  echo "== written to $E/summary.txt (keep the PR URL private unless the owner agrees to publish it)"
  exit 0
fi

# cleanup: only what this run made. A terminal goes only when its created_ms is the one watch recorded.
end_term() { # end_term <name> <recorded created_ms file>
  c=$(cat "$2" 2>/dev/null); [ -n "$c" ] || { echo "keep $1: never recorded by watch"; return 0; }
  [ -n "$(hcj "$1")" ] || { echo "gone $1: already removed (by the secretary or by hand)"; return 0; }
  [ "$(hcj "$1" | field created_ms)" = "$c" ] || { echo "keep $1: not the terminal this run saw"; return 0; }
  hc kill "$1" >/dev/null 2>&1; hc rm "$1" >/dev/null 2>&1 && echo "removed terminal $1" || echo "could not remove $1"
}
end_term "$W" "$RUN/worker.created"
if [ -f "$RUN/pr.number" ]; then
  ci=ci-$(cat "$RUN/pr.number"); hc get --json "$ci" >/dev/null 2>&1 && echo "left $ci: started --rm by org-pull-request; it goes when it ends"
fi
end_term secretary "$RUN/secretary.created"
if [ -d "$WT" ]; then git -C "$PROJECT" worktree remove --force "$WT" && echo "removed worktree $WT" || echo "could not remove $WT"; fi
git -C "$PROJECT" branch -D "$BR" >/dev/null 2>&1 && echo "deleted local branch $BR"
os=$(orgstate)
others=$(printf '%s' "$os" | grep -Eo '"task_id": *"[^"]*"' | grep -v "\"$T\"" | head -n 1)
if [ -n "$others" ]; then echo "org-state kept: it holds another task ($others); remove $T's entries by hand"
elif printf '%s' "$os" | grep -q "\"$T"; then
  bash "$ORG" --as secretary doc set org-state < "$RUN/org-state.before" && echo "org-state put back to its value before the run"
fi
[ -f "$RUN/pr.number" ] && echo "To close the pull request and delete the remote branch (a person decides): gh pr close $(cat "$RUN/pr.number") --repo $REPO --delete-branch"
echo "evidence kept in $RUN"
