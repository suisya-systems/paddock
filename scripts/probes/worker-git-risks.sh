#!/bin/sh
# Probes for Issue #277, option D (local mirror): the four "Remaining probes" of docs/design/worker-github-access.md
# section D (from the known-risks survey). One script, four subcommands; each needs no GitHub access and no credential.
#
#   sh scripts/probes/worker-git-risks.sh mounts     # 1: what the worker sandbox mounts read-only or masks in the shared .git
#   sh scripts/probes/worker-git-risks.sh delegate   # 2: org-delegate while a worker is live, and with a stranded config.lock
#   sh scripts/probes/worker-git-risks.sh race       # 3: the launch race (#79248): about 30 worker commands against git churn
#   sh scripts/probes/worker-git-risks.sh shapes     # 4: other clone shapes: hooks symlink, worktreeConfig + sparse, tracked .gitmodules
#
# Run on the host, from the repo root, in a core terminal (HC_TERMINAL_SOCKET set), after
# `bash skills/org-start/scripts/org-start.sh` from THIS checkout (worker rules and the `worker` template placed).
# Needs: hc, git, claude, POSIX sh; the workers folder (PADDOCK_WORKERS_DIR, default ~/paddock-workers)
# already trusted by Claude Code. Each subcommand takes 3-12 minutes (PADDOCK_PROBE_WAIT, default 240 s, per wait).
# Claude Code asks the folder-trust question again for every new worktree; the probe passes it the way production does
# (org-delegate for `delegate`; hc run + org-escalation prompt --then-send for the others, as worker-mirror.sh does). It
# never answers a dialog itself. If one stays on screen it prints NEEDS-PERSON, keeps what it made and stops.
#
# What it touches (all of it is made by this run and removed by its exit trap, except where noted):
#   all four : one temp folder $workers/.probe277d.XXXXXX holding bare "upstream" repositories and throw-away clones that
#              play the secretary's project clone (NOT $TMPDIR: the worker sandbox may write there, which would hide a
#              read-only shared .git); worktrees $workers/p7d-<pid>-<time>[-x] and branches in those clones; terminals
#              w-p7d-<pid>-<time>[-x] (hc kill + hc rm); the host's ~/.local/bin/claude link is restored if claude moved it.
#   mounts, race, shapes : also one temporary template p277d-worker in the core's templates folder (removed), made from
#              templates/worker.md with the read-only token check and GH_TOKEN cut out and --settings pointing at a copy of
#              templates/worker-settings.json whose allowWrite holds only the probe's result folder (as worker-mirror.sh).
#   delegate : runs skills/org-delegate/scripts/org-delegate.sh itself with the real `worker` template and the real token
#              file (it must exist), as org-script-reach.sh does. So it also writes, in the real state folder
#              (${PADDOCK_STATE_DIR:-~/.local/state/paddock}): a start record per task p7d-<pid>-<time>-<x> in the mailbox,
#              the worker's own files, and settings/<task>.json (the last is removed on exit; the records stay and are
#              harmless: those tasks are not in org-state). No --title is passed, so org-state is not touched.
# Never written: ~/.claude.json, any real project's .git, the real project registry. Stranded locks are made only inside
# the throw-away clone. The probe reads (never writes) ~/.claude/projects/*p7d*/ transcripts of its own workers (race, shapes).
#
# Reading the output. "RESULT <name>: <PASS|FAIL|INCONCLUSIVE|NO DATA|DATA> (detail)". DATA means a measurement with no
# pass line (mounts, delegate): paste the lines back. Everything printed is paths, modes, exit codes and error text; no credential.
set -u
usage() { echo "usage: sh scripts/probes/worker-git-risks.sh mounts|delegate|race|shapes   (run from the repo root; see the comment at the top)"; }
SUB=${1:-}
ROOT=$(pwd)

# ---- w.sh: what a worker runs (written to the result folder). Prints facts only.
emit_w() { cat <<'W'
d=$(dirname "$0"); ph=$1
t() { n=$1; shift; "$@" >"$d/t.out" 2>"$d/t.err"; r=$?; echo "$n rc=$r $(head -n 1 "$d/t.err" | tr -d '\r' | cut -c1-120)"; }
case $ph in
mounts)
  gd=$(cd "$(git rev-parse --git-dir)" && pwd); cm=$(cd "$(git rev-parse --git-common-dir)" && pwd)
  {
  echo "gitdir $gd"; echo "commondir $cm"; echo "cwd $PWD"
  for p in config config.lock config.worktree hooks packed-refs HEAD; do echo "stat-common $p: $(stat -c '%F mode=%a uid=%u size=%s' "$cm/$p" 2>&1 | head -n 1)"; done
  for p in config.worktree index HEAD; do echo "stat-gitdir $p: $(stat -c '%F mode=%a uid=%u size=%s' "$gd/$p" 2>&1 | head -n 1)"; done
  echo "stat-root .gitmodules: $(stat -c '%F %t:%T mode=%a size=%s' .gitmodules 2>&1 | head -n 1)"
  t read-gitmodules cat .gitmodules | sed 's/^/test /'
  t write-config sh -c ": >> '$cm/config'" | sed 's/^/test /'
  had=; [ -e "$cm/config.lock" ] && had=1
  t create-config.lock sh -c ": > '$cm/config.lock'" | sed 's/^/test /'
  [ -n "$had" ] || { [ ! -e "$cm/config.lock" ] || t remove-config.lock rm -f "$cm/config.lock" | sed 's/^/test /'; }
  t read-config.worktree cat "$cm/config.worktree" | sed 's/^/test /'
  t create-in-hooks sh -c ": > '$cm/hooks/p277-probe'" | sed 's/^/test /'; rm -f "$cm/hooks/p277-probe" 2>/dev/null
  t create-in-objects sh -c ": > '$cm/objects/p277-probe'" | sed 's/^/test /'; rm -f "$cm/objects/p277-probe" 2>/dev/null
  t create-in-refs sh -c ": > '$cm/refs/p277-probe'" | sed 's/^/test /'; rm -f "$cm/refs/p277-probe" 2>/dev/null
  t create-in-gitdir sh -c ": > '$gd/p277-probe'" | sed 's/^/test /'; rm -f "$gd/p277-probe" 2>/dev/null
  t git-config-write git config p277.probe 1 | sed 's/^/test /'; git config --unset p277.probe >/dev/null 2>&1
  t git-status git status --porcelain | sed 's/^/test /'
  echo "== mountinfo (root mountpoint options fstype), filtered to .git / .claude / .gitmodules / probe folders / /dev/null"
  awk '{ i = 1; while (i <= NF && $i != "-") i++; print $4, $5, $6, $(i + 1) }' /proc/self/mountinfo | grep -E '\.git|\.claude|\.gitmodules|probe277d|p277d|/dev/null' | sed 's/^/m /'
  echo "mountinfo-total $(wc -l < /proc/self/mountinfo)"
  } > "$d/mounts.txt" 2>&1
  sleep 8   # the host reads .git/config.lock while this command is still running
  echo done > "$d/mounts.rc" ;;
n)
  { echo "n=$2"; date +%s; git status --porcelain | wc -l; } > "$d/n$2.txt" 2>&1 ;;
shape)
  {
  t status git status --porcelain
  t log git log --oneline -3
  t diff git diff --stat
  echo shape >> base.txt; t add-u git add -u
  echo n > sub/new.txt; t add-new git add sub/new.txt   # inside the sparse selection of the sparse shape
  t commit git -c user.name=p277 -c user.email=p277@example.invalid commit -q -m "p277 shape commit"
  echo "head $(git log -1 --format=%s 2>&1 | head -n 1)"
  } > "$d/shape.txt" 2>&1
  echo done > "$d/shape.rc" ;;
esac
W
}
case $SUB in
  mounts|delegate|race|shapes) ;;
  --print-w) emit_w; exit 0 ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 1 ;;
esac

[ -f "$ROOT/templates/worker.md" ] || { echo "RESULT precondition-failed: run from the repo root"; exit 1; }
for c in git hc claude; do command -v $c >/dev/null 2>&1 || { echo "RESULT precondition-failed: $c not on PATH"; exit 1; }; done
ID=p7d-$$-$(date +%s | tail -c 6);  # short: a terminal name (w-<id>-<suffix>) is at most 32 characters
 TPL=p277d-worker
WAIT=${PADDOCK_PROBE_WAIT:-240}
cfg=${APPDATA:-${XDG_CONFIG_HOME:-$HOME/.config}}
TPL_DIR=${PADDOCK_CORE_TEMPLATES_DIR:-$cfg/herdr-core/templates}
bd=${PADDOCK_BIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/paddock/bin}
state=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}
workers=${PADDOCK_WORKERS_DIR:-$HOME/paddock-workers}
ESC=$ROOT/skills/org-escalation/scripts/org-escalation.sh
mkdir -p "$workers" || exit 1
WORK=$(mktemp -d "$workers/.probe277d.XXXXXX") || exit 1
case "$WORK$bd" in *[[:space:]]*) echo "RESULT precondition-failed: paths must not contain whitespace ($WORK $bd)"; exit 1 ;; esac
OUT=$WORK/out; mkdir -p "$OUT" || exit 1
KEEP= TERMS= OWNTPL= CHURN=
SA=hold-a SD=hold-d   # delegate probe: worker A and D each run `until [ -f $OUT/hold-x.release ]` (a bare `sleep N` is blocked by the harness)
. "$(dirname "$0")/claude-link.sh"
claude_link_save
cleanup() {
  claude_link_restore
  [ -z "$CHURN" ] || kill "$CHURN" 2>/dev/null   # the race probe's background churn loop, also when the run is kept for a person
  if [ -n "$KEEP" ]; then echo "kept for a person: terminals$TERMS, temp folder $WORK, worktrees $workers/$ID*, template $TPL_DIR/$TPL.md"; return; fi
  for n in $TERMS; do hc kill "$n" >/dev/null 2>&1; hc rm "$n" >/dev/null 2>&1; done
  : > "$OUT/$SA.release"; : > "$OUT/$SD.release"   # ends the hold loops of this probe's own delegate workers (they poll every 2 s)
  [ -z "$OWNTPL" ] || rm -f "$TPL_DIR/$TPL.md"
  # the worktrees are linked to clones inside $WORK, so removing both leaves nothing behind in any real repository
  for w in "$workers/$ID"*; do [ -e "$w" ] && rm -rf "$w"; done
  rm -f "$state/settings/$ID"*.json 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT; trap 'exit 130' INT TERM
export GIT_AUTHOR_NAME=p277 GIT_AUTHOR_EMAIL=p277@example.invalid GIT_COMMITTER_NAME=p277 GIT_COMMITTER_EMAIL=p277@example.invalid
echo "== versions"; git --version; hc --version 2>&1; claude --version 2>&1
echo "== subcommand $SUB, id $ID"

# build DIR: DIR/up.git (GitHub's stand-in), DIR/seed, DIR/proj (the secretary's project clone, branch main with origin).
build() {
  mkdir -p "$1" &&
  git -c init.defaultBranch=main init -q --bare "$1/up.git" &&
  git clone -q "$1/up.git" "$1/seed" 2>/dev/null &&
  git -C "$1/seed" checkout -q -b main &&
  mkdir -p "$1/seed/sub" && echo base > "$1/seed/base.txt" && echo f > "$1/seed/sub/f.txt" &&
  git -C "$1/seed" add base.txt sub/f.txt && git -C "$1/seed" commit -q -m c1 || return 1
}
publish() { git -C "$1/seed" push -q origin main && git clone -q "$1/up.git" "$1/proj"; }
mkwt() { git -C "$1" worktree add -q -b "work/$3" "$2" origin/main; } # project worktree branch-id

dialog_on() { case "$(hc read "$1" 2>/dev/null)" in *"Quick safety check"*|*"trust this folder"*) return 0 ;; esac; return 1; }
need_person() { echo "NEEDS-PERSON: a dialog is still on screen in $1 after the production path; answer it in the terminal and rerun"; KEEP=1; exit 1; }
# waitfor NAME FILE SECS: 0 when FILE appears in $OUT; stops on a dialog nobody answered.
waitfor() { t=0; while [ "$t" -lt "$3" ]; do [ -f "$OUT/$2" ] && return 0; dialog_on "$1" && need_person "$1"; t=$((t + 3)); sleep 3; done; return 1; }
hostlock() { f=$1/config.lock; if [ -e "$f" ] || [ -L "$f" ]; then echo "present size=$(stat -c %s "$f" 2>/dev/null) mode=$(stat -c %a "$f" 2>/dev/null) mtime=$(stat -c %y "$f" 2>/dev/null | cut -c1-19)"; else echo "absent"; fi; }
# transcripts of this probe's workers (read only): exact tool-result text, no model in the loop
transcripts() { ls "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*"$1"*/*.jsonl 2>/dev/null; }

# ---- the custom template (mounts, race, shapes): production command, credential-free, settings at the probe's copy
mk_template() {
  [ ! -e "$TPL_DIR/$TPL.md" ] || { echo "RESULT precondition-failed: $TPL_DIR/$TPL.md exists; remove it"; exit 1; }
  CMD=$(sed -n 's/^command: //p' "$ROOT/templates/worker.md")
  SETTINGS=$WORK/worker-settings.json
  CMD=$(printf '%s' "$CMD" | sed -e 's/tok=.*exit 1; }; //' -e 's/ GH_TOKEN="\$tok"//' -e "s|--settings \"\\\$ws\"|--settings $SETTINGS|" \
    -e 's/^env -u /env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN -u /')
  case "$CMD" in *'GH_TOKEN="'*|*'$tok'*|*'--settings "$ws"'*) echo "RESULT precondition-failed: could not derive the credential-free command from templates/worker.md (it changed?)"; exit 1 ;; esac
  case "$CMD" in *"exec env GH_CONFIG_DIR="*"--settings $SETTINGS'") ;; *) echo "RESULT precondition-failed: derived command lacks the expected GH_CONFIG_DIR / --settings parts"; exit 1 ;; esac
  [ -f "$bd/worker-rules.md" ] || { echo "RESULT precondition-failed: $bd/worker-rules.md missing (run org-start from this checkout first)"; exit 1; }
  [ "$(grep -c '"allowWrite": \[\]' "$ROOT/templates/worker-settings.json")" = 1 ] || { echo "RESULT precondition-failed: templates/worker-settings.json has no single empty allowWrite"; exit 1; }
  sed "s|\"allowWrite\": \[\]|\"allowWrite\": [\"$OUT\"]|" "$ROOT/templates/worker-settings.json" > "$SETTINGS"
  printf -- '---\ndescription: probe 277d (temporary)\ncommand: %s\n---\nProbe 277. Follow only the message below.\n' "$CMD" > "$TPL_DIR/$TPL.md" || exit 1
  OWNTPL=1
  if [ -n "${PADDOCK_CORE_SOCKET_DIR:-}" ]; then SOCKDIR=$PADDOCK_CORE_SOCKET_DIR; elif [ -n "${HC_TERMINAL_SOCKET:-}" ]; then SOCKDIR=$(dirname "$HC_TERMINAL_SOCKET"); else echo "RESULT precondition-failed: run from a core terminal (HC_TERMINAL_SOCKET) or set PADDOCK_CORE_SOCKET_DIR"; exit 1; fi
  emit_w > "$OUT/w.sh"
}
# launch NAME WORKTREE TASKID TASK: the per-task deny of the socket folder (as org-delegate), then hc run, then org-escalation on a dialog.
launch() {
  mkdir -p "$2/.claude" && printf '{"sandbox":{"filesystem":{"denyRead":["%s"],"denyWrite":["%s"]}}}\n' "$SOCKDIR" "$SOCKDIR" > "$2/.claude/settings.local.json" \
    && printf 'settings.local.json\n.gitignore\n' > "$2/.claude/.gitignore" || { echo "RESULT precondition-failed: cannot write $2/.claude"; exit 1; }
  TERMS="$TERMS $1"
  out=$(hc run --bg --outlive-parent --name "$1" --cwd "$2" --label "task_id=$3" $TPL "$4" 2>&1) || { echo "RESULT launch: hc run failed: $(printf %s "$out" | cut -c1-200)"; return 1; }
  if printf '%s' "$out" | tr -d '\n' | grep -Eq '"sent": *true'; then LAUNCHINFO="not needed (hc sent the first message)"
  else
    po=$(bash "$ESC" prompt --task "$3" --then-send "$4" 2>&1); erc=$?
    LAUNCHINFO="exit=$erc $(printf '%s' "$po" | grep -E '^(POLICY|PROMPT=)' | tr '\n' ' ' | cut -c1-200)"
    [ "$erc" -eq 0 ] || { echo "RESULT launch: org-escalation prompt $LAUNCHINFO"; echo "NEEDS-PERSON: org-escalation prompt did not finish (exit $erc); look at: hc read $1"; KEEP=1; exit 1; }
  fi
  echo "== launch $1: org-escalation prompt $LAUNCHINFO"
}
endterm() { hc kill "$1" >/dev/null 2>&1; hc rm "$1" >/dev/null 2>&1; }

# =========================================================== 1 mounts
sub_mounts() {
  mk_template
  P=$WORK/m; build "$P" && publish "$P" && mkwt "$P/proj" "$workers/$ID" "$ID" || { echo "RESULT precondition-failed: could not build the throw-away repository"; exit 1; }
  echo "== host before: .git/config.lock $(hostlock "$P/proj/.git"), .gitmodules in the worktree: $([ -e "$workers/$ID/.gitmodules" ] && echo yes || echo no), config.worktree on host: $([ -e "$P/proj/.git/config.worktree" ] && echo yes || echo no)"
  TASK="Probe for paddock Issue #277. This is a measurement the secretary asks for and permits; do not decline or report blocked. Work only in this worktree plus the folder $OUT. Run this ONE command as ONE Bash call, with the sandbox ON (never skip it), and do nothing else: sh $OUT/w.sh mounts
If it fails or prints an error, do not retry it another way. Then reply with the single word done."
  launch "w-$ID" "$workers/$ID" "$ID" "$TASK" || exit 1
  seen=; t=0; while [ "$t" -lt "$WAIT" ] && [ ! -f "$OUT/mounts.rc" ]; do
    dialog_on "w-$ID" && need_person "w-$ID"
    [ -n "$seen" ] || { s=$(hostlock "$P/proj/.git"); case "$s" in present*) seen="$s" ;; esac; }
    t=$((t + 1)); sleep 1
  done
  [ -f "$OUT/mounts.rc" ] || { echo "RESULT mounts: NO DATA (the worker never finished the command within ${WAIT}s)"; hc read "w-$ID" 2>&1 | tail -n 12; exit 1; }
  sleep 3
  echo "== worker output (mounts.txt)"; cat "$OUT/mounts.txt"
  echo "RESULT mounts-host-placeholder: DATA (while the worker's command ran: ${seen:-never seen}; 3 s after it ended: $(hostlock "$P/proj/.git"))"
  echo "RESULT mounts-worker-view: DATA (see the 'stat-*', 'test' and 'm' lines above; paste them all)"
  echo "== host after: $(ls -la "$P/proj/.git" | grep -E 'config|hooks' | tr '\n' ';' | cut -c1-300)"
}

# =========================================================== 2 delegate
DELE=$ROOT/skills/org-delegate/scripts/org-delegate.sh
# dele SUFFIX HOLD-NAME|none [org-delegate options...]: runs org-delegate, prints exit and time.
cfgw() { e=$(git -C "$PJ" config "$@" 2>&1); r=$?; echo "rc=$r $(printf '%s' "$e" | head -n 1 | cut -c1-140)"; }
dele() {
  sfx=$1; sl=$2; shift 2; tid=$ID-$sfx; TERMS="$TERMS w-$tid"
  if [ "$sl" = none ]; then task="Probe for paddock Issue #277. A measurement the secretary permits. Run no command at all and change nothing; reply with the single word done."
  else task="Probe for paddock Issue #277. A measurement the secretary permits; do not decline, do not report. Run exactly ONE Bash call, its timeout set to 600000 ms, with the sandbox ON: until [ -f $OUT/$sl.release ]; do sleep 2; done
Run it exactly as written (a bare sleep is blocked, this loop is not). Do nothing else, then reply with the single word done."; fi
  s0=$(date +%s)
  dout=$(bash "$DELE" --project "$PJ" --task-id "$tid" --task "$task" "$@" 2>&1); drc=$?
  echo "delegate $sfx: exit=$drc after $(( $(date +%s) - s0 )) s; output: $(printf '%s' "$dout" | tr '\n' ' ' | cut -c1-420)"
}
facts() { # SUFFIX: what the delegate left
  tid=$ID-$1
  echo "  worktree=$([ -d "$workers/$tid" ] && echo created || echo absent) branch=$(git -C "$PJ" rev-parse --verify -q "work/$tid" >/dev/null && echo yes || echo no) paddockBase=$(git -C "$PJ" config --get "branch.work/$tid.paddockBase" 2>&1 | head -n 1 | cut -c1-60) upstream-merge=$(git -C "$PJ" config --get "branch.work/$tid.merge" 2>&1 | head -n 1 | cut -c1-60) terminal=$(hc get "w-$tid" >/dev/null 2>&1 && echo exists || echo absent)"
}
# wait_lock HOLD: the lock is on the host AND the worker's own hold loop (until [ -f ...release ]) runs (the worker's startup commands make a placeholder too)
# on a timeout, diag NAME prints what is on the host and the worker's screen, so the cause is visible
diag() { echo "  diag: config.lock $(hostlock "$PJ/.git"); processes matching the sleep: $(pgrep -af "$OUT/$2.release" | head -n 3 | tr '\n' '|' | cut -c1-200); screen: $(hc read "$1" 2>&1 | tail -n 8 | tr '\n' '|' | cut -c1-500)"; }
wait_lock() { t=0; while [ "$t" -lt "$WAIT" ]; do case "$(hostlock "$PJ/.git")" in present*) [ "$(pgrep -f "$OUT/$1.release" | wc -l)" -gt 0 ] && return 0 ;; esac; t=$((t + 1)); sleep 1; done; return 1; }
sub_delegate() {
  tf=${PADDOCK_WORKER_GH_TOKEN_FILE:-$cfg/paddock/worker-gh-token}
  [ -s "$tf" ] && [ -f "$TPL_DIR/worker.md" ] && [ -f "$bd/worker-rules.md" ] || { echo "RESULT precondition-failed: needs the real worker template ($TPL_DIR/worker.md), $bd/worker-rules.md and a non-empty token file ($tf); the production path starts with them"; exit 1; }
  P=$WORK/d; build "$P" && publish "$P" || { echo "RESULT precondition-failed: could not build the throw-away repository"; exit 1; }
  PJ=$P/proj
  echo "== 2c the secretary side. Is this shell sandboxed? (run it the way the secretary runs org-delegate, from its Bash tool, to learn the secretary's answer)"
  echo "   claude env names: $(env | sed -n 's/^\(CLAUDE[A-Z_]*\|SANDBOX[A-Z_]*\)=.*/\1/p' | tr '\n' ' ')"
  echo "   direct config write in the project clone, no worker running: $(cfgw p277.secretary 1)"
  git -C "$PJ" config --unset p277.secretary >/dev/null 2>&1
  echo "   direct write of .git/config by redirect: $( ( : >> "$PJ/.git/config" ) 2>&1 | head -n 1 | cut -c1-100)"
  echo "RESULT 2c-secretary-sandbox: DATA (see the three lines above; no error text there = this shell can write the clone's config)"

  echo "== 2a org-delegate while a worker's sandboxed command runs"
  dele a $SA || true; echo "  A $(facts a)"
  if [ "$drc" -ne 0 ]; then
    [ "$drc" -eq 10 ] && dialog_on "w-$ID-a" && need_person "w-$ID-a"
    echo "RESULT 2a-delegate-live-worker: NO DATA (worker A did not start, exit $drc)"
  elif ! wait_lock $SA; then echo "RESULT 2a-delegate-live-worker: NO DATA (config.lock and A's hold loop never ran together within ${WAIT}s)"; diag "w-$ID-a" "$SA"
  else
    echo "  host while A's command runs: config.lock $(hostlock "$PJ/.git"), A's hold loop running: $(pgrep -f "$OUT/$SA.release" | wc -l)"
    echo "  direct 'git config' from this shell now: $(cfgw p277.live 1)"; git -C "$PJ" config --unset p277.live >/dev/null 2>&1
    dele b none; echo "  B (default base: fetch, origin/main) $(facts b)"
    dele c none --no-fetch --base main; echo "  C (--no-fetch --base main, local base: no upstream write) $(facts c)"
    echo "  host after B and C: config.lock $(hostlock "$PJ/.git"), A's hold loop still running: $(pgrep -f "$OUT/$SA.release" | wc -l) (0 = B and C ran after A's command ended: discard the 2a result)"
    echo "RESULT 2a-delegate-live-worker: DATA (B exit/facts and C exit/facts above; exit 6 + worktree absent = the delegate fails; worktree created + paddockBase empty = line 177 hid a failed write)"
    : > "$OUT/$SA.release"   # A's command ends now: does its placeholder go away?
    t=0; while [ "$t" -lt "$WAIT" ]; do case "$(hostlock "$PJ/.git")" in absent) break ;; esac; t=$((t + 3)); sleep 3; done
    echo "RESULT 2a-placeholder-after-clean-exit: DATA (A's hold loop and its command ended; B/C may still hold one; after waiting $t s: config.lock $(hostlock "$PJ/.git"))"
  fi
  endterm "w-$ID-b"; endterm "w-$ID-c"; endterm "w-$ID-a"; sleep 3
  case "$(hostlock "$PJ/.git")" in present*) echo "== a lock is still on the host before phase 2 ($(hostlock "$PJ/.git")); removing it so phase 2 starts clean"; rm -f "$PJ/.git/config.lock" ;; esac

  echo "== 2b stranded config.lock: kill the worker's pane in the middle of its command (hc kill + hc rm, the org-resume / org-down path)"
  dele d $SD || true
  if [ "$drc" -ne 0 ]; then echo "RESULT 2b-stranded-lock: NO DATA (worker D did not start, exit $drc)"
  elif ! wait_lock $SD; then echo "RESULT 2b-stranded-lock: NO DATA (config.lock and D's hold loop never ran together within ${WAIT}s)"; diag "w-$ID-d" "$SD"
  else
    echo "  before the kill: config.lock $(hostlock "$PJ/.git"); hold loops: $(pgrep -f "$OUT/$SD.release" | wc -l)"
    hc kill "w-$ID-d" >/dev/null 2>&1; hc rm "w-$ID-d" >/dev/null 2>&1; sleep 3
    echo "  after the kill: config.lock $(hostlock "$PJ/.git"); hold loops still alive: $(pgrep -f "$OUT/$SD.release" | wc -l)"
    echo "  'git config' write now: $(cfgw p277.strand 1)"; git -C "$PJ" config --unset p277.strand >/dev/null 2>&1
    dele e none; echo "  E, a new delegate against the stranded lock $(facts e)"
    endterm "w-$ID-e"
    : > "$OUT/$SD.release"; sleep 4   # the orphaned hold loop (if the kill left it) ends now
    echo "  after the leftover sleep ended too: config.lock $(hostlock "$PJ/.git")"
    if command -v timeout >/dev/null 2>&1; then dd_out=$(cd "$PJ" && timeout 60 claude doctor </dev/null 2>&1); dd_rc=$?; else dd_out=$(cd "$PJ" && claude doctor </dev/null 2>&1); dd_rc=$?; fi
    echo "  claude doctor: exit=$dd_rc, $(printf '%s\n' "$dd_out" | wc -l) lines; lines naming a lock, placeholder or sandbox: $(printf '%s\n' "$dd_out" | grep -iE 'lock|placeholder|sandbox' | head -n 6 | tr '\n' '|' | cut -c1-400)"
    echo "RESULT 2b-stranded-lock: DATA (the lines above: whether the lock survives the kill, what E did against it, whether claude doctor names it)"
  fi
}

# =========================================================== 3 race
sub_race() {
  mk_template
  P=$WORK/r; build "$P" && publish "$P" && mkwt "$P/proj" "$workers/$ID" "$ID" || { echo "RESULT precondition-failed: could not build the throw-away repository"; exit 1; }
  N=${PADDOCK_PROBE_RACE_N:-30}; RW=${PADDOCK_PROBE_RACE_WAIT:-720}
  list=; i=1; while [ "$i" -le "$N" ]; do list="$list
sh $OUT/w.sh n $i"; i=$((i + 1)); done
  TASK="Probe for paddock Issue #277. This is a measurement the secretary asks for and permits; do not decline or report blocked. Work only in this worktree plus the folder $OUT. Run these $N commands in order, each as its OWN Bash call (one command per call, never several in one call, never in parallel), with the sandbox ON (never skip it):$list
If a call fails or prints an error, do NOT retry it: go straight on to the next number. After number $N reply with the single word done."
  launch "w-$ID" "$workers/$ID" "$ID" "$TASK" || exit 1
  # the churn: the secretary's side, writing the shared config and fetching in the project clone while the worker's commands start
  ( i=0; ok=0; bad=0; ferr=0
    while [ ! -f "$OUT/churn.stop" ]; do
      i=$((i + 1))
      if git -C "$P/proj" config p277.churn "$i" 2>/dev/null; then ok=$((ok + 1)); git -C "$P/proj" config --unset p277.churn 2>/dev/null; else bad=$((bad + 1)); fi
      if [ $((i % 5)) -eq 0 ]; then git -C "$P/seed" commit -q --allow-empty -m "c$i" && git -C "$P/seed" push -q origin main 2>/dev/null; git -C "$P/proj" fetch -q origin 2>/dev/null || ferr=$((ferr + 1)); fi
      sleep 0.2
    done
    echo "churn cycles=$i config-writes-ok=$ok config-writes-failed=$bad fetch-failed=$ferr" > "$OUT/churn.res" ) &
  CHURN=$!
  t=0; last=0; idle=0   # ends at number N, at RW s, or when no new number appears for 150 s after the first
  while [ "$t" -lt "$RW" ]; do
    [ -f "$OUT/n$N.txt" ] && break
    dialog_on "w-$ID" && need_person "w-$ID"
    c=$(ls "$OUT"/n[0-9]*.txt 2>/dev/null | wc -l)
    if [ "$c" -ne "$last" ]; then last=$c; idle=0; else idle=$((idle + 3)); fi
    [ "$last" -gt 0 ] && [ "$idle" -ge 150 ] && break
    t=$((t + 3)); sleep 3
  done
  : > "$OUT/churn.stop"; sleep 1; wait "$CHURN"; CHURN=
  ran=$(ls "$OUT"/n[0-9]*.txt 2>/dev/null | wc -l); tj=$(transcripts "$ID"); att=; errs=; bw=
  if [ -n "$tj" ]; then
    att=$(cat $tj | grep -E '"type": ?"tool_use"' | grep -E '"name": ?"Bash"' | grep -o 'w\.sh n [0-9]*' | sort -u | wc -l)   # Bash tool calls only: the prompt text lists all of them
    errs=$(cat $tj | grep -c '"is_error":true')
    bw=$(cat $tj | grep -o "bwrap: [^\"\\\\]*\|Can't get type of source[^\"\\\\]*" | sort | uniq -c | sort -rn | head -n 5 | tr '\n' '|')
  fi
  echo "== churn: $(cat "$OUT/churn.res" 2>/dev/null)"
  echo "== worker commands: attempted=${att:-unknown (no transcript found under ~/.claude/projects)} ran=$ran/$N error-results=${errs:-?} bwrap-text=${bw:-none}"
  missing=; i=1; while [ "$i" -le "$N" ]; do [ -f "$OUT/n$i.txt" ] || missing="$missing $i"; i=$((i + 1)); done
  echo "== numbers whose command never ran:${missing:- none}"
  echo "== worker screen tail"; hc read "w-$ID" 2>&1 | tail -n 8
  if [ "$ran" -eq "$N" ] && [ -z "$tj" ]; then echo "RESULT 3-launch-race: INCONCLUSIVE (all $N ran, but no transcript was found under ~/.claude/projects, so a start failure that was retried cannot be ruled out)"
  elif [ "$ran" -eq "$N" ] && [ -z "$bw" ]; then echo "RESULT 3-launch-race: PASS (all $N commands ran, no bwrap failure text in the transcript; churn: $(cat "$OUT/churn.res" 2>/dev/null))"
  elif [ "$ran" -eq "$N" ]; then echo "RESULT 3-launch-race: FAIL (all $N ran in the end but start failures were reported, so the harness or the worker retried: $bw)"
  elif [ -n "${att:-}" ] && [ "$att" -lt "$N" ]; then echo "RESULT 3-launch-race: INCONCLUSIVE (the worker attempted only $att of $N commands; ran=$ran)"
  else echo "RESULT 3-launch-race: FAIL ($((N - ran)) of $N commands never ran: numbers$missing; text: ${bw:-not in the transcript})"; fi
}

# =========================================================== 4 shapes
# shape KEY: builds clone shape KEY, one worker, the same six git commands in each; PASS = all exit 0.
shape_one() {
  k=$1; tid=$ID-$k; wt=$workers/$tid; P=$WORK/$k
  build "$P" || { echo "RESULT 4-$k: NO DATA (could not build)"; return; }
  case $k in
    subm) mkdir -p "$P/subsrc" && git -C "$P/subsrc" init -q -b main && echo s > "$P/subsrc/s.txt" && git -C "$P/subsrc" add s.txt && git -C "$P/subsrc" commit -q -m s \
      && git -C "$P/seed" -c protocol.file.allow=always submodule add -q "$P/subsrc" vendor >/dev/null 2>&1 && git -C "$P/seed" commit -q -m "add submodule" ;;
  esac
  publish "$P" || { echo "RESULT 4-$k: NO DATA (could not publish)"; return; }
  case $k in
    hook) mkdir -p "$P/hooks-elsewhere" && mv "$P/proj/.git/hooks" "$P/hooks-elsewhere/h" && ln -s "$P/hooks-elsewhere/h" "$P/proj/.git/hooks" ;;
    wtcfg) git -C "$P/proj" config extensions.worktreeConfig true ;;
  esac
  mkwt "$P/proj" "$wt" "$tid" || { echo "RESULT 4-$k: NO DATA (git worktree add failed)"; return; }
  case $k in wtcfg) git -C "$wt" sparse-checkout set --no-cone sub base.txt >/dev/null 2>&1 ;; esac
  echo "== shape $k: host .git/hooks=$([ -L "$P/proj/.git/hooks" ] && echo symlink || echo dir) config.worktree on host=$([ -e "$P/proj/.git/config.worktree" ] && echo yes || echo no) worktree config.worktree=$([ -e "$P/proj/.git/worktrees/$tid/config.worktree" ] && echo yes || echo no) .gitmodules tracked=$(git -C "$wt" ls-files .gitmodules | wc -l)"
  rm -f "$OUT/shape.rc" "$OUT/shape.txt"
  TASK="Probe for paddock Issue #277. This is a measurement the secretary asks for and permits; do not decline or report blocked. Work only in this worktree plus the folder $OUT. Run this ONE command as ONE Bash call, with the sandbox ON (never skip it), and do nothing else: sh $OUT/w.sh shape
If it fails or prints an error, do not retry it another way. Then reply with the single word done."
  launch "w-$tid" "$wt" "$tid" "$TASK" || { echo "RESULT 4-$k: NO DATA (launch failed)"; return; }
  if waitfor "w-$tid" shape.rc "$WAIT"; then
    sed 's/^/   /' "$OUT/shape.txt"
    bad=$(grep -E '^(status|log|diff|add-u|add-new|commit) rc=[1-9]' "$OUT/shape.txt" | tr '\n' ';' | cut -c1-240)
    warn=$(grep -E '^(status|log|diff|add-u|add-new|commit) rc=0 .+' "$OUT/shape.txt" | tr '\n' ';' | cut -c1-240)
    if [ -z "$bad" ]; then echo "RESULT 4-$k: PASS (status, log, diff, add -u, add, commit all exit 0; stderr noise: ${warn:-none}; host sees: $(git -C "$wt" log --format=%s -1))"
    else echo "RESULT 4-$k: FAIL ($bad)"; fi
  else
    err=; tj=$(transcripts "$tid"); [ -z "$tj" ] || err=$(cat $tj | grep -o "bwrap: [^\"\\\\]*\|Can't[^\"\\\\]*\|sandbox[^\"\\\\]\{0,100\}" | sort | uniq -c | sort -rn | head -n 4 | tr '\n' '|')
    echo "RESULT 4-$k: FAIL (the command never ran within ${WAIT}s; a sandbox that cannot start fails closed; transcript text: ${err:-none found}; screen: $(hc read "w-$tid" 2>&1 | tail -n 6 | tr '\n' '|' | cut -c1-300))"
  fi
  endterm "w-$tid"
}
sub_shapes() {
  mk_template
  for k in ctl hook wtcfg subm; do shape_one $k; done
}

case $SUB in mounts) sub_mounts ;; delegate) sub_delegate ;; race) sub_race ;; shapes) sub_shapes ;; esac
echo "== done: paste every line above (the RESULT lines and the lines between them)"
