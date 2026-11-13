#!/bin/sh
# Probe for Issue #277, option D (local mirror) in docs/design/worker-github-access.md:
# can a worker with NO GitHub credential work from the secretary's project clone?
#
# Run on the host, from the repo root, in a core terminal (HC_TERMINAL_SOCKET set), after
# `bash skills/org-start/scripts/org-start.sh` from THIS checkout (so the worker rules are placed):
#   sh scripts/probes/worker-mirror.sh <github-url>
# <github-url> is an https URL of a PRIVATE repository that your own login can read, for example
# https://github.com/OWNER/REPO.git. It is only fetched from (never pushed to), by the runner as a control
# and by the worker as the "must fail" case. Needs: hc, git, claude, POSIX sh, cksum; the workers folder
# (PADDOCK_WORKERS_DIR, default ~/paddock-workers) already trusted by Claude Code. Takes 3-6 minutes
# (PADDOCK_PROBE_WAIT, default 240 s, per wait).
#
# What it touches. Everything lives in one private temp folder (mktemp under $TMPDIR): a bare "upstream"
# repository, a clone of it that plays the secretary's project clone, and a seed clone. It adds one
# worktree + branch p277-<pid>-<time> in that throw-away clone, under the workers folder, one terminal
# p277-w and one temporary template p277-worker (in the core's templates folder). It writes no mailbox
# or org-state record. No real repository is changed; the github URL is only read. The exit trap removes
# the terminal, template, worktree and temp folder (kept, and named, when a person must answer a dialog).
#
# How the worker is started. The command line is the one in templates/worker.md with two edits, both
# printed: the read-only token check and GH_TOKEN="$tok" are cut out, the four GitHub token variables are
# unset in the launch prefix (so a token in the runner's environment is not inherited), and
# --settings points at a copy of templates/worker-settings.json whose allowWrite holds only the probe's
# result folder. GH_CONFIG_DIR is kept as the template sets it (a fresh empty folder). The worktree gets
# the same .claude/settings.local.json deny of the core socket folder that org-delegate writes. Not
# reproduced: the template body (the probe's message replaces it), org-delegate itself (it needs a real
# project and writes the mailbox), and the org mailbox: the stale-base "message" is a file the worker
# writes and the probe reads. So item 3 proves the git side of the round trip, not the mailbox side.
#
# What the worker is told to do (it is told this is a permitted measurement; the standing rules would
# make a worker hesitate). It runs `sh <out>/w.sh <phase>` three times, one Bash call each:
#   read    : checks its environment, reads origin/main from the shared clone, commits a file,
#             tries gh auth status, git credential fill and a fetch of <github-url>, then writes a
#             "base is stale" message file.
#   wait    : up to 170 s for the probe's go file, then reads origin/main again.
#   rebase  : git rebase origin/main.
# Between read and wait the probe plays the secretary: pushes a new commit to upstream (what a merge on
# GitHub would do), runs `git fetch origin` in the project clone, and touches the go file.
# `git push` is not attempted: the worker settings deny it by permission, which would prove nothing
# about the credential. Item 4 shows the credential side instead (no token, empty gh config dir, gh auth
# status fails, git credential fill returns no password, the GitHub fetch fails with an auth error).
#
# Reading the output. One line per item, "RESULT <n> <name>: PASS|FAIL|INCONCLUSIVE|NO DATA (detail)":
#   1 read-shared-refs       the worktree reads origin/main, its log, diff and objects from the
#                            project clone, and can commit (the shared object store / refs are writable)
#   2 fetch-visible          after the secretary's fetch, the running worker sees the new origin/main
#   3 stale-base-round-trip  the worker's message, the secretary's fetch, the worker's own rebase
#   4 no-github-credential   no token, empty gh config, gh auth status fails, no git credential,
#                            GitHub fetch fails with an auth error and leaves refs/remotes unchanged
# INCONCLUSIVE in 4 = the fetch failed for a non-auth reason (network allowlist?) or the control fetch
# from the runner failed, so the failure does not show a missing credential. Then "SUMMARY n/4 PASS".
# Paste everything back. The output holds sha prefixes and error lines, no credential values.
#
# Dry run without hc: PADDOCK_PROBE_NO_WORKER=1 sh scripts/probes/worker-mirror.sh <url> runs the same
# phases as plain shell in the worktree (no template, no sandbox, no claude): a check of this script's
# logic only, the items are then labelled "no worker".
set -u
ROOT=$(pwd)
URL=${1:-}
NOW=${PADDOCK_PROBE_NO_WORKER:-}
[ -f "$ROOT/templates/worker.md" ] || { echo "RESULT precondition-failed: run from the repo root"; exit 1; }
[ -n "$URL" ] || { echo "RESULT precondition-failed: give the https URL of a private GitHub repository as the argument"; exit 1; }
for c in git cksum; do command -v $c >/dev/null 2>&1 || { echo "RESULT precondition-failed: $c not on PATH"; exit 1; }; done
[ -n "$NOW" ] || for c in hc claude; do command -v $c >/dev/null 2>&1 || { echo "RESULT precondition-failed: $c not on PATH"; exit 1; }; done

ID=p277-$$-$(date +%s); NAME=p277-w; TPL=p277-worker
WAIT=${PADDOCK_PROBE_WAIT:-240}
cfg=${APPDATA:-${XDG_CONFIG_HOME:-$HOME/.config}}
TPL_DIR=${PADDOCK_CORE_TEMPLATES_DIR:-$cfg/herdr-core/templates}
bd=${PADDOCK_BIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/paddock/bin}
workers=${PADDOCK_WORKERS_DIR:-$HOME/paddock-workers}
WT=$workers/$ID
has() { hc ls 2>&1 | grep -Eq "(^|[^A-Za-z0-9_-])$1([^A-Za-z0-9_-]|\$)"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/probe277.XXXXXX") || exit 1
case "$WORK$WT$bd" in *[[:space:]]*) echo "RESULT precondition-failed: paths must not contain whitespace ($WORK $WT $bd)"; exit 1 ;; esac
OUT=$WORK/out; UP=$WORK/up.git; SEED=$WORK/seed; PROJ=$WORK/proj
mkdir -p "$OUT" || exit 1
KEEP= OWNTERM= OWNTPL=
. "$(dirname "$0")/claude-link.sh"
claude_link_save
cleanup() {
  claude_link_restore
  if [ -n "$KEEP" ]; then echo "kept for a person: terminal $NAME, worktree $WT, temp folder $WORK, template $TPL_DIR/$TPL.md"; return; fi
  if [ -n "$OWNTERM" ]; then hc kill $NAME >/dev/null 2>&1; hc rm $NAME >/dev/null 2>&1; fi
  if [ -n "$OWNTPL" ]; then rm -f "$TPL_DIR/$TPL.md"; fi
  git -C "$PROJ" worktree remove --force "$WT" >/dev/null 2>&1
  rm -rf "$WT" "$WORK"
}
trap cleanup EXIT INT TERM
[ -z "$NOW" ] && { has $NAME && { echo "RESULT precondition-failed: terminal $NAME exists (leftover of an earlier run)"; KEEP=; exit 1; }; [ -e "$TPL_DIR/$TPL.md" ] && { echo "RESULT precondition-failed: $TPL_DIR/$TPL.md exists; remove it"; exit 1; }; }

export GIT_AUTHOR_NAME=p277 GIT_AUTHOR_EMAIL=p277@example.invalid GIT_COMMITTER_NAME=p277 GIT_COMMITTER_EMAIL=p277@example.invalid
echo "== versions"; git --version; [ -z "$NOW" ] && { hc --version 2>&1; claude --version 2>&1; }

# Control: the runner (which has the person's login) can read <github-url>; otherwise item 4 cannot show a missing credential.
if GIT_TERMINAL_PROMPT=0 git ls-remote "$URL" >/dev/null 2>&1; then CONTROL=ok; else CONTROL=failed; fi
echo "== control: runner ls-remote of the github URL: $CONTROL"

# The throw-away repositories: upstream (GitHub's stand-in), the secretary's project clone, a seed clone.
{
  git -c init.defaultBranch=main init -q --bare "$UP" &&
  git clone -q "$UP" "$SEED" 2>/dev/null &&
  git -C "$SEED" checkout -q -b main &&
  echo base > "$SEED/base.txt" && git -C "$SEED" add base.txt && git -C "$SEED" commit -q -m c1 &&
  git -C "$SEED" push -q origin main &&
  git -C "$SEED" rev-parse HEAD > "$OUT/expect1" &&
  echo next > "$SEED/next.txt" && git -C "$SEED" add next.txt && git -C "$SEED" commit -q -m c2 &&
  git -C "$SEED" rev-parse HEAD > "$OUT/expect2" &&
  git clone -q "$UP" "$PROJ" &&
  mkdir -p "$workers" &&
  git -C "$PROJ" worktree add -q -b "work/$ID" "$WT" origin/main
} || { echo "RESULT precondition-failed: could not build the throw-away repositories"; exit 1; }
printf '%s\n' "$URL" > "$OUT/ghurl"
E1=$(cat "$OUT/expect1"); E2=$(cat "$OUT/expect2")

# w.sh: runs in the worker (or in the worktree for the dry run). Prints facts, never credential values.
cat > "$OUT/w.sh" <<'W'
d=$(dirname "$0"); ph=$1; o=$d/$ph.txt; E1=$(cat "$d/expect1"); E2=$(cat "$d/expect2")
case $ph in
read)
  {
  [ -z "${GH_TOKEN-}${GITHUB_TOKEN-}${GH_ENTERPRISE_TOKEN-}${GITHUB_ENTERPRISE_TOKEN-}" ] && echo "tokens absent" || echo "tokens PRESENT"
  if [ -n "${GH_CONFIG_DIR-}" ] && [ -d "$GH_CONFIG_DIR" ] && [ -z "$(ls -A "$GH_CONFIG_DIR")" ]; then echo "ghdir empty"; else echo "ghdir not-empty-or-unset"; fi
  echo "origin $(git rev-parse origin/main 2>&1 | head -n 1)"
  git log --oneline origin/main >/dev/null 2>&1; echo "log-rc $?"
  git diff --stat origin/main...HEAD >/dev/null 2>&1; echo "diff-rc $?"
  git cat-file -p origin/main >/dev/null 2>&1; echo "cat-rc $?"
  echo w1 > w1.txt; git add w1.txt
  git -c user.name=p277 -c user.email=p277@example.invalid commit -q -m "p277 worker commit" > "$d/commit.err" 2>&1; echo "commit-rc $?"
  if command -v gh >/dev/null 2>&1; then gh auth status > "$d/gh.out" 2>&1; echo "gh-rc $?"; else echo "gh-rc 127"; fi
  cr=$(printf 'protocol=https\nhost=github.com\n\n' | GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never git credential fill 2>&1)
  case "$cr" in *password=*) echo "cred PRESENT" ;; *) echo "cred absent" ;; esac
  b=$(git for-each-ref refs/remotes | cksum)
  GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never git fetch "$(cat "$d/ghurl")" '+refs/heads/*:refs/remotes/p277gh/*' > "$d/ghfetch.out" 2>&1; echo "ghfetch-rc $?"
  [ "$b" = "$(git for-each-ref refs/remotes | cksum)" ] && echo "refs unchanged" || echo "refs CHANGED"
  if grep -Eqi 'tunnel failed|proxy|could not resolve|connection (refused|timed out)' "$d/ghfetch.out"; then echo "fetch-error other: network or proxy, not an auth answer: $(head -n 1 "$d/ghfetch.out" | cut -c1-120)"
  elif grep -Eqi 'authentication failed|could not read (username|password)|terminal prompts disabled|repository .*not found|invalid (username|credentials)|requested URL returned error: 40[134]|access denied' "$d/ghfetch.out"; then echo "fetch-error auth"; else echo "fetch-error other: $(head -n 1 "$d/ghfetch.out" | cut -c1-160)"; fi
  echo "base is stale, need origin/main at or after $E2" > "$d/stale.msg"
  } > "$o" 2>&1
  echo done > "$d/read.rc" ;;
wait)
  { echo "before $(git rev-parse origin/main 2>&1 | head -n 1)"; } > "$o"
  n=0; while [ ! -f "$d/go2" ] && [ $n -lt 170 ]; do n=$((n + 2)); sleep 2; done
  { [ -f "$d/go2" ] && echo "go yes" || echo "go NO"
    echo "after $(git rev-parse origin/main 2>&1 | head -n 1)"
    git cat-file -e "$E2^{commit}" 2>/dev/null; echo "have-c2-rc $?"
    git log --format=%H origin/main 2>/dev/null | grep -q "^$E2" ; echo "log-c2-rc $?"; } >> "$o" 2>&1
  echo done > "$d/wait.rc" ;;
rebase)
  { git rebase origin/main > "$d/rebase.out" 2>&1; echo "rebase-rc $?"
    git merge-base --is-ancestor "$E2" HEAD >/dev/null 2>&1; echo "anc-rc $?"
    [ -f w1.txt ] && echo "w1 yes" || echo "w1 NO"; } > "$o" 2>&1
  echo done > "$d/rebase.rc" ;;
esac
W

run_phases_local() { for p in read wait rebase; do (cd "$WT" && sh "$OUT/w.sh" $p); done; }

if [ -z "$NOW" ]; then
  # The template: the command of templates/worker.md without the token check and GH_TOKEN, with --settings at the probe's copy.
  CMD=$(sed -n 's/^command: //p' "$ROOT/templates/worker.md")
  SETTINGS=$WORK/worker-settings.json
  CMD=$(printf '%s' "$CMD" | sed -e 's/tok=.*exit 1; }; //' -e 's/ GH_TOKEN="\$tok"//' -e "s|--settings \"\\\$ws\"|--settings $SETTINGS|" \
    -e 's/^env -u /env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN -u /')
  case "$CMD" in *'GH_TOKEN="'*|*'$tok'*|*'--settings "$ws"'*) echo "RESULT precondition-failed: could not derive the credential-free command from templates/worker.md (it changed?)"; echo "   $CMD" | cut -c1-300; exit 1 ;; esac
  case "$CMD" in *"exec env GH_CONFIG_DIR="*"--settings $SETTINGS'") ;; *) echo "RESULT precondition-failed: derived command lacks the expected GH_CONFIG_DIR / --settings parts"; exit 1 ;; esac
  [ -f "$bd/worker-rules.md" ] || { echo "RESULT precondition-failed: $bd/worker-rules.md missing (run org-start from this checkout first)"; exit 1; }
  # worker settings: the shipped file with allowWrite holding only the result folder.
  [ "$(grep -c '"allowWrite": \[\]' "$ROOT/templates/worker-settings.json")" = 1 ] || { echo "RESULT precondition-failed: templates/worker-settings.json has no single empty allowWrite"; exit 1; }
  sed "s|\"allowWrite\": \[\]|\"allowWrite\": [\"$OUT\"]|" "$ROOT/templates/worker-settings.json" > "$SETTINGS"
  # the per-task deny of the core socket folder, as org-delegate writes it
  if [ -n "${PADDOCK_CORE_SOCKET_DIR:-}" ]; then sockdir=$PADDOCK_CORE_SOCKET_DIR; elif [ -n "${HC_TERMINAL_SOCKET:-}" ]; then sockdir=$(dirname "$HC_TERMINAL_SOCKET"); else echo "RESULT precondition-failed: run from a core terminal (HC_TERMINAL_SOCKET) or set PADDOCK_CORE_SOCKET_DIR"; exit 1; fi
  mkdir -p "$WT/.claude" && printf '{"sandbox":{"filesystem":{"denyRead":["%s"],"denyWrite":["%s"]}}}\n' "$sockdir" "$sockdir" > "$WT/.claude/settings.local.json" \
    && printf 'settings.local.json\n.gitignore\n' > "$WT/.claude/.gitignore" || { echo "RESULT precondition-failed: cannot write $WT/.claude"; exit 1; }
  printf -- '---\ndescription: probe 277 (temporary)\ncommand: %s\n---\nProbe 277. Follow only the message below.\n' "$CMD" > "$TPL_DIR/$TPL.md" || exit 1
  OWNTPL=1
  echo "== command under test (from templates/worker.md; token check and GH_TOKEN removed, --settings = $SETTINGS)"; echo "   $CMD" | cut -c1-400
  TASK="Probe for paddock Issue #277. This is a measurement the secretary asks for and permits; do not decline or report blocked. Work only in this worktree plus the folder $OUT. Run these three commands, each as ONE Bash call, in this order, with the sandbox ON (never skip it), and do nothing else:
1. sh $OUT/w.sh read
2. sh $OUT/w.sh wait     (set this Bash call's timeout to 200000; it waits for the secretary)
3. sh $OUT/w.sh rebase
If a command fails or prints an error, do not retry it another way; just go on to the next. Then reply with the single word done."
  OWNTERM=1
  hc run --bg --outlive-parent --name $NAME --cwd "$WT" --label task_id=p277 $TPL "$TASK" >/dev/null 2>&1 || { echo "RESULT precondition-failed: hc run failed"; exit 1; }
else
  (run_phases_local >/dev/null 2>&1 &)  # dry run: the phases run in the background; "go2" is touched below like in the real run
fi

# poll helper: wait for $OUT/$1 up to WAIT s; stops on a dialog the probe will not answer.
waitfor() {
  t=0
  while [ "$t" -lt "$WAIT" ]; do
    [ -f "$OUT/$1" ] && return 0
    if [ -z "$NOW" ]; then
      case "$(hc read $NAME 2>/dev/null)" in *"Quick safety check"*|*"trust this folder"*)
        echo "NEEDS-PERSON: folder-trust dialog in $NAME; trust $workers, answer it, and rerun"; KEEP=1; exit 1 ;; esac
    fi
    t=$((t + 3)); sleep 3
  done
  return 1
}

# ---- the secretary's part, after the worker has read and reported a stale base
if waitfor read.rc; then
  echo "== worker wrote read results and the stale message: $(cat "$OUT/stale.msg" 2>/dev/null | cut -c1-120)"
  git -C "$SEED" push -q origin main 2>/dev/null  # what a merge on GitHub does: upstream moves to c2
  git -C "$PROJ" fetch -q origin 2>&1 | head -n 3
  echo "== secretary side: project clone origin/main is now $(git -C "$PROJ" rev-parse origin/main | cut -c1-10)"
  : > "$OUT/go2"
else
  echo "== no read results within ${WAIT}s"
fi
waitfor rebase.rc || echo "== no rebase results within ${WAIT}s"
[ -z "$NOW" ] && { echo "== worker screen tail"; hc read $NAME 2>&1 | tail -n 12; }

# ---- verdicts
g() { sed -n "s/^$2 //p" "$OUT/$1.txt" 2>/dev/null | head -n 1; }
PASS=0
res() { # n name verdict detail
  [ -z "$NOW" ] && lab= || lab=" [no worker: logic check only]"
  echo "RESULT $1 $2: $3 ($4)$lab"; [ "$3" = PASS ] && PASS=$((PASS + 1))
}
if [ -f "$OUT/read.rc" ]; then
  d="origin=$(g read origin | cut -c1-10) want=$(echo $E1 | cut -c1-10) log=$(g read log-rc) diff=$(g read diff-rc) cat=$(g read cat-rc) commit=$(g read commit-rc)"
  if [ "$(g read origin)" = "$E1" ] && [ "$(g read log-rc)" = 0 ] && [ "$(g read diff-rc)" = 0 ] && [ "$(g read cat-rc)" = 0 ] && [ "$(g read commit-rc)" = 0 ]; then res 1 read-shared-refs PASS "$d"
  else res 1 read-shared-refs FAIL "$d; commit error: $(head -n 2 "$OUT/commit.err" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"; fi
else res 1 read-shared-refs "NO DATA" "the worker never wrote read results"; fi

if [ -f "$OUT/wait.rc" ]; then
  d="before=$(g wait before | cut -c1-10) after=$(g wait after | cut -c1-10) want=$(echo $E2 | cut -c1-10) have-c2=$(g wait have-c2-rc) go=$(g wait go)"
  if [ "$(g wait after)" = "$E2" ] && [ "$(g wait have-c2-rc)" = 0 ] && [ "$(g wait log-c2-rc)" = 0 ]; then res 2 fetch-visible PASS "$d"; else res 2 fetch-visible FAIL "$d"; fi
else res 2 fetch-visible "NO DATA" "the worker never reached the wait step"; fi

if [ -f "$OUT/rebase.rc" ] && [ -f "$OUT/stale.msg" ]; then
  d="rebase=$(g rebase rebase-rc) ancestor=$(g rebase anc-rc) w1=$(g rebase w1) commit-before=$(g read commit-rc); host sees: $(git -C "$WT" log --format=%s -3 2>/dev/null | tr '\n' ',')"
  if [ "$(g rebase rebase-rc)" = 0 ] && [ "$(g rebase anc-rc)" = 0 ] && [ "$(g read commit-rc)" = 0 ] && [ "$(g rebase w1)" = yes ]; then res 3 stale-base-round-trip PASS "$d"
  else res 3 stale-base-round-trip FAIL "$d; rebase output: $(head -n 3 "$OUT/rebase.out" 2>/dev/null | tr '\n' ' ' | cut -c1-240)"; fi
else res 3 stale-base-round-trip "NO DATA" "no stale message or no rebase result"; fi

if [ -f "$OUT/read.rc" ]; then
  d="tokens=$(g read tokens) ghdir=$(g read ghdir) gh-auth-status-rc=$(g read gh-rc) git-credential=$(g read cred) fetch-rc=$(g read ghfetch-rc) refs=$(g read refs) $(g read fetch-error)"
  ok=
  [ "$(g read tokens)" = absent ] && [ "$(g read ghdir)" = empty ] && [ "$(g read gh-rc)" != 0 ] && [ "$(g read cred)" = absent ] && [ "$(g read refs)" = unchanged ] && [ "$(g read ghfetch-rc)" != 0 ] && ok=1
  if [ -z "$ok" ]; then res 4 no-github-credential FAIL "$d"
  elif [ "$CONTROL" != ok ]; then res 4 no-github-credential INCONCLUSIVE "$d; the runner's own ls-remote of the URL failed, so the URL is not proven readable"
  else case "$(g read fetch-error)" in "other"*) res 4 no-github-credential INCONCLUSIVE "$d; the fetch failed, but not with an auth error (network allowlist?)" ;; *) res 4 no-github-credential PASS "$d" ;; esac; fi
  echo "   GitHub fetch error (first lines): $(head -n 2 "$OUT/ghfetch.out" 2>/dev/null | tr '\n' ' ' | cut -c1-240)"
else res 4 no-github-credential "NO DATA" "the worker never wrote read results"; fi
echo "SUMMARY $PASS/4 PASS"
[ "$PASS" = 4 ]
