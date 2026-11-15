#!/usr/bin/env bash
# Decision 0014, wave 2 unit 3: `org-delegate --repo OWNER/NAME` clones the repository when it is not on the
# machine (through org-clone), then delegates into the clone; and every non-zero exit of org-delegate and
# org-clone ends with one line `next: <action>` or `next: ask the person: <question>`.
# No network, no core: hc and the GitHub CLI are stubs on PATH, the remote is a local bare repository.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dg=$here/skills/org-delegate/scripts/org-delegate.sh
cl=$here/skills/org-clone/scripts/org-clone.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
g() { git -c user.name=t -c user.email=t@t.invalid "$@"; }

# The remote o/r (default branch trunk).
mkdir -p "$tmp/remote/o/r.git"; g init -q --bare -b trunk "$tmp/remote/o/r.git" 2>/dev/null || g init -q --bare "$tmp/remote/o/r.git"
g init -q -b trunk "$tmp/seed" 2>/dev/null || g init -q "$tmp/seed"
g -C "$tmp/seed" checkout -q -B trunk; g -C "$tmp/seed" commit -q --allow-empty -m init
g -C "$tmp/seed" push -q "$tmp/remote/o/r.git" trunk 2>/dev/null; command rm -rf "$tmp/seed"
g -C "$tmp/remote/o/r.git" symbolic-ref HEAD refs/heads/trunk

export STUB=$tmp/s; mkdir -p "$STUB" "$tmp/bin"
cli=g''h
cat > "$tmp/bin/$cli" <<'S'
#!/bin/sh
echo "cli $*" >> "$STUB/calls"
[ "$1 $2" = "repo clone" ] || exit 64
if [ -f "$STUB/cli-fail" ]; then cat "$STUB/cli-fail" >&2; mkdir -p "$4"; exit 1; fi
git clone -q "$STUB/../remote/$3.git" "$4" 2>/dev/null || { echo "GraphQL: Could not resolve to a Repository with the name '$3'." >&2; exit 1; }
git -C "$4" remote set-url origin "https://github.com/$3.git"
S
cat > "$tmp/bin/hc" <<'S'
#!/bin/sh
echo "hc $*" >> "$STUB/calls"
cmd=$1; shift
case "$cmd" in
  ls) [ -z "${STUB_LS_FAIL:-}" ] || exit 1; echo '[]' ;;
  get) name=; for a in "$@"; do case "$a" in --*) ;; *) name=$a ;; esac; done
       [ -f "$STUB/term-$name" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       echo "{\"name\":\"$name\",\"state\":\"live\"}" ;;
  file) shift; path=; for a in "$@"; do case "$a" in --*) ;; *) path=$a ;; esac; done
        mkdir -p "$(dirname "$path")" && cat > "$path"; echo '{"written":true}' ;;
  run) tname=; prev=; for a in "$@"; do [ "$prev" != --name ] || tname=$a; prev=$a; done
       : > "$STUB/term-$tname"
       echo "{\"first_message\":{\"sent\":${STUB_FIRST_SENT:-true},\"started\":true,\"turn\":0}}" ;;
esac
exit 0
S
chmod +x "$tmp/bin/$cli" "$tmp/bin/hc"

export PADDOCK_PROJECTS_DIR=$tmp/pp PADDOCK_PROJECTS_FILE=$tmp/projects.md PADDOCK_WORKERS_DIR=$tmp/workers \
  PADDOCK_STATE_DIR=$tmp/state PADDOCK_CORE_SOCKET_DIR=$tmp/run/herdr-core PADDOCK_NOW=2026-11-16T01:02:03Z
unset PADDOCK_ORG_ID HC_TERMINAL_SOCKET
reset() { command rm -rf "$tmp/pp" "$tmp/projects.md" "$tmp/workers" "$tmp/state" "$STUB/cli-fail" "$STUB"/term-*; : > "$STUB/calls"; }
run() { PATH="$tmp/bin:$PATH" bash "$@" >"$STUB/out" 2>&1; echo $?; } # run <script> <args>: the exit code; output in $STUB/out
lastnext() { tail -n 1 "$STUB/out" | grep -Eq '^next: .+'; }
clones() { grep -c '^cli repo clone' "$STUB/calls"; }
runs() { grep -c '^hc run' "$STUB/calls"; }

# 1. --repo on a machine that does not have it: clone, register, delegate into the clone.
reset
rc=$(run "$dg" --repo o/r --task-id t1 --task "Do it." --no-fetch)
[ "$rc" = 0 ]; s=$?; check "--repo o/r clones and delegates (exit $rc: $(tail -n 2 "$STUB/out" | tr '\n' ' '))" $s
[ "$(clones)" = 1 ] && [ -d "$tmp/pp/o/r/.git" ]; check "the repository was cloned once into PADDOCK_PROJECTS_DIR/o/r" $?
grep -q "^| r | $tmp/pp/o/r | trunk |" "$tmp/projects.md"; check "projects.md has the row, base from origin/HEAD" $?
[ "$(runs)" = 1 ] && grep -q "worker=w-t1 worktree=$tmp/workers/t1 branch=work/t1" "$STUB/out"; check "the worker started in a worktree of the clone" $?
[ "$(git -C "$tmp/workers/t1" rev-parse --abbrev-ref HEAD 2>/dev/null)" = work/t1 ]; check "the worktree is on work/t1" $?
[ "$rc" = 0 ] && grep -q 'trust' "$STUB/out"; check "the output tells the secretary the first worker stops at the folder-trust dialog (ask the person)" $?

# 2. --repo again: the clone is recorded, so no second clone.
rm -f "$STUB/term-w-t1"; : > "$STUB/calls"
rc=$(run "$dg" --repo o/r --task-id t2 --task "Do more." --no-fetch)
[ "$rc" = 0 ] && [ "$(clones)" = 0 ] && [ "$(runs)" = 1 ]; check "a recorded repository is not cloned again; the second delegate runs (exit $rc)" $?

# 3. --repo and --project together, or a bare name: exit 2 before anything is cloned or started.
reset
rc=$(run "$dg" --repo o/r --project "$tmp/pp/o/r" --task-id t1 --task t)
[ "$rc" = 2 ] && [ "$(clones)" = 0 ] && [ "$(runs)" = 0 ]; check "--repo with --project exits 2, nothing cloned or started" $?
lastnext; check "  and ends with a next: line" $?
rc=$(run "$dg" --repo r --task-id t1 --task t)
[ "$rc" = 2 ] && [ "$(clones)" = 0 ] && [ "$(runs)" = 0 ] && [ ! -e "$tmp/workers" ]; check "a bare name after --repo exits 2, nothing created" $?
tail -n 1 "$STUB/out" | grep -q '^next: ask the person: .*OWNER/NAME'; check "  and the next: line asks the person for OWNER/NAME" $?

# 4. The clone fails: the clone's exit code is the delegate's, nothing is started, one next: line ends the output.
reset
rc=$(run "$dg" --repo nope/x --task-id t1 --task t --no-fetch)
[ "$rc" = 4 ] && [ "$(runs)" = 0 ] && [ ! -e "$tmp/workers/t1" ]; check "no access or not found: exit 4 (org-clone's), no worker, no worktree ($rc)" $?
lastnext; check "  and ends with a next: line" $?
[ "$(grep -c '^next: ' "$STUB/out")" = 1 ]; check "  and holds exactly one next: line" $?
printf 'Could not resolve host: github.com\n' > "$STUB/cli-fail"
rc=$(run "$dg" --repo o/r --task-id t1 --task t --no-fetch)
[ "$rc" = 5 ] && [ "$(runs)" = 0 ] && lastnext; check "network failure while cloning: exit 5, no worker, next: line ($rc)" $?

# 5. Every non-zero exit of org-delegate ends with a next: line.
reset; proj=$tmp/project; git init -q -b main "$proj" 2>/dev/null || git init -q "$proj"; g -C "$proj" commit -q --allow-empty -m init
good=(--project "$proj" --task-id t1 --task t)
rc=$(run "$dg" --task-id t1 --task t); [ "$rc" = 2 ] && lastnext; check "exit 2 (no --project) ends with a next: line" $?
rc=$(env PATH="$tmp/empty" "$(command -v bash)" "$dg" "${good[@]}" >"$STUB/out" 2>&1; echo $?); [ "$rc" = 3 ] && lastnext; check "exit 3 (no hc or git) ends with a next: line" $?
rc=$(STUB_LS_FAIL=1 run "$dg" "${good[@]}"); [ "$rc" = 5 ] && lastnext; check "exit 5 (core unreachable) ends with a next: line" $?
rc=$(run "$dg" --project "$tmp/not-a-repo" --task-id t1 --task t); [ "$rc" = 6 ] && lastnext; check "exit 6 (not a git repository) ends with a next: line" $?
: > "$STUB/term-w-t1"; rc=$(run "$dg" "${good[@]}"); [ "$rc" = 7 ] && lastnext; check "exit 7 (terminal exists) ends with a next: line" $?
rm -f "$STUB/term-w-t1"
rc=$(STUB_FIRST_SENT=false run "$dg" "${good[@]}"); [ "$rc" = 10 ] && lastnext; check "exit 10 (first message not sent) ends with a next: line" $?
lastnext && tail -n 1 "$STUB/out" | grep -q 'hc read w-t1'; check "  and it says to read the screen with hc read w-t1" $?

# 6. Every non-zero exit of org-clone ends with a next: line.
reset
rc=$(run "$cl" r); [ "$rc" = 2 ] && lastnext; check "org-clone exit 2 (bare name) ends with a next: line" $?
tail -n 1 "$STUB/out" | grep -q '^next: ask the person: .*OWNER/NAME'; check "  and asks the person for OWNER/NAME" $?
rc=$(run "$cl" nope/x); [ "$rc" = 4 ] && lastnext; check "org-clone exit 4 (not found or no access) ends with a next: line" $?
printf 'Could not resolve host: github.com\n' > "$STUB/cli-fail"
rc=$(run "$cl" o/r); [ "$rc" = 5 ] && lastnext; check "org-clone exit 5 (network) ends with a next: line" $?
rm -f "$STUB/cli-fail"; mkdir -p "$tmp/pp/o/r"
rc=$(run "$cl" o/r); [ "$rc" = 6 ] && lastnext; check "org-clone exit 6 (a folder is in the way) ends with a next: line" $?
rmdir "$tmp/pp/o/r"
printf '| name | path | base |\n| --- | --- | --- |\n| r | /elsewhere | main |\n' > "$tmp/projects.md"
rc=$(run "$cl" o/r); [ "$rc" = 7 ] && lastnext; check "org-clone exit 7 (the name is taken) ends with a next: line" $?
tail -n 1 "$STUB/out" | grep -q '^next: ask the person: '; check "  and asks the person for another name" $?
rc=$(env PATH="$tmp/empty" "$(command -v bash)" "$cl" o/r >"$STUB/out" 2>&1; echo $?); [ "$rc" = 3 ] && lastnext; check "org-clone exit 3 (no git) ends with a next: line" $?

# 7. A success prints no next: line (it is the line of a failure).
reset
rc=$(run "$cl" o/r); [ "$rc" = 0 ] && ! grep -q '^next: ' "$STUB/out"; check "org-clone exit 0 prints no next: line" $?
exit $fail
