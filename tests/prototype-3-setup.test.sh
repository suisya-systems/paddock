#!/usr/bin/env bash
# Issue #267: one named command prepares a prototype host (the throwaway clone, a clean paddock clone,
# the workers folder, the read-only worker token) and says exactly what a person must still do.
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
out=$(sh "$S" --help 2>&1); [ $? -eq 0 ] && grep -q -- '--token-stdin' <<<"$out"; check "--help names --token-stdin" $?
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
[ "$1 $2" = "repo clone" ] || exit 9
echo "$3" >> "$STUB_GH_LOG"
exec git clone -q "$STUB_THROWAWAY" "$4"
EOF
chmod +x "$tmp/bin/gh"
run() { # run <args...>: a clean host environment
  env -u CLAUDE_CONFIG_DIR -u APPDATA -u XDG_CONFIG_HOME \
    PADDOCK_WORKER_GH_TOKEN_FILE="${TOKF:-$tmp/home/.config/paddock/worker-gh-token}" \
    HOME="$tmp/home" PATH="$tmp/bin:$PATH" STUB_GH_LOG="$tmp/gh.log" STUB_THROWAWAY="$tmp/throwaway.git" \
    PADDOCK_REPO_URL="$tmp/paddock.git" PADDOCK_WORKERS_DIR="$tmp/workers" \
    sh "$S" "$@" </dev/null 2>&1
}

# Refusals come first and touch nothing.
run --project "$tmp/p" --paddock "$tmp/c" >/dev/null; [ $? -eq 2 ]; check "no --repo exits 2" $?
run --repo nobody --project "$tmp/p" --paddock "$tmp/c" >/dev/null; [ $? -eq 2 ]; check "--repo without a slash exits 2" $?
run --repo Suisya-Systems/Paddock --project "$tmp/p" --paddock "$tmp/c" >/dev/null; [ $? -eq 6 ]; check "this repository is refused, any case" $?
[ ! -e "$tmp/p" ] && [ ! -e "$tmp/c" ] && [ ! -e "$tmp/workers" ]; check "a refusal creates nothing" $?

# First run: everything made, the token and the folder trust are the person's.
out=$(run --repo Acme/Throwaway --project "$tmp/p" --paddock "$tmp/c"); rc=$?
[ $rc -eq 1 ]; check "first run exits 1 (a person step remains)" $?
git -C "$tmp/p" rev-parse --git-dir >/dev/null 2>&1 && grep -qx 'acme/throwaway' <(tr 'A-Z' 'a-z' < "$tmp/gh.log"); check "the throwaway repository is cloned with gh" $?
[ "$(git -C "$tmp/c" rev-parse HEAD)" = "$(git -C "$tmp/c" rev-parse origin/main)" ] && [ -z "$(git -C "$tmp/c" status --porcelain)" ]; check "paddock is cloned, clean, at origin/main" $?
[ -d "$tmp/workers" ]; check "the workers folder is made" $?
grep -q 'https://github.com/settings/personal-access-tokens/new?' <<<"$out" \
  && grep -q 'target_name=Acme\|target_name=acme' <<<"$out" && grep -q 'contents=read' <<<"$out"; check "the token URL pre-fills owner and contents=read" $?
grep -q -- '--token-stdin' <<<"$out" && grep -qi 'only select repositories' <<<"$out"; check "the token step says how to save it and to select the repository" $?
grep -q 'I trust this folder' <<<"$out" && grep -q "$tmp/p" <<<"$out"; check "the trust step names the clone and the dialog answer" $?
grep -q "$tmp/c" <<<"$out" && grep -q 'prototype-3.sh prepare' <<<"$out"; check "the next step is prepare, run from the clean clone" $?

# The token comes on stdin and is written 0600; its value is never printed.
printf 'ghp_secretvalue\n' | env -u CLAUDE_CONFIG_DIR -u APPDATA -u XDG_CONFIG_HOME -u PADDOCK_WORKER_GH_TOKEN_FILE \
  HOME="$tmp/home" PATH="$tmp/bin:$PATH" STUB_GH_LOG="$tmp/gh.log" STUB_THROWAWAY="$tmp/throwaway.git" \
  PADDOCK_REPO_URL="$tmp/paddock.git" PADDOCK_WORKERS_DIR="$tmp/workers" \
  sh "$S" --repo Acme/Throwaway --project "$tmp/p" --paddock "$tmp/c" --token-stdin >"$tmp/out2" 2>&1
tf="$tmp/home/.config/paddock/worker-gh-token"
[ "$(cat "$tf" 2>/dev/null)" = ghp_secretvalue ]; check "the token is saved where org-start looks" $?
[ "$(stat -c %a "$tf" 2>/dev/null)" = 600 ]; check "the token file is mode 600" $?
! grep -q ghp_secretvalue "$tmp/out2"; check "the token value is never printed" $?
rm -f "$tf"
: | env HOME="$tmp/home" PATH="$tmp/bin:$PATH" STUB_THROWAWAY="$tmp/throwaway.git" PADDOCK_REPO_URL="$tmp/paddock.git" \
  PADDOCK_WORKERS_DIR="$tmp/workers" sh "$S" --repo Acme/Throwaway --project "$tmp/p" --paddock "$tmp/c" --token-stdin >/dev/null 2>&1
rc=$?; [ $rc -eq 6 ] && [ ! -e "$tf" ]; check "an empty stdin exits 6 and writes no file" $?

# Trust follows the repository (Q13): a trusted folder above the clone does not count.
printf 'ghp_secretvalue\n' > "$tmp/tok"
printf '{"projects":{"%s":{"allowedTools":[],"hasTrustDialogAccepted":true}}}\n' "$tmp" > "$tmp/home/.claude.json"
out=$(TOKF="$tmp/tok" run --repo Acme/Throwaway --project "$tmp/p" --paddock "$tmp/c"); rc=$?
[ $rc -eq 1 ] && grep -q 'TODO folder-trust' <<<"$out"; check "a trusted folder above the clone is not enough: exit 1" $?
# The clone itself trusted: nothing left to do; a rerun updates the clean clone.
printf '{"projects":{"%s":{"allowedTools":[],"hasTrustDialogAccepted":true}}}\n' "$tmp/p" > "$tmp/home/.claude.json"
git_ -C "$tmp/seed-paddock" commit -q --allow-empty -m two && git_ -C "$tmp/seed-paddock" push -q "$tmp/paddock.git" main
out=$(TOKF="$tmp/tok" run --repo Acme/Throwaway --project "$tmp/p" --paddock "$tmp/c"); rc=$?
[ $rc -eq 0 ]; check "token present and the clone trusted: exit 0" $?
[ "$(git -C "$tmp/c" rev-parse HEAD)" = "$(git -C "$tmp/paddock.git" rev-parse main)" ]; check "a rerun fast-forwards the clean clone" $?
echo x > "$tmp/c/dirty"
TOKF="$tmp/tok" run --repo Acme/Throwaway --project "$tmp/p" --paddock "$tmp/c" >/dev/null; [ $? -eq 6 ]; check "a dirty paddock clone exits 6" $?

# A clean clone ahead of origin/main would fail prepare: refused. A relative --project is printed absolute.
rm -f "$tmp/c/dirty"; git_ -C "$tmp/c" commit -q --allow-empty -m local
TOKF="$tmp/tok" run --repo Acme/Throwaway --project "$tmp/p" --paddock "$tmp/c" >/dev/null; [ $? -eq 6 ]; check "a clone ahead of origin/main exits 6" $?
git_ -C "$tmp/c" reset -q --hard origin/main
out=$(cd "$tmp" && TOKF="$tmp/tok" run --repo Acme/Throwaway --project p --paddock "$tmp/c"); grep -q "^next: .*--project '$tmp/p'" <<<"$out"; check "a relative --project is printed absolute" $?

# prepare points at the setup command instead of leaving the person to work it out.
grep -q 'prototype-3-setup.sh' scripts/probes/prototype-3.sh; check "prepare names the setup command" $?
exit $fail
