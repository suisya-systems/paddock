#!/usr/bin/env bash
# Acceptance test for skills/org-delegate/scripts/org-delegate.sh (Issue #62). Needs only
# bash, coreutils and git: hc is a stub on PATH, so no core runs. The project is a real
# throwaway git repository; scripts/org is the real one, writing under a throwaway state dir.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-delegate/scripts/org-delegate.sh
org=$here/scripts/org
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

[ -f "$script" ]; check "script exists" $?
[ -f "$here/skills/org-delegate/SKILL.md" ]; check "SKILL.md exists" $?
bash -n "$script" 2>/dev/null; check "script parses" $?

# Stub hc. State lives in $STUB: "term-<name>" exists while a terminal of that name exists.
# Every call is appended to $STUB/calls; `file write` also copies its stdin to the path and
# keeps the stdin in $STUB/written; `run` keeps its argv one per line in $STUB/run-argv.
# STUB_FIRST_SENT=false: run reports first_message.sent false. STUB_RUN_FAIL=1: run fails.
# STUB_WRITE_FAIL=1: file write fails. STUB_LS_FAIL=1: ls fails. STUB_RUN_FAIL_AFTER=1: run makes the
# terminal, then fails. STUB_RUN_OUT=<text>: run answers with that text. STUB_LOCK=1: run locks the
# worktree first, so that `git worktree remove --force` cannot undo it.
stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/calls"
cmd=$1; shift
case "$cmd" in
  ls) [ -z "${STUB_LS_FAIL:-}" ] || { echo 'hc: cannot reach the core' >&2; exit 1; }; echo '[]'; exit 0 ;;
  get) name=; for a in "$@"; do case "$a" in --*) ;; *) name=$a ;; esac; done
       [ -f "$STUB/term-$name" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       if [ -n "${STUB_TRUST:-}" ] && [ -f "$STUB/entered" ]; then echo "{\"name\":\"$name\",\"state\":\"live\",\"status\":{\"state\":\"idle\"}}"
       else echo "{\"name\":\"$name\",\"state\":\"live\"}"; fi; exit 0 ;;
  keys) [ "$2" != enter ] || : > "$STUB/entered"; [ "$2" != down ] || : > "$STUB/down"; exit 0 ;;
  read) [ -n "${STUB_TRUST:-}" ] || exit 0
        if [ -f "$STUB/down" ]; then printf ' Quick safety check\n   1. No, exit\n \342\235\257 2. Yes, I trust this folder\n'
        else printf ' Quick safety check\n \342\235\257 1. No, exit\n   2. Yes, I trust this folder\n'; fi; exit 0 ;;
  file) [ "$1" = write ] || exit 2; shift
        [ -z "${STUB_WRITE_FAIL:-}" ] || { echo 'hc: write refused' >&2; exit 1; }
        path=; for a in "$@"; do case "$a" in --*) ;; *) path=$a ;; esac; done
        mkdir -p "$(dirname "$path")" && cat > "$path" && cp "$path" "$STUB/written"
        echo '{"written":true}'; exit 0 ;;
  run) tname=; cwd=; prev=
       for a in "$@"; do case "$prev" in --name) tname=$a ;; --cwd) cwd=$a ;; esac; prev=$a; done
       # The start record must exist before the worker is launched.
       ls "$PADDOCK_STATE_DIR"/events/*/secretary.jsonl >/dev/null 2>&1 && echo yes > "$STUB/record-before-run"
       : > "$STUB/run-argv"; for a in "$@"; do printf '%s\n' "$a" >> "$STUB/run-argv"; done
       [ -z "${STUB_LOCK:-}" ] || git -C "$STUB_PROJ" worktree lock "$cwd"
       [ -z "${STUB_RUN_FAIL_AFTER:-}" ] || : > "$STUB/term-$tname"
       [ -z "${STUB_RUN_FAIL:-}${STUB_RUN_FAIL_AFTER:-}" ] || { echo 'hc: run failed' >&2; exit 1; }
       : > "$STUB/term-$tname"
       [ -z "${STUB_RUN_OUT:-}" ] || { echo "$STUB_RUN_OUT"; exit 0; }
       echo "{\"first_message\":{\"sent\":${STUB_FIRST_SENT:-true},\"started\":true,\"turn\":0}}"; exit 0 ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"

# A throwaway project with a main branch.
proj=$tmp/project
git init -q -b main "$proj" 2>/dev/null || { git init -q "$proj"; git -C "$proj" checkout -q -b main; }
git -C "$proj" -c user.name=t -c user.email=t@t.invalid commit -q --allow-empty -m init
workers=$tmp/workers

reset() {
  rm -rf "$tmp/stub" "$workers" "$tmp/real-workers" "$tmp/link-workers" "$tmp/state"; mkdir -p "$tmp/stub"; : > "$tmp/stub/calls"
  git -C "$proj" worktree prune
  git -C "$proj" for-each-ref --format='%(refname:short)' refs/heads \
    | grep -Ev '^(main|weird-base|tracked-base)$' | while read -r b; do git -C "$proj" branch -q -D "$b"; done
  return 0
}
run() { # run <env assignments...> -- <args...>
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  env -u PADDOCK_ORG_ID -u HC_TERMINAL_SOCKET PADDOCK_CORE_SOCKET_DIR="$tmp/run/herdr-core" STUB="$tmp/stub" STUB_PROJ="$proj" PATH="$stubdir:$PATH" PADDOCK_WORKERS_DIR="$workers" \
      PADDOCK_STATE_DIR="$tmp/state" PADDOCK_NOW=2026-11-10T01:02:03Z "${envs[@]}" bash "$script" "$@" 2>&1
}
calls=$tmp/stub/calls
line() { grep -n "$1" "$calls" | head -1 | cut -d: -f1; } # line <regex> of the call log
good=(--project "$proj" --task-id t1 --task "Fix the typo in README.")

# Arguments and environment.
out=$(bash "$script" --help 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -qi 'usage' <<<"$out"; check "--help exits 0 with usage" $?
bash "$script" --no-such-flag >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; check "unknown argument exits 2" $?
reset
for bad in "--project $proj --task t" "--task-id t1 --task t" "--project $proj --task-id t1" \
           "--project $proj --task-id T1 --task t" "--project $proj --task-id has_space? --task t" \
           "--project $proj --task-id aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --task t" \
           "--project $proj --task-id t1 --task t --allow-write relative/path" \
           "--project $proj --task-id t1 --task t --allow-write /a\"b" \
           "--project $proj --task-id t1 --task t --task-file /dev/null"; do
  # shellcheck disable=SC2086
  out=$(run -- $bad); rc=$?
  [ "$rc" -eq 2 ] && ! grep -Eq '^(run|file) ' "$calls" && [ ! -d "$workers" ]
  check "bad arguments exit 2, nothing created: $bad" $?
done
out=$(env PATH="$tmp/empty" "$(command -v bash)" "$script" "${good[@]}" 2>&1); rc=$?
[ "$rc" -eq 3 ]; check "no hc or git on PATH exits 3" $?
reset; out=$(run STUB_LS_FAIL=1 -- "${good[@]}"); rc=$?
[ "$rc" -eq 5 ] && [ ! -d "$workers" ]; check "core unreachable exits 5, creates nothing" $?
reset; out=$(run -- --project "$tmp/not-a-repo" --task-id t1 --task t); rc=$?
[ "$rc" -eq 6 ] && ! grep -Eq '^(run|file) ' "$calls"; check "project that is not a git repository exits 6" $?
reset; out=$(run -- "${good[@]}" --base no-such-ref); rc=$?
[ "$rc" -eq 6 ] && ! grep -Eq '^(run|file) ' "$calls" && [ ! -e "$workers/t1" ]; check "unknown base exits 6, starts nothing" $?

# Happy path.
reset; out=$(run -- "${good[@]}"); rc=$?
[ "$rc" -eq 0 ]; check "delegation exits 0 ($out)" $?
grep -q "worker=w-t1 worktree=$workers/t1 branch=work/t1" <<<"$out"; check "prints worker, worktree and branch" $?
[ -d "$workers/t1" ] && [ "$(git -C "$workers/t1" rev-parse --abbrev-ref HEAD)" = work/t1 ] \
  && [ "$(git -C "$workers/t1" rev-parse HEAD)" = "$(git -C "$proj" rev-parse main)" ]
check "worktree is on branch work/t1 at main" $?
git -C "$proj" worktree list | grep -q "$workers/t1"; check "git knows the worktree" $?
fw=$(line '^file write '); r=$(line '^run '); g=$(line '^get ')
[ -n "$g" ] && [ -n "$fw" ] && [ -n "$r" ] && [ "$g" -lt "$fw" ] && [ "$fw" -lt "$r" ]
check "order: name check, settings file written, run" $?
[ -f "$tmp/stub/record-before-run" ]; check "the start record exists before hc run is called" $?
grep -q "^file write .*$workers/t1/.claude/settings.local.json" "$calls"; check "settings go to <worktree>/.claude/settings.local.json" $?
# Issue #155: the socket folder deny is always there (tests/worker-core-api-holders.test.sh checks it).
# Issue #189: the npm, uv and pip caches go into the sandbox temporary folder of the worker (/tmp/claude-<uid>).
# Claude Code does not expand $TMPDIR in a settings env value, so the path is written out here.
ct=/tmp/claude-$(id -u)
envj="\"env\":{\"npm_config_cache\":\"$ct/npm-cache\",\"UV_CACHE_DIR\":\"$ct/uv-cache\",\"PIP_CACHE_DIR\":\"$ct/pip-cache\"}"
[ "$(tr -d ' \n' < "$workers/t1/.claude/settings.local.json")" = "{\"sandbox\":{\"filesystem\":{\"denyRead\":[\"$tmp/run/herdr-core\"],\"denyWrite\":[\"$tmp/run/herdr-core\"]}},$envj}" ]; check "no --allow-write writes the socket folder deny and the cache env" $?
! grep -q '\$TMPDIR' "$workers/t1/.claude/settings.local.json"; check "the cache env holds no unexpanded TMPDIR variable" $?
[ ! -e "$workers/t1/AGENTS.md" ] && [ ! -e "$workers/t1/CLAUDE.md" ] && [ ! -e "$workers/t1/CLAUDE.local.md" ]
check "no rules or brief file is written into the worktree (Q12)" $?
argv=$tmp/stub/run-argv
tr '\n' ' ' < "$argv" | grep -q -- "--bg " && grep -qx -- '--outlive-parent' "$argv" \
  && grep -qx -- 'w-t1' "$argv" && grep -qx -- "$workers/t1" "$argv" && grep -qx -- 'task_id=t1' "$argv"
check "run has --bg, --outlive-parent, --name w-t1, --cwd <worktree>, --label task_id=t1" $?
w=$(grep -nx worker "$argv" | tail -1 | cut -d: -f1)
[ -n "$w" ] && sed -n "$((w + 1))p" "$argv" | grep -q '^Your org id is w-t1'; check "template is 'worker', the task follows as the last argument" $?
# The task text spans several lines, so look for its parts anywhere in the run argv.
grep -q 'Your org id is w-t1' "$argv" && grep -q 'Fix the typo in README.' "$argv"; check "task text carries the org id and the task" $?
! grep -Eq '^(send|keys|kill|rm|server) ' "$calls"; check "never types into an agent, kills or touches the core" $?
list=$(PADDOCK_STATE_DIR="$tmp/state" PADDOCK_NOW=2026-11-10T01:02:04Z bash "$org" --as secretary list_runs)
grep -q '^t1.secretary.started' <<<"$list" || grep -Eq '^t1[[:space:]]+secretary[[:space:]]+started' <<<"$list"
check "the delegation is recorded: list_runs shows t1 started by secretary" $?
msgs=$(PADDOCK_STATE_DIR="$tmp/state" bash "$org" --as secretary check_messages --peek)
grep -q 'w-t1' <<<"$msgs"; check "the record names the worker" $?
# The worker reports done later: list_runs shows done, not the secretary's earlier start.
PADDOCK_STATE_DIR="$tmp/state" PADDOCK_NOW=2026-11-10T01:09:00Z bash "$org" --as w-t1 report done --task t1 "done" >/dev/null
list=$(PADDOCK_STATE_DIR="$tmp/state" PADDOCK_NOW=2026-11-10T01:09:05Z bash "$org" --as secretary list_runs)
grep -Eq '^t1[[:space:]]+w-t1[[:space:]]+done' <<<"$list"; check "a worker's later done wins over the delegation record in list_runs" $?

# Options.
reset; out=$(run -- "${good[@]}" --branch feat/x --base main --allow-write "$tmp/out dir" --allow-write '~/notes' --allow-write "$tmp/a&b"); rc=$?
[ "$rc" -eq 0 ] && [ "$(git -C "$workers/t1" rev-parse --abbrev-ref HEAD)" = feat/x ]; check "--branch names the branch" $?
[ "$(git -C "$workers/t1" config --get branch.feat/x.paddockBase)" = main ]; check "the base is recorded for the review gate (branch.<name>.paddockBase)" $?
# Issue #160: in the worker's own --settings file (Claude Code ignores allowWrite in settings.local.json once
# allowUnsandboxedCommands is false there), not in settings.local.json.
sj=$(tr -d '\n' < "$tmp/state/settings/t1.json")
grep -q '"allowWrite"' <<<"$sj" && grep -qF "\"$tmp/out dir\"" <<<"$sj" && grep -qF '"~/notes"' <<<"$sj" && grep -qF "\"$tmp/a&b\"" <<<"$sj" \
  && grep -q '"sandbox"' <<<"$sj" && grep -q '"filesystem"' <<<"$sj" \
  && ! grep -q '"allowWrite"' "$workers/t1/.claude/settings.local.json"
check "--allow-write lands in sandbox.filesystem.allowWrite of the per-task settings file" $?
# Issue #177: the two argument-free review-gate calls run outside the worker sandbox; exact strings, no
# wildcard, quoted and unquoted path, the same strings in excludedCommands and permissions.allow.
if command -v node >/dev/null 2>&1; then
  node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const g = (process.env.PADDOCK_BIN_DIR || (process.env.XDG_DATA_HOME || process.env.HOME + "/.local/share") + "/paddock/bin") + "/second-model-review.sh";
    const want = [`bash "${g}"`, `bash ${g}`, `bash "${g}" --design`, `bash ${g} --design`];
    const same = (a, b) => a.length === b.length && b.every(x => a.includes(x));
    const ex = s.sandbox.excludedCommands, al = s.permissions.allow.map(x => x.replace(/^Bash\((.*)\)$/, "$1"));
    process.exit(same(ex, want) && same(al, want) && !ex.concat(al).some(x => x.includes("*")) && s.sandbox.allowUnsandboxedCommands === false ? 0 : 1);' \
    "$tmp/state/settings/t1.json"
  check "the review gate's exact calls are in excludedCommands and permissions.allow of the per-task file" $?
fi
if command -v node >/dev/null 2>&1; then
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$workers/t1/.claude/settings.local.json"
  check "the settings file is valid JSON" $?
fi
reset; printf 'line one\nline "two"\n' > "$tmp/task.txt"
out=$(run -- --project "$proj" --task-id t1 --task-file "$tmp/task.txt"); rc=$?
[ "$rc" -eq 0 ] && grep -q 'line one' "$tmp/stub/run-argv" && grep -qF 'line "two"' "$tmp/stub/run-argv"; check "--task-file passes the file's text" $?
reset; out=$(printf 'from stdin\n' | run -- --project "$proj" --task-id t1 --task-file -); rc=$?
[ "$rc" -eq 0 ] && grep -q 'from stdin' "$tmp/stub/run-argv"; check "--task-file - reads stdin" $?
reset; out=$(run -- --project "$proj" --task-id t1 --task "$(printf 'a "quoted" $HOME `x`\nsecond')"); rc=$?
[ "$rc" -eq 0 ] && grep -qF 'a "quoted" $HOME `x`' "$tmp/stub/run-argv"; check "task text with quotes and \$ reaches hc run verbatim" $?

# Refusals: nothing is changed.
reset; : > "$tmp/stub/term-w-t1"; out=$(run -- "${good[@]}"); rc=$?
[ "$rc" -eq 7 ] && ! grep -Eq '^(run|file|kill|rm) ' "$calls" && [ ! -e "$workers/t1" ]; check "a terminal named w-t1 exists: exit 7, nothing created" $?
reset; mkdir -p "$workers/t1"; out=$(run -- "${good[@]}"); rc=$?
[ "$rc" -eq 6 ] && ! grep -Eq '^(run|file) ' "$calls"; check "worktree path exists: exit 6, nothing started" $?
reset; mkdir -p "$tmp/elsewhere" "$workers"; ln -s "$tmp/elsewhere" "$workers/t1"
out=$(run -- "${good[@]}"); rc=$?
[ "$rc" -eq 6 ] && ! grep -Eq '^(run|file) ' "$calls" && [ -z "$(ls -A "$tmp/elsewhere")" ]
check "a symlink at the worktree path is refused (exit 6) and nothing is written through it" $?
reset; mkdir -p "$tmp/real-workers"; ln -s "$tmp/real-workers" "$tmp/link-workers"
out=$(run PADDOCK_WORKERS_DIR="$tmp/link-workers" -- "${good[@]}"); rc=$?
[ "$rc" -eq 0 ] && [ -d "$tmp/real-workers/t1" ]; check "a workers folder that is itself a symlink is allowed" $?

# Settings path safety: a base whose tree has a .claude symlink or a tracked settings.local.json.
git="git -C $proj -c user.name=t -c user.email=t@t.invalid"
$git checkout -q -b weird-base main
mkdir -p "$tmp/elsewhere2"; ln -s "$tmp/elsewhere2" "$proj/.claude"
$git add .claude; $git commit -q -m "tracked symlink"
$git checkout -q main
$git checkout -q -b tracked-base main
mkdir -p "$proj/.claude"; echo '{"tracked":true}' > "$proj/.claude/settings.local.json"
$git add -f .claude/settings.local.json; $git commit -q -m "tracked settings"
$git checkout -q main
reset; out=$(run -- "${good[@]}" --base weird-base); rc=$?
[ "$rc" -eq 6 ] && ! grep -Eq '^(file|run) ' "$calls" && [ -z "$(ls -A "$tmp/elsewhere2")" ] && [ ! -e "$workers/t1" ]
check ".claude is a symlink in the base: exit 6, nothing written through it, worktree removed" $?
reset; out=$(run -- "${good[@]}" --base tracked-base); rc=$?
[ "$rc" -eq 6 ] && ! grep -Eq '^(file|run) ' "$calls" && [ ! -e "$workers/t1" ] \
  && [ "$(git -C "$proj" show tracked-base:.claude/settings.local.json)" = '{"tracked":true}' ]
check "a tracked settings.local.json is refused, never overwritten: exit 6, worktree removed" $?

# Failures. The worktree and branch are removed only when no worker can exist.
gone() { [ ! -e "$workers/t1" ] && ! git -C "$proj" rev-parse -q --verify work/t1 >/dev/null; }
blocked_t1() { PADDOCK_STATE_DIR="$tmp/state" PADDOCK_NOW=2026-11-10T01:09:05Z bash "$org" --as secretary list_runs \
  | grep -Eq '^t1[[:space:]]+secretary[[:space:]]+blocked'; }
reset; out=$(run STUB_WRITE_FAIL=1 -- "${good[@]}"); rc=$?
[ "$rc" -eq 5 ] && ! grep -q '^run ' "$calls" && gone; check "settings write fails: exit 5, no run, worktree and branch removed" $?
! ls "$tmp/state"/events/*/secretary.jsonl >/dev/null 2>&1; check "that failure happens before the record, so nothing was recorded" $?
reset; out=$(run STUB_RUN_FAIL=1 -- "${good[@]}"); rc=$?
[ "$rc" -eq 5 ] && gone; check "hc run fails and no terminal exists: exit 5, worktree and branch removed" $?
blocked_t1; check "that failure is recorded as blocked too" $?
out=$(run -- "${good[@]}"); rc=$?
[ "$rc" -eq 0 ]; check "after a cleaned-up failure the same task id can be delegated" $?
reset; out=$(run STUB_RUN_FAIL_AFTER=1 -- "${good[@]}"); rc=$?
[ "$rc" -eq 5 ] && [ -d "$workers/t1" ] && git -C "$proj" rev-parse -q --verify work/t1 >/dev/null && [ -f "$tmp/stub/term-w-t1" ] \
  && ! grep -Eq '^(kill|rm) ' "$calls" && grep -q "$workers/t1" <<<"$out" && grep -q 'work/t1' <<<"$out" && grep -q 'w-t1' <<<"$out"
check "hc run fails but the terminal exists: kept, and the worktree, branch and terminal are named" $?
reset; out=$(run STUB_RUN_FAIL=1 STUB_LOCK=1 -- "${good[@]}"); rc=$?
[ "$rc" -eq 5 ] && [ -d "$workers/t1" ] && grep -q "$workers/t1" <<<"$out" && grep -qi 'left' <<<"$out"
check "the undo itself fails: exit 5 and the worktree left behind is named" $?
git -C "$proj" worktree unlock "$workers/t1" 2>/dev/null

# The first message was not delivered, or the answer is unusable: the worker is left, no keys.
for v in "STUB_FIRST_SENT=false" "STUB_RUN_OUT=not json at all" 'STUB_RUN_OUT={"first_message":{"started":true}}'; do
  reset; out=$(run "$v" -- "${good[@]}"); rc=$?
  [ "$rc" -eq 10 ] && [ -d "$workers/t1" ] && [ -f "$tmp/stub/term-w-t1" ] && ! grep -Eq '^(send|keys|kill|rm) ' "$calls"
  check "exit 10, worktree and terminal kept, no keys, no kill: $v" $?
done
reset; out=$(run STUB_FIRST_SENT=false -- "${good[@]}"); rc=$?
grep -q 'sent' <<<"$out" && grep -qi 'trust' <<<"$out"; check "exit 10 prints the result and points at the trusted folder" $?
blocked_t1; check "exit 10 leaves a blocked record" $?
out=$(run -- "${good[@]}"); rc=$?
[ "$rc" -eq 7 ]; check "rerun after exit 10 with the same id is refused (terminal still there)" $?

# Issue #260: the folder-trust dialog (the policy list) is answered after a screen read, and the
# brief is sent again; nothing else is typed.
reset; out=$(run STUB_FIRST_SENT=false STUB_TRUST=1 -- "${good[@]}"); rc=$?
[ "$rc" -eq 0 ] && grep -q '^keys w-t1 down' "$calls" && grep -q '^keys w-t1 enter' "$calls" \
  && grep -q '^send w-t1 You are a worker of a paddock organization' "$calls" && grep -q '^Your org id is w-t1' "$calls" \
  && ! grep -Eq '^(kill|rm) ' "$calls"
check "folder-trust at launch: down, enter, the template body and the brief sent again, exit 0" $?

# The start record cannot be written: nothing is started, the worktree is removed (exit 12).
if [ "$(id -u)" -eq 0 ]; then echo "skip record failure (running as root)"; else
  reset; mkdir -p "$tmp/state"; : > "$tmp/state/events"   # a file where the events folder must be
  out=$(run -- "${good[@]}"); rc=$?
  [ "$rc" -eq 12 ] && ! grep -q '^run ' "$calls" && gone; check "the record fails: exit 12, nothing started, worktree and branch removed" $?
fi

exit $fail
