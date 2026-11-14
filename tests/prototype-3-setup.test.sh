#!/usr/bin/env bash
# Issue #267: one named command prepares a prototype host (the throwaway clone, a clean paddock clone,
# the workers folder) and says exactly what a person must still do.
# Uses stub gh and local bare repositories; no network, no core.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here" || exit 1
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
S=$here/scripts/probes/prototype-3-setup.sh
tmp=$(mktemp -d) || exit 1; trap 'rm -rf "$tmp"' EXIT

[ -f "$S" ]; check "the setup command exists" $?
sh -n "$S" 2>/dev/null; check "parses" $?
out=$(sh "$S" --help 2>&1); [ $? -eq 0 ] && ! grep -qi 'token' <<<"$out"; check "--help names no token (Q20 decision D)" $?
! LC_ALL=C grep -q '[^ -~]' <<<"$out"; check "--help is ASCII" $?

# Local stand-ins for the two GitHub repositories, and a gh that clones from them.
git_() { git -c user.name=t -c user.email=t@example.com "$@"; }
for r in throwaway paddock; do
  git init -q --bare -b main "$tmp/$r.git"
  git init -q -b main "$tmp/seed-$r" && : > "$tmp/seed-$r/f" && git_ -C "$tmp/seed-$r" add f \
    && git_ -C "$tmp/seed-$r" commit -qm one && git_ -C "$tmp/seed-$r" push -q "$tmp/$r.git" main
done
mkdir -p "$tmp/bin" "$tmp/home"
cat > "$tmp/bin/gh" <<'EOF'
#!/bin/sh
if [ "$1" = api ]; then # Issue #286: serves the file the way the contents API does
  echo "$2" >> "$STUB_GH_LOG"; cat "$STUB_SETUP_SRC"; exit 0
fi
[ "$1 $2" = "repo clone" ] || exit 9
echo "$3" >> "$STUB_GH_LOG"
exec git clone -q "$STUB_THROWAWAY" "$4"
EOF
chmod +x "$tmp/bin/gh"
run() { # run <args...>: a clean host environment
  env -u CLAUDE_CONFIG_DIR -u APPDATA -u XDG_CONFIG_HOME \
    HOME="$tmp/home" PATH="$tmp/bin:$PATH" STUB_GH_LOG="$tmp/gh.log" STUB_THROWAWAY="$tmp/throwaway.git" \
    PADDOCK_REPO_URL="$tmp/paddock.git" PADDOCK_WORKERS_DIR="$tmp/workers" \
    sh "$S" "$@" </dev/null 2>&1
}

# Refusals come first and touch nothing.
run --project "$tmp/p" --paddock "$tmp/c" >/dev/null; [ $? -eq 2 ]; check "no --repo exits 2" $?
run --repo nobody --project "$tmp/p" --paddock "$tmp/c" >/dev/null; [ $? -eq 2 ]; check "--repo without a slash exits 2" $?
run --repo Suisya-Systems/Paddock --project "$tmp/p" --paddock "$tmp/c" >/dev/null; [ $? -eq 6 ]; check "this repository is refused, any case" $?
[ ! -e "$tmp/p" ] && [ ! -e "$tmp/c" ] && [ ! -e "$tmp/workers" ]; check "a refusal creates nothing" $?

# First run: everything made, the folder trust is the person's.
out=$(run --repo Acme/Throwaway --project "$tmp/p" --paddock "$tmp/c"); rc=$?
[ $rc -eq 1 ]; check "first run exits 1 (a person step remains)" $?
git -C "$tmp/p" rev-parse --git-dir >/dev/null 2>&1 && grep -qx 'acme/throwaway' <(tr 'A-Z' 'a-z' < "$tmp/gh.log"); check "the throwaway repository is cloned with gh" $?
[ "$(git -C "$tmp/c" rev-parse HEAD)" = "$(git -C "$tmp/c" rev-parse origin/main)" ] && [ -z "$(git -C "$tmp/c" status --porcelain)" ]; check "paddock is cloned, clean, at origin/main" $?
[ -d "$tmp/workers" ]; check "the workers folder is made" $?
! grep -qi 'token' <<<"$out"; check "no token step is printed" $?
grep -q 'I trust this folder' <<<"$out" && grep -q "$tmp/p" <<<"$out"; check "the trust step names the clone and the dialog answer" $?
grep -q "$tmp/c" <<<"$out" && grep -q 'prototype-3.sh prepare' <<<"$out"; check "the next step is prepare, run from the clean clone" $?

# The token option is gone.
run --repo Acme/Throwaway --project "$tmp/p" --paddock "$tmp/c" --token-stdin >/dev/null; [ $? -eq 2 ]; check "--token-stdin is an unknown option (exit 2)" $?

# Trust follows the repository (Q13): a trusted folder above the clone does not count.
printf '{"projects":{"%s":{"allowedTools":[],"hasTrustDialogAccepted":true}}}\n' "$tmp" > "$tmp/home/.claude.json"
out=$(run --repo Acme/Throwaway --project "$tmp/p" --paddock "$tmp/c"); rc=$?
[ $rc -eq 1 ] && grep -q 'TODO folder-trust' <<<"$out"; check "a trusted folder above the clone is not enough: exit 1" $?
# The clone itself trusted: nothing left to do; a rerun updates the clean clone.
printf '{"projects":{"%s":{"allowedTools":[],"hasTrustDialogAccepted":true}}}\n' "$tmp/p" > "$tmp/home/.claude.json"
git_ -C "$tmp/seed-paddock" commit -q --allow-empty -m two && git_ -C "$tmp/seed-paddock" push -q "$tmp/paddock.git" main
out=$(run --repo Acme/Throwaway --project "$tmp/p" --paddock "$tmp/c"); rc=$?
[ $rc -eq 0 ]; check "the clone trusted: exit 0" $?
[ "$(git -C "$tmp/c" rev-parse HEAD)" = "$(git -C "$tmp/paddock.git" rev-parse main)" ]; check "a rerun fast-forwards the clean clone" $?
echo x > "$tmp/c/dirty"
run --repo Acme/Throwaway --project "$tmp/p" --paddock "$tmp/c" >/dev/null; [ $? -eq 6 ]; check "a dirty paddock clone exits 6" $?

# A clean clone ahead of origin/main would fail prepare: refused. A relative --project is printed absolute.
rm -f "$tmp/c/dirty"; git_ -C "$tmp/c" commit -q --allow-empty -m local
run --repo Acme/Throwaway --project "$tmp/p" --paddock "$tmp/c" >/dev/null; [ $? -eq 6 ]; check "a clone ahead of origin/main exits 6" $?
git_ -C "$tmp/c" reset -q --hard origin/main
out=$(cd "$tmp" && run --repo Acme/Throwaway --project p --paddock "$tmp/c"); grep -q "^next: .*--project '$tmp/p'" <<<"$out"; check "a relative --project is printed absolute" $?

# prepare points at the setup command instead of leaving the person to work it out.
grep -q 'prototype-3-setup.sh' scripts/probes/prototype-3.sh; check "prepare names the setup command" $?

# Issue #286: a stale clone has no setup command. The runbook gives an entry point that does not
# live in the clone: fetch the script from origin/main with gh, then run that copy.
D=docs/design/prototype-3.md
fetch=$(grep -m1 '^gh api repos/suisya-systems/paddock/contents/scripts/probes/prototype-3-setup.sh ' "$D")
[ -n "$fetch" ]; check "the runbook has a fetch command for the setup script" $?
[ -n "$fetch" ] && grep -B3 -A3 -F "$fetch" "$D" | grep -qi 'stale\|older\|outside'; check "the runbook says it is for a clone without the script" $?
mkdir -p "$tmp/elsewhere" "$tmp/home2"
(cd "$tmp/elsewhere" && env HOME="$tmp/home2" PATH="$tmp/bin:$PATH" STUB_GH_LOG="$tmp/gh2.log" STUB_SETUP_SRC="$S" sh -c "$fetch") >/dev/null 2>&1
[ -s "$tmp/home2/prototype-3-setup.sh" ] && sh -n "$tmp/home2/prototype-3-setup.sh"; check "the fetch command saves a parseable script outside any clone" $?
out=$(cd "$tmp/elsewhere" && env -u CLAUDE_CONFIG_DIR -u APPDATA -u XDG_CONFIG_HOME \
  HOME="$tmp/home2" PATH="$tmp/bin:$PATH" STUB_GH_LOG="$tmp/gh2.log" STUB_THROWAWAY="$tmp/throwaway.git" \
  PADDOCK_REPO_URL="$tmp/paddock.git" PADDOCK_WORKERS_DIR="$tmp/workers2" \
  sh "$tmp/home2/prototype-3-setup.sh" --repo Acme/Throwaway --project "$tmp/p4" --paddock "$tmp/c4" </dev/null 2>&1)
[ -d "$tmp/c4/.git" ] && grep -q '^next: ' <<<"$out"; check "the fetched copy runs from outside and sets up the clean clone" $?
exit $fail
