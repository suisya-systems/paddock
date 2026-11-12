#!/bin/sh
# Host runbook for Prototype 3 (Issue #243): one task from a typed request to a pull request that
# passes the acceptance job, on a clean checkout of main, with the worker's question answered on
# the card, an acceptance test first and a review by a second model through the gate. What the run
# is, its steps and pass criteria: docs/design/prototype-3.md. Run from the paddock repository root (the
# script itself may sit in another checkout; it reads its fixture from its own folder),
# on the host where hc, herdr-app, claude, codex and gh run. Every step runs inside herdr: prepare,
# org-start and layout.switch from a plain shell terminal in herdr (an agent already in herdr makes it
# with hc and types into it; making it is set-up, not a touch), watch from there or from an agent.
# herdr's own terminals are the only shells the run needs. Phases, in order:
#
#   sh scripts/probes/prototype-3.sh prepare --project <git repo> --repo OWNER/NAME [--base main] [--task-id T]
#   sh scripts/probes/prototype-3.sh watch   --task-id T [--timeout 5400]
#   sh scripts/probes/prototype-3.sh note    --task-id T [--touch] "<what a person saw or did>"
#   sh scripts/probes/prototype-3.sh collect --task-id T
#   sh scripts/probes/prototype-3.sh cleanup --task-id T
#
# prepare: from a terminal in herdr. The core must already be running (the process herdr-core serve; no hc
#   call can tell, any may start it): prepare never starts it, so the core's environment is never this shell's or an agent's. Checks the
#   paddock checkout, the fixture and the host, saves the run and the request, prints the setup
#   commands. It starts nothing.
# watch: start it and keep it running. Polls every 5 s and prints one RESULT line per step as it
#   holds, and "NOW:" lines when the person must act. It sends the request itself (hc send to the
#   secretary) once the secretary reports a status, and records that in the notes. Re-runnable;
#   the history files last, so most steps are read back after the fact.
# note: records an observation by eye (--touch: a person touched a terminal; it counts as a finding).
# collect: writes the evidence into the run folder and prints it. cleanup: removes only what
#   this run made (terminals by recorded created_ms, the worktree and local branch), puts the
#   saved org-state back when only this run's task is in it, and prints the gh command that
#   closes the PR; it never touches GitHub itself.
#
# The pull request goes to a throwaway branch work/<T> of the repository named with --repo, which
# must be the project's origin for both fetch and push, and whose base holds the acceptance job
# (scripts/probes/prototype-3-acceptance.yml) and scripts/acceptance-check.sh. Never suisya-systems/paddock.
# Run folder: ${XDG_STATE_HOME:-~/.local/state}/paddock-proto3/<T>. Exit: 0 ok, 1 a FAIL or timeout,
# 2 bad argument, 3 a tool is missing, 6 a precondition failed (the core not running is one).
set -u

die() { c=$1; shift; echo "prototype-3: $*" >&2; exit "$c"; }
usage() { sed -n '2,36p' "$0"; }

phase=${1:-}; [ $# -gt 0 ] && shift
case "$phase" in
  prepare|watch|note|collect|cleanup) ;;
  -h|--help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
  *) die 2 "unknown phase: $phase" ;;
esac

project= repo= base=main T= timeout=5400 touch=0 text=
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
HERE=$(cd "$(dirname "$0")" && pwd)
FIXTURE="$HERE/prototype-3-acceptance.yml" # beside this script: the run may call it from another checkout
STATE=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}
RUNS=${XDG_STATE_HOME:-$HOME/.local/state}/paddock-proto3
TESTF=tests/paddock-proto3.test.sh
FILE=paddock-proto3.txt
TAB=$(printf '\t')
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
one_line() { tr -d '\n'; }
lc() { tr 'A-Z' 'a-z'; }

# owner/name of a GitHub URL, lowercase; empty for anything else.
gh_name() { printf '%s' "$1" | sed -n 's#^\(https://github\.com/\|git@github\.com:\|ssh://git@github\.com/\)\([^/]*/[^/]*\)$#\2#p' | sed 's#\.git$##; s#/$##' | lc; }

if [ "$phase" = prepare ]; then
  [ -n "$project" ] && [ -n "$repo" ] || die 2 "prepare needs --project and --repo"
  case "$project${PADDOCK_WORKERS_DIR:-}" in *"'"*) die 2 "a path with an apostrophe is not supported (the run file quotes paths with it)" ;; esac
  [ -n "$T" ] || T=p3-$(date -u +%Y%m%d%H%M)
  repo=$(printf '%s' "$repo" | lc)
  case "$repo" in */*) ;; *) die 2 "--repo must be OWNER/NAME" ;; esac
  [ "$repo" != suisya-systems/paddock ] || die 6 "never this repository: name a throwaway repository"
  # Host rule: claude relinks ~/.local/bin/claude to the data folder it runs with (Issue #213).
  [ -z "${XDG_DATA_HOME:-}" ] || die 6 "XDG_DATA_HOME is set; the run uses the host's data folder: unset it in this shell"
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

# herdr-app is a Windows program when the core runs in WSL: not on PATH there, so find it by its path.
HERDR_APP=$(command -v herdr-app 2>/dev/null)
if [ -z "$HERDR_APP" ]; then
  for f in "${PADDOCK_HERDR_APP:-}" /mnt/c/Users/*/AppData/Local/Programs/herdr-app/herdr-app.exe; do
    [ -n "$f" ] && [ -x "$f" ] && { HERDR_APP=$f; break; }
  done
fi
[ -n "$HERDR_APP" ] || HERDR_APP=herdr-app # not found: the commands say so when run (PADDOCK_HERDR_APP names it)
for c in hc git gh bash awk sed grep cmp pgrep; do command -v "$c" >/dev/null 2>&1 || die 3 "$c not found on PATH"; done
hcj() { hc get --json "$1" 2>/dev/null | one_line; }
field() { grep -Eo "\"$1\": *(\"[^\"]*\"|[0-9]+)" | head -n 1 | sed 's/^[^:]*: *//; s/"//g'; }
state_of() { hcj "$1" | grep -Eo '"status": *\{[^{}]*"state": *"[a-z]*"' | grep -Eo '"state": *"[a-z]*"' | tail -n 1 | sed 's/.*: *"//; s/"$//'; } # up to the state key: a status text may hold braces
orgstate() { bash "$ORG" --as secretary doc get org-state 2>/dev/null | one_line; }

if [ "$phase" = prepare ]; then
  # Host rule (org-start's Q17): the first hc command starts a core that inherits the caller's
  # environment. Every hc command can start one (even `hc server status`, hc 0.1.20 on Unix), so the
  # check calls no hc: the core is the process `herdr-core serve`.
  pgrep -f '(^|/)herdr-core serve' >/dev/null 2>&1 || die 6 "the core is not running: start herdr first (this runbook never starts the core, so it never gets this shell's environment)"
  # The paddock checkout: main, clean, at origin/main (the loop is run on today's main).
  pb=$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null)
  [ "$pb" = main ] || die 6 "the paddock checkout is on '${pb:-detached}', not main"
  [ -z "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ] || die 6 "the paddock checkout is not clean (git status --porcelain shows changes or untracked files)"
  phead=$(git -C "$ROOT" rev-parse HEAD)
  [ "$phead" = "$(git -C "$ROOT" rev-parse -q --verify origin/main 2>/dev/null)" ] \
    || die 6 "the paddock checkout is not at origin/main: git fetch origin && git merge --ff-only origin/main"
  # The fixture: a git repository whose origin (fetch AND push) is the named throwaway repository.
  project=$(cd "$project" 2>/dev/null && pwd) || die 6 "no such folder: --project"
  git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || die 6 "$project is not a git repository"
  urls=$( { git -C "$project" remote get-url --all origin; git -C "$project" remote get-url --push --all origin; } 2>/dev/null)
  [ -n "$urls" ] || die 6 "$project has no origin"
  for u in $urls; do [ "$(gh_name "$u")" = "$repo" ] || die 6 "origin URL $u is not github.com/$repo (fetch and push must both be it)"; done
  # org-delegate branches from origin/<base> after a fetch; check what it will branch from.
  git -C "$project" fetch -q origin || die 6 "git fetch origin failed in $project"
  ob=origin/$base
  git -C "$project" rev-parse --verify -q "$ob^{commit}" >/dev/null || die 6 "$ob is not a commit in $project"
  for p in .claude .claude/settings.local.json "$FILE" "$TESTF"; do
    git -C "$project" cat-file -e "$ob:$p" 2>/dev/null && die 6 "$ob already has $p (org-delegate refuses .claude files; the task adds $FILE and $TESTF)"
  done
  # The acceptance job of the throwaway repository: the fixture workflow alone, and paddock's checker.
  git -C "$project" show "$ob:scripts/acceptance-check.sh" 2>/dev/null | cmp -s - "$ROOT/scripts/acceptance-check.sh" \
    || die 6 "$ob has no scripts/acceptance-check.sh equal to this checkout's; seed it (docs/design/prototype-3.md, Seed the throwaway repository)"
  git -C "$project" show "$ob:.github/workflows/acceptance.yml" 2>/dev/null | cmp -s - "$FIXTURE" \
    || die 6 "$ob has no .github/workflows/acceptance.yml equal to $FIXTURE; seed it (docs/design/prototype-3.md)"
  wf=$(git -C "$project" ls-tree --name-only "$ob" .github/workflows/ 2>/dev/null)
  [ "$wf" = .github/workflows/acceptance.yml ] \
    || die 6 "$ob has other workflows ($(echo $wf)); org-pull-request watches one run per commit, so the acceptance job must be the only one"
  workers=${PADDOCK_WORKERS_DIR:-$HOME/paddock-workers}
  WT=$workers/$T; BR=work/$T
  [ ! -e "$WT" ] || die 6 "$WT exists; pick another --task-id"
  ! git -C "$project" rev-parse --verify -q "refs/heads/$BR" >/dev/null || die 6 "branch $BR exists in $project; pick another --task-id"
  [ -z "$(git -C "$project" ls-remote --heads origin "$BR" 2>/dev/null)" ] || die 6 "branch $BR exists on origin; pick another --task-id"
  hc ls >/dev/null 2>&1 || die 6 "hc ls failed: the core is not reachable"
  hc get --json secretary >/dev/null 2>&1 && die 6 "a terminal named secretary exists; the run starts the secretary fresh from the template (end it with org-down --secretary, if it is yours to end)"
  hc get --json "$W" >/dev/null 2>&1 && die 6 "a terminal named $W exists"
  hc ls 2>/dev/null | grep -q "task_id=$T" && die 6 "a terminal labelled task_id=$T exists"
  os=$(bash "$ORG" --as secretary doc get org-state 2>&1) || die 6 "cannot read org-state, so the run cannot know it is free: $os"
  os=$(printf '%s' "$os" | one_line)
  printf '%s' "$os" | grep -Eq '"task_id"' && die 6 "org-state holds other work or approvals; the run needs the organization to itself (org-state: $os)"
  [ -d "$workers" ] || echo "prototype-3: note: $workers does not exist yet; org-delegate creates it, and its first worker meets the folder-trust dialog once (Q13)" >&2
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
PADDOCK_HEAD='$phead'
EOF
  printf '%s\n' "${os:-null}" > "$RUN/org-state.before"
  echo "RESULT preconditions: PASS (paddock main at $phead, clean; origin = github.com/$repo for fetch and push; $ob has the acceptance job and no $FILE; no secretary, no $W, org-state free)" | tee "$RUN/prepare.txt"
  # Core child notes must be off (decision 0002, Q2): a note typed into the secretary would move the loop.
  cfg=${APPDATA:-${XDG_CONFIG_HOME:-$HOME/.config}}/herdr-core
  nl=$(grep -rhs -E '^[[:space:]]*notes[[:space:]]*=' "$cfg" 2>/dev/null | head -n 1)
  case "$nl" in *false*) echo "RESULT notes-off: PASS ($nl)" | tee -a "$RUN/prepare.txt" ;;
    *) echo "RESULT notes-off: FAIL (no 'notes = false' under $cfg; set it before the run, decision 0002; a note typed into the secretary counts as a touch)" | tee -a "$RUN/prepare.txt" ;; esac
  { [ -s "${PADDOCK_WORKER_GH_TOKEN_FILE:-$cfg/../paddock/worker-gh-token}" ] \
    && echo "RESULT worker-token: PASS (file exists, not read)" || echo "RESULT worker-token: FAIL (no read-only token file; see skills/org-start/SKILL.md, Worker token)"; } | tee -a "$RUN/prepare.txt"
  # The review gate calls the reviewing CLI with the login in CODEX_HOME (scripts/second-model-review.sh).
  { if command -v codex >/dev/null 2>&1 && [ -e "${CODEX_HOME:-$HOME/.codex}/auth.json" ]; then
      echo "RESULT codex-cli: PASS ($(codex --version 2>/dev/null | head -n 1); login file exists, not read)"
    else echo "RESULT codex-cli: FAIL (codex not on PATH or no ${CODEX_HOME:-~/.codex}/auth.json; the gate would end 'unavailable' or 'not-established')"; fi; } | tee -a "$RUN/prepare.txt"
  # The request is test scaffolding (fixed text, so the results can be checked): watch sends it.
  cat > "$RUN/request.txt" <<EOF
Delegate one task to a worker with the org-delegate skill: project $project, task id $T, title "paddock prototype 3", base $base. The task text: "Add an acceptance test, then the file it checks. (1) Add $TESTF, a bash script that exits 0 only when the file $FILE at the repository root holds exactly the one line 'paddock prototype 3, task $T', and exits 1 otherwise. Commit it alone, as the first commit of your branch, with the line 'Acceptance-Test: $TESTF' in the last paragraph of the commit message (no blank line inside that paragraph). Check that git log -1 --format='%(trailers)' shows the line and that bash $TESTF fails. (2) Before you create $FILE, report blocked with the question 'May I add $FILE at the repository root?' and wait for the answer as your instructions say. On no, report done without the file. (3) On yes, add $FILE with that one line, commit it as a second commit, and check that bash $TESTF passes. Commit only these two files. Never change the test after its commit; if a review finding is about the test, leave it and say so in your report. (4) Ask for the review by the second model as your rules say, and fix Blocker and Major findings in new commits. (5) Report done with both commit SHAs, the test result and the last line of the review gate." When the worker asks its question, do not answer it yourself: put it on the card with org-escalation ask --answer-in secretary, and when the ANSWER from the card is in your mailbox, forward it with org-escalation answer. When the worker reports done, open the pull request with the org-pull-request skill, --mode human --base $base --task-id $T, title "paddock prototype 3 run $T", and tell me its URL and the skill's exit code. Do not merge. This is a test run; the pull request goes to the throwaway repository $repo.
EOF
  tee "$RUN/steps.txt" <<EOF

== Run $T prepared ($RUN). Do these in order:

1. In this terminal in herdr: start the organization. org-start places the
   templates, the bin files, the cockpit mod and the layout itself.
     bash skills/org-start/scripts/org-start.sh            # expect: "org-start: ready", exit 0
     "$HERDR_APP" do layout.switch '{"name":"paddock"}'
   Then look at the window: the secretary is in the centre. Record it:
     sh $HERE/prototype-3.sh note --task-id $T "layout open, secretary in the centre"
2. Start the watcher and keep it running (another terminal in herdr is fine; an agent may run it). It sends
   the request itself to the secretary (hc send), once the secretary reports a status, and notes
   that it did; nobody types it. The request is saved in $RUN/request.txt:
     sh $HERE/prototype-3.sh watch --task-id $T
3. When watch prints "NOW: click Yes", click Yes on the card. Answer nothing else in any terminal;
   if you have to, do it, and record it: note --task-id $T --touch "<what and why>".
4. When watch ends: collect, then cleanup (both with --task-id $T).
EOF
  exit 0
fi

# ---- the history (decision 0005): one file per writer, the writer is the file name (Issue #160).
# lines: "<writer><TAB><json line>" of the secretary, the person, the worker and codex-gate, all
# months, only lines since the run started.
lines() {
  for id in secretary person "$W" codex-gate; do
    for f in "$STATE"/events/*/"$id".jsonl; do
      [ -f "$f" ] && sed "s/^/$id$TAB/" "$f"
    done
  done | awk -v s="$START" 'match($0, /"ts":"[^"]*"/) { if (substr($0, RSTART + 6, RLENGTH - 7) >= s) print }'
}
of() { lines | awk -F"$TAB" -v w="$1" '$1 == w' | cut -f2-; } # of <writer>: that writer's lines
has() { of "$1" | grep -Eq "$2"; }                              # has <writer> <ERE>
first_of() { of "$1" | grep -E "$2" | head -n 1; }
seq_of() { first_of "$1" "$2" | sed -n 's/^{"seq":\([0-9]*\),.*/\1/p'; }
# acked <sender> <seq>: the secretary's ack line says it read <sender> up to at least <seq>.
acked() {
  [ -n "$2" ] || return 1
  of secretary | grep -E '"kind":"ack"' | sed -n 's/.*"text":"\([^"]*\)".*/\1/p' \
    | awk -v w="$1" -v s="$2" '$1 == w && $2 + 0 >= s + 0 { f = 1 } END { exit !f }'
}
# the branch's own commits, oldest first (what the acceptance job reads)
own_commits() { git -C "$PROJECT" rev-list --reverse --first-parent "$BR" --not "origin/$BASE" 2>/dev/null; }

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
  td=${PADDOCK_CORE_TEMPLATES_DIR:-${APPDATA:-${XDG_CONFIG_HOME:-$HOME/.config}}/herdr-core/templates}
  bd=${PADDOCK_BIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/paddock/bin}
  t=0; prev_s=; prev_w=; prev_os=; AID=$(cat "$RUN/approval.id" 2>/dev/null)
  while [ "$t" -lt "$timeout" ]; do
    # status of the two terminals, logged on change
    s=$(state_of secretary); w=$(state_of "$W")
    sb=0; wb=0; [ "$s" = blocked ] && [ "$prev_s" != blocked ] && sb=1; [ "$w" = blocked ] && [ "$prev_w" != blocked ] && wb=1
    [ "$s" = "$prev_s" ] || { log "secretary ${s:-none}"; prev_s=$s; }
    [ "$w" = "$prev_w" ] || { log "$W ${w:-none} $(hcj "$W" | grep -Eo '"status": *\{.*' | cut -c1-300)"; prev_w=$w; }
    os=$(orgstate)
    [ "$os" = "$prev_os" ] || { log "org-state $os"; printf '%s\t%s\n' "$(now)" "$os" >> "$RUN/org-state.log"; prev_os=$os; }

    # 1. the secretary from the template; org-start placed today's files
    if [ -n "$s" ] && [ ! -f "$RUN/secretary.created" ]; then
      hcj secretary | field created_ms > "$RUN/secretary.created"
      res 1-secretary PASS "status $s"
      bad=
      for m in "templates/secretary.md $td/secretary.md" "templates/worker.md $td/worker.md" \
        "scripts/org $bd/org" "scripts/second-model-review.sh $bd/second-model-review.sh" \
        "scripts/hooks/premise-reminder.sh $bd/premise-reminder.sh" "templates/secretary-settings.json $bd/secretary-settings.json" \
        "templates/worker-rules.md $bd/worker-rules.md" "templates/worker-settings.json $bd/worker-settings.json"; do
        src=${m%% *}; dst=${m#* }
        if cmp -s "$ROOT/$src" "$dst"; then echo "$dst $(cksum < "$dst")" >> "$RUN/placed-files.txt"; else bad="$bad $dst"; fi
      done
      [ -z "$bad" ] && res 1-placed-files PASS "8 files equal this checkout" || res 1-placed-files FAIL "missing or not this checkout's:$bad"
    fi
    # 2. the request: sent by the runbook once the secretary reports a status that is not a prompt; once per run.
    # It is test scaffolding, not what a person would write; recorded as a note ("sent"), not a touch.
    if [ -n "$s" ] && [ "$s" != blocked ] && [ ! -f "$RUN/request.sent" ]; then
      if hc send secretary "$(cat "$RUN/request.txt")" >/dev/null 2>&1; then
        : > "$RUN/request.sent"
        printf '%s\tsent\t%s\n' "$(now)" "the runbook sent the request to the secretary with hc send (status $s)" >> "$RUN/notes.tsv"
        res 2-request PASS "sent with hc send to the secretary (status $s); the person types nothing"
      else once sendfail "NOW: hc send to the secretary failed; will retry. If it keeps failing, send $RUN/request.txt by hand and record it: note --task-id $T --touch \"sent the request by hand\""; fi
    fi
    # 3. worktree, its settings.local.json, and the task's own settings file (Issues #160, #177)
    if [ -d "$WT" ] && git -C "$PROJECT" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $WT"; then
      [ -f "$WT/.claude/settings.local.json" ] && [ "$(git -C "$WT" symbolic-ref --short HEAD 2>/dev/null)" = "$BR" ] && res 3-worktree PASS "$WT on $BR, settings.local.json written"
      ws=$STATE/settings/$T.json
      if [ -f "$ws" ] && [ ! -f "$RUN/res.3-own-settings" ]; then
        if grep -q "/$W.jsonl" "$ws" && grep -Eq '"excludedCommands": \[[^]]*second-model-review\.sh' "$ws"; then
          command cp -f "$ws" "$RUN/task-settings.json"; res 3-own-settings PASS "$ws names $W's own files and the gate's calls"
        else res 3-own-settings FAIL "$ws lacks $W's own files or the gate in excludedCommands"; fi
      fi
    fi
    # 4. worker started, labelled; its own start report shows the template command ran ($PADDOCK_ORG)
    if [ -n "$w" ] && [ ! -f "$RUN/worker.created" ]; then
      hcj "$W" | field created_ms > "$RUN/worker.created"
      hcj "$W" | grep -Eq "\"task_id\": *\"$T\"" && res 4-worker PASS "$W, label task_id=$T" || res 4-worker FAIL "$W has no label task_id=$T"
    fi
    has "$W" '"kind":"run_started"' && res 4-worker-report PASS "$W wrote run_started in its own file"
    has secretary "\"kind\":\"work_added\",\"to\":\"[^\"]*\",\"task_id\":\"$T\"" && res 4-work-entry PASS "work_added for $T in the secretary's history"
    # 5. the question on the card (the approval_asked line carries the approval id)
    has "$W" '"kind":"run_blocked"' && res 5-blocked PASS "$W reported blocked"
    if [ -z "$AID" ]; then
      AID=$(first_of secretary "\"kind\":\"approval_asked\",\"to\":\"[^\"]*\",\"task_id\":\"$T\"" | grep -Eo "$T-[0-9]{8}T[0-9]{6}Z" | head -n 1)
      [ -n "$AID" ] || AID=$(printf '%s' "$os" | grep -Eo "\"id\": *\"$T-[0-9TZ]*\"" | head -n 1 | sed 's/.*: *"//; s/"$//')
      [ -n "$AID" ] && { echo "$AID" > "$RUN/approval.id"; res 5-approval PASS "approval $AID asked"
        once click "NOW: click Yes on the card ($AID). Then record what the card showed: note --task-id $T \"card showed ...\""; }
    fi
    # 6. answered on the card; 7. the answer reaches the worker
    if [ -n "$AID" ]; then
      aq="\"kind\":\"message\",\"to\":\"secretary\".*\"text\":\"ANSWER $AID "
      if has person "$aq"; then
        res 6-card-answer PASS "ANSWER $AID in the person's file"
        if acked person "$(seq_of person "$aq")"; then res 7-secretary-read PASS "the secretary read the ANSWER"
        elif [ "$s" = done ] || [ "$s" = idle ]; then
          once idle140 "NOW: the secretary is $s with the card's ANSWER unread. It should be waiting in 'org wait' (Issue #140); this is a finding. Give it 90 s; if it does not move, type 'check your mailbox' into its conversation and record: note --task-id $T --touch \"nudged the secretary, #140\""
        fi
        has secretary "\"to\":\"$W\".*Answer to your question \\($AID\\)" && res 7-forwarded PASS "answer sent to $W"
        has secretary "\"kind\":\"approval_removed\".*\"text\":\"$AID\"" && res 7-approval-removed PASS "approval_removed $AID in the secretary's history"
      fi
    fi
    # blocked status is Claude Code's own prompt or dialog: the worker waits for its answer in 'org wait',
    # in its turn (working). A prompt is answered in that terminal (Issue #127), so each one is a finding.
    if [ $wb -eq 1 ]; then
      echo "NOW: $W is blocked on a prompt or dialog in its own terminal. A folder-trust dialog: do NOT answer it; note --task-id $T --touch \"trust dialog in $W\" and end the run (host rule). Any other prompt (Issue #127): if the card shows it, its button opens that terminal. Answer it there, then: note --task-id $T --touch \"answered $W's prompt: <what it asked>\""
      log "finding: $W blocked on its own prompt"
    fi
    if [ $sb -eq 1 ]; then
      echo "NOW: the secretary is blocked on a prompt in its pane. A folder-trust dialog: do NOT answer it; note it with --touch and end the run (host rule). Any other prompt: answer it there, then: note --task-id $T --touch \"answered the secretary's prompt: <what it asked>\""
      log "finding: secretary blocked on its own prompt"
    fi
    # 8. the test commit, the review, done, read by the secretary
    dq='"kind":"run_completed"'
    if has "$W" "$dq"; then
      first=$(own_commits | head -n 1)
      if [ -n "$first" ] && git -C "$PROJECT" log -1 --format='%(trailers:key=Acceptance-Test,valueonly)' "$first" | grep -qxF "$TESTF" \
        && [ "$(git -C "$PROJECT" diff --name-only "$first^" "$first")" = "$TESTF" ]; then
        res 8-test-commit PASS "first own commit $first declares $TESTF and changes only it"
      else res 8-test-commit FAIL "first own commit ${first:-none} does not declare $TESTF alone (Acceptance-Test trailer)"; fi
      git -C "$PROJECT" log --format=%H -n 1 "$BR" -- "$FILE" 2>/dev/null | grep -q . \
        && res 8-done PASS "$W reported done; $BR has the commit with $FILE" || res 8-done FAIL "$W reported done; no commit with $FILE on $BR"
      # the gate's own record of the task's last diff round (Issue #253), not the worker's done text:
      # the task's last diff line from codex-gate, so a later round with no result is not covered by an older pass
      r=$(of codex-gate | grep -E "\"kind\":\"codex_round_(started|passed|failed)\",\"to\":\"[^\"]*\",\"task_id\":\"$T\",\"text\":\"diff round" | tail -n 1 \
        | sed -n 's/.*"kind":"\(codex_round_[a-z]*\)".*"text":"\([^"]*\)".*/\1: \2/p')
      case "$r" in
        codex_round_passed:*) res 8-review PASS "codex-gate recorded $r" ;;
        '') res 8-review FAIL "no diff round from codex-gate for $T (did the worker run the gate?)" ;;
        codex_round_started:*) res 8-review FAIL "the last round has no result: $r" ;;
        *) res 8-review FAIL "codex-gate recorded $r" ;;
      esac
      acked "$W" "$(seq_of "$W" "$dq")" && res 8-secretary-read PASS "the secretary read the completion"
    fi
    # 9. the pull request (gh read-only), the CI record, the acceptance job
    if [ ! -f "$RUN/pr.number" ] && [ -f "$RUN/res.8-done" ]; then
      n=$(gh pr list --repo "$REPO" --head "$BR" --state all --json number --jq '.[0].number' 2>/dev/null)
      [ -n "$n" ] && { echo "$n" > "$RUN/pr.number"; res 9-pull-request PASS "PR #$n on $BR"; }
    fi
    if [ -f "$RUN/pr.number" ]; then
      ci=$(first_of secretary "\"kind\":\"ci_completed\".*\"task_id\":\"$T\"")
      if [ -n "$ci" ]; then
        code=$(printf '%s' "$ci" | sed -n 's/.*"exit_code":\([0-9]*\).*/\1/p'); run=$(printf '%s' "$ci" | sed -n 's/.*"run_id":\([0-9]*\).*/\1/p')
        [ "$code" = 0 ] && res 9-ci-record PASS "ci_completed for $T, run $run, exit 0" || res 9-ci-record FAIL "ci_completed for $T, run $run, exit $code"
        if [ ! -f "$RUN/res.9-acceptance" ] && gh run view "$run" --repo "$REPO" --log > "$RUN/ci-run.log" 2>/dev/null; then
          if grep -q 'ACCEPTANCE: pass' "$RUN/ci-run.log"; then res 9-acceptance PASS "run $run: ACCEPTANCE: pass"
          else res 9-acceptance FAIL "run $run: $(grep -o 'ACCEPTANCE: [a-z]*' "$RUN/ci-run.log" | tail -n 1)"; fi
        fi
        [ -f "$RUN/res.9-acceptance" ] && break
      fi
      [ -f "$RUN/pr.seen" ] || date +%s > "$RUN/pr.seen"
      [ $(( $(date +%s) - $(cat "$RUN/pr.seen") )) -gt 900 ] && break # no CI record 15 min after the PR
    fi
    t=$((t + 5)); sleep 5
  done
  # The summary is recomputed on every run of watch: only PASS and FAIL of a step are kept.
  {
  echo "== summary of run $T"
  rc=0
  for st in 1-secretary 1-placed-files 2-request 3-worktree 3-own-settings 4-worker 4-worker-report 4-work-entry 5-blocked 5-approval \
    6-card-answer 7-secretary-read 7-forwarded 7-approval-removed 8-test-commit 8-review 8-done 8-secretary-read \
    9-pull-request 9-ci-record 9-acceptance; do
    if [ -f "$RUN/res.$st" ]; then cat "$RUN/res.$st"; grep -q ': PASS' "$RUN/res.$st" || rc=1
    else echo "RESULT $st: NO DATA (not seen while watch ran, or not reached)"; rc=1; fi
  done
  touches=$(grep -c "${TAB}touch${TAB}" "$RUN/notes.tsv" 2>/dev/null); found=$(grep -c "finding:" "$RUN/watch.log" 2>/dev/null)
  if [ "${touches:-0}" -eq 0 ] && [ "${found:-0}" -eq 0 ]; then echo "RESULT 10-no-touch: PASS (no touch noted, no prompt seen)"
  else echo "RESULT 10-no-touch: FAIL (${touches:-0} touch notes, ${found:-0} prompts in the status log; see notes.tsv, watch.log)"; rc=1; fi
  echo "== watch ended; next: collect --task-id $T"
  echo $rc > "$RUN/watch.rc"
  } | tee "$RUN/watch-summary.txt"
  exit "$(cat "$RUN/watch.rc")"
fi

if [ "$phase" = collect ]; then
  E="$RUN/evidence"; mkdir -p "$E" || die 6 "cannot create $E"
  { echo "== versions"; hc --version 2>&1; "$HERDR_APP" --version 2>&1; claude --version 2>&1; codex --version 2>&1; gh --version 2>&1 | head -n 1
    echo "== paddock main at the run: $PADDOCK_HEAD"
    echo "== results (prepare, then each step watch recorded: kept even when watch was stopped)"; cat "$RUN/prepare.txt" "$RUN"/res.* 2>/dev/null
    echo "== the last watch summary (none when watch was stopped)"; cat "$RUN/watch-summary.txt" 2>/dev/null
    echo "== notes"; cat "$RUN/notes.tsv" 2>/dev/null
    echo "== hc ls"; hc ls 2>&1
    echo "== hc get secretary"; hcj secretary; echo
    echo "== hc get $W"; hcj "$W"; echo
    echo "== list_runs"; bash "$ORG" --as secretary list_runs 2>&1
    echo "== history lines since $START (writer, line: secretary, person, $W, codex-gate)"; lines
    echo "== org-state now"; orgstate; echo
    echo "== org-state changes"; cat "$RUN/org-state.log" 2>/dev/null
    echo "== status log"; cat "$RUN/watch.log" 2>/dev/null
    echo "== placed files (path, cksum)"; cat "$RUN/placed-files.txt" 2>/dev/null
    echo "== the task's settings file, as watch saw it"; cat "$RUN/task-settings.json" 2>/dev/null
    echo "== $BR (own commits, with trailers)"; for c in $(own_commits); do git -C "$PROJECT" log -1 --format='%h %s%n%(trailers)' "$c"; git -C "$PROJECT" diff --name-only "$c^" "$c" | sed 's/^/   /'; done
    echo "== pull request"; [ -f "$RUN/pr.number" ] && { gh pr view "$(cat "$RUN/pr.number")" --repo "$REPO" --json number,url,state,headRefName,baseRefName,createdAt 2>&1; gh pr checks "$(cat "$RUN/pr.number")" --repo "$REPO" 2>&1; }
    echo "== acceptance job log (acceptance-check lines)"; grep -E 'acceptance-check:|ACCEPTANCE:' "$RUN/ci-run.log" 2>/dev/null | cut -f3-
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
echo "kept: $STATE/settings/$T.json (the task's settings file) and the codex-gate round count for $T"
[ -f "$RUN/pr.number" ] && echo "To close the pull request and delete the remote branch (a person decides): gh pr close $(cat "$RUN/pr.number") --repo $REPO --delete-branch"
echo "evidence kept in $RUN"
