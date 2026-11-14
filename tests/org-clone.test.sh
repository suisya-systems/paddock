#!/usr/bin/env bash
# Acceptance test for Issue #362 (decision 0011): skills/org-clone/scripts/org-clone.sh clones the repository a
# request names into PADDOCK_PROJECTS_DIR/<owner>/<name> through a .partial folder, registers it in projects.md,
# and records nothing on any failure. Needs only bash, coreutils and git (the GitHub CLI is a stub; no network, no hc).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-clone/scripts/org-clone.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

g() { git -c user.name=t -c user.email=t@t.invalid "$@"; }
# The "remote": o/r has default branch trunk (not main); o/plain has main.
mkremote() { # mkremote <owner/name> <branch>
  mkdir -p "$tmp/remote/$1.git"; g init -q --bare -b "$2" "$tmp/remote/$1.git" 2>/dev/null || g init -q --bare "$tmp/remote/$1.git"
  g init -q -b "$2" "$tmp/seed" 2>/dev/null || g init -q "$tmp/seed"
  g -C "$tmp/seed" checkout -q -B "$2"; g -C "$tmp/seed" commit -q --allow-empty -m init
  g -C "$tmp/seed" push -q "$tmp/remote/$1.git" "$2" 2>/dev/null; command rm -rf "$tmp/seed"
  g -C "$tmp/remote/$1.git" symbolic-ref HEAD "refs/heads/$2"
}
mkremote o/r trunk
mkremote o/plain main

# Stub of the GitHub CLI: `<cli> repo clone OWNER/NAME DEST`. $STUB/cli-fail holds the message printed on failure.
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
chmod +x "$tmp/bin/$cli"
export PADDOCK_PROJECTS_DIR=$tmp/pp PADDOCK_PROJECTS_FILE=$tmp/projects.md
unset PADDOCK_ORG_ID
run() { : > "$STUB/calls"; PATH="$tmp/bin:$PATH" bash "$script" "$@" >"$STUB/out" 2>"$STUB/err"; echo $?; }
reset() { command rm -rf "$tmp/pp" "$tmp/projects.md" "$STUB/cli-fail"; }
row() { grep -c "^| $1 |" "$tmp/projects.md" 2>/dev/null; }

# 1. Argument shapes: exit 2 before any network call; a bare name is asked back as OWNER/NAME.
reset
for bad in "" r "o/" "/r" "o/r/x" "https://gitlab.com/o/r" "git@gitlab.com:o/r.git" "o r/x" "../x/y" "o/.." ; do
  rc=$(run "$bad"); [ "$rc" = 2 ] && [ ! -s "$STUB/calls" ] && [ ! -e "$tmp/pp" ]; check "bad shape '$bad': exit 2, no clone call, nothing made ($rc)" $?
done
rc=$(run r); grep -q 'OWNER/NAME' "$STUB/err"; check "a bare name is asked back as OWNER/NAME" $?
rc=$(PADDOCK_PROJECTS_DIR=rel run o/r); [ "$rc" = 2 ] && [ ! -s "$STUB/calls" ]; check "a relative PADDOCK_PROJECTS_DIR exits 2 (like PADDOCK_WORKERS_DIR)" $?

# 2. Success: path, partial renamed, row with base from origin/HEAD, name on stdout, trust marker.
reset
rc=$(run o/r)
[ "$rc" = 0 ]; check "o/r clones (exit $rc)" $?
[ "$(cat "$STUB/out")" = r ]; check "stdout is the projects.md name only" $?
[ -d "$tmp/pp/o/r/.git" ] && [ ! -e "$tmp/pp/o/.r.partial" ]; check "cloned into <dir>/o/r, the .partial folder is gone" $?
grep -q "^| r | $tmp/pp/o/r | trunk |" "$tmp/projects.md"; check "row: name, path, base from origin/HEAD (trunk)" $?
grep -q 'repo clone o/r ' "$STUB/calls" && grep -q '/\.r\.partial$' "$STUB/calls"; check "the clone goes into the .partial folder" $?
ls "$tmp/pp/o/r/.git" | grep -q paddock-trust-pending; check "a fresh clone carries the trust-pending marker" $?
grep -q 'trust' "$STUB/err"; check "stderr tells the secretary to ask the person (trust card) first" $?

# 3. The same repository again, by any spelling: no second clone, the recorded name, exit 0.
for again in o/r https://github.com/o/r https://github.com/o/r.git git@github.com:o/r.git O/R; do
  rc=$(run "$again"); [ "$rc" = 0 ] && [ "$(cat "$STUB/out")" = r ] && [ ! -s "$STUB/calls" ] && [ "$(row r)" = 1 ]; check "recorded origin skips the clone: $again ($rc)" $?
done
grep -q 'already' "$STUB/err"; check "stderr says it is already recorded" $?

# 4. URL forms clone like OWNER/NAME; base falls back to main.
reset
rc=$(run https://github.com/o/plain.git); [ "$rc" = 0 ] && grep -q "^| plain | $tmp/pp/o/plain | main |" "$tmp/projects.md"; check "https URL with .git: row plain, base main ($rc)" $?
reset
rc=$(run git@github.com:o/plain.git); [ "$rc" = 0 ] && [ -d "$tmp/pp/o/plain/.git" ]; check "ssh URL clones into o/plain ($rc)" $?

# 5. Failure: nothing registered, no partial, exit codes by reason, no retry.
reset; echo "GraphQL: Could not resolve to a Repository with the name 'o/r'. (repository not found)" > "$STUB/cli-fail"
rc=$(run o/r); [ "$rc" = 4 ] && [ ! -e "$tmp/pp/o/.r.partial" ] && [ ! -e "$tmp/pp/o/r" ] && [ ! -e "$tmp/projects.md" ]; check "not found or no access: exit 4, nothing left, nothing recorded ($rc)" $?
[ "$(grep -c 'repo clone' "$STUB/calls")" = 1 ]; check "no retry" $?
reset; echo "fatal: could not read Username for 'https://github.com': terminal prompts disabled" > "$STUB/cli-fail"
rc=$(run o/r); [ "$rc" = 4 ]; check "no credential: exit 4 ($rc)" $?
reset; echo "fatal: unable to access 'https://github.com/o/r.git/': Could not resolve host: github.com" > "$STUB/cli-fail"
rc=$(run o/r); [ "$rc" = 5 ] && [ ! -e "$tmp/pp/o/.r.partial" ] && [ ! -e "$tmp/projects.md" ]; check "network: exit 5, nothing left, nothing recorded ($rc)" $?
grep -q 'Could not resolve host' "$STUB/err"; check "the cause is on stderr" $?

# 6. A target that exists and is not a clone of that origin is never reused or overwritten (exit 6).
reset; mkdir -p "$tmp/pp/o/r"; echo mine > "$tmp/pp/o/r/file"
rc=$(run o/r); [ "$rc" = 6 ] && [ "$(cat "$tmp/pp/o/r/file")" = mine ] && [ ! -s "$STUB/calls" ] && [ ! -e "$tmp/projects.md" ]; check "plain folder in the way: exit 6, untouched, no clone ($rc)" $?
reset; mkdir -p "$tmp/pp/o"; g init -q "$tmp/pp/o/r"
g -C "$tmp/pp/o/r" remote add origin https://github.com/other/r.git
rc=$(run o/r); [ "$rc" = 6 ] && [ ! -e "$tmp/projects.md" ]; check "a clone of another origin in the way: exit 6 ($rc)" $?
# ... but a clone of the same origin that is not recorded yet is registered, not cloned again.
reset; mkdir -p "$tmp/pp/o"; git clone -q "$tmp/remote/o/r.git" "$tmp/pp/o/r"; git -C "$tmp/pp/o/r" remote set-url origin https://github.com/o/r.git
rc=$(run o/r); [ "$rc" = 0 ] && [ ! -s "$STUB/calls" ] && [ "$(row r)" = 1 ]; check "same-origin clone not yet recorded: registered, no second clone ($rc)" $?

# 7. NAME already names a different row: stop, never overwrite (exit 7).
reset; printf '| name | path | base |\n| --- | --- | --- |\n| r | /elsewhere/r | main |\n' > "$tmp/projects.md"
cp "$tmp/projects.md" "$tmp/projects.before"
rc=$(run o/r); cmp -s "$tmp/projects.md" "$tmp/projects.before" && [ "$rc" = 7 ] && [ ! -e "$tmp/pp/o/r" ] && [ ! -e "$tmp/pp/o/.r.partial" ]; check "name taken by another row: exit 7, row kept, nothing cloned or left ($rc)" $?
grep -q 'name' "$STUB/err"; check "stderr asks the secretary to ask the person for a name" $?

# 8. The row is added beside existing rows; the other rows are untouched.
reset; printf '| name | path | base |\n| --- | --- | --- |\n| app | /x/app | dev |\n' > "$tmp/projects.md"
rc=$(run o/plain); [ "$rc" = 0 ] && grep -qx '| app | /x/app | dev |' "$tmp/projects.md" && [ "$(row plain)" = 1 ]; check "existing rows kept, new row added ($rc)" $?

# 9. No GitHub CLI on PATH: a plain git clone of https://github.com/OWNER/NAME.git.
reset
mkdir -p "$tmp/nocli"; for t in bash git sh awk sed grep tr mkdir mv rm cat dirname basename head cut sort date mktemp ls cp; do p=$(command -v $t) && ln -sf "$p" "$tmp/nocli/$t"; done
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$tmp/remote/o/r.git.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/o/r.git
PATH="$tmp/nocli" bash "$script" o/r >"$STUB/out" 2>"$STUB/err"; rc=$?
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
[ "$rc" = 0 ] && [ -d "$tmp/pp/o/r/.git" ] && grep -q "^| r | $tmp/pp/o/r | trunk |" "$tmp/projects.md"; check "no CLI on PATH: falls back to git clone ($rc)" $?
exit $fail
