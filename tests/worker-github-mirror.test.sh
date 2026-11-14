#!/usr/bin/env bash
# Acceptance test for Issue #277 (Q20 decision D, the local mirror): a worker holds no GitHub credential.
# The template passes no GH_TOKEN and reads no token file, GH_CONFIG_DIR is still an empty folder, the person's
# own token variables do not reach the worker, org-start asks for no token, and a worker that needs a newer base
# is told to ask the secretary, who fetches in the project clone. Needs bash, coreutils and a stub claude.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tpl=$here/templates/worker.md
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
cmd=$(sed -n '2,${/^---[[:space:]]*$/q;p;}' "$tpl" | grep -m1 '^command:' | sed 's/^command:[[:space:]]*//;s/[[:space:]]*$//')
[ -n "$cmd" ]; check "the worker template has a command" $?

# 1. The command: no token, no token file; the empty GH_CONFIG_DIR stays.
! grep -Eq 'GH_TOKEN="|worker-gh-token|PADDOCK_WORKER_GH_TOKEN_FILE|\$tok' <<<"$cmd"; check "command sets no GH_TOKEN and reads no token file" $?
grep -q 'GH_CONFIG_DIR=' <<<"$cmd"; check "command still sets GH_CONFIG_DIR" $?
for v in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; do
  grep -q -- "-u $v" <<<"$cmd"; check "command removes the person's $v" $?
done

# 2. Run it with a stub claude, no token file anywhere, and the person's tokens in the environment.
stub=$tmp/bin; mkdir -p "$stub"
cat > "$stub/claude" <<'EOF2'
#!/bin/sh
{ for v in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_CONFIG_DIR; do eval "echo $v=\${$v-unset}"; done; } > "$CLAUDE_OUT"
EOF2
chmod +x "$stub/claude"
env -u APPDATA -u PADDOCK_WORKER_GH_TOKEN_FILE -u PADDOCK_BIN_DIR XDG_CONFIG_HOME="$tmp/cfg" XDG_DATA_HOME="$tmp/data" \
  PATH="$stub:$PATH" CLAUDE_OUT="$tmp/o1" GH_TOKEN=person-a GITHUB_TOKEN=person-b GH_ENTERPRISE_TOKEN=person-c GITHUB_ENTERPRISE_TOKEN=person-d \
  sh -c "$cmd" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ -f "$tmp/o1" ]; check "a worker starts with no token file" $?
for v in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; do
  grep -qx "$v=unset" "$tmp/o1"; check "$v does not reach claude" $?
done
gd=$(sed -n 's/^GH_CONFIG_DIR=//p' "$tmp/o1")
[ -n "$gd" ] && [ -d "$gd" ] && [ -z "$(ls -A "$gd")" ]; check "GH_CONFIG_DIR is an existing empty folder" $?

# 3. org-start asks for no token.
! grep -qi 'worker-gh-token' "$here/skills/org-start/scripts/org-start.sh"; check "org-start.sh no longer looks for a worker token" $?
! grep -q '^## Worker token' "$here/skills/org-start/SKILL.md"; check "org-start SKILL has no Worker token section" $?
sh "$here/scripts/probes/prototype-3-setup.sh" --repo o/n --project "$tmp/p" --token-stdin >/dev/null 2>&1; [ $? -eq 2 ]; check "prototype-3-setup.sh no longer takes --token-stdin" $?

# 4. The stale-base request: the worker is told to ask, the secretary to fetch in the project clone.
rules=$here/templates/worker-rules.md; sec=$here/templates/secretary.md; dg=$here/skills/org-delegate/SKILL.md
grep -qi 'stale' "$rules" && grep -qi 'send_message secretary' "$rules" && grep -qi 'do not fetch\|never fetch\|no credential' "$rules"; check "worker rules: ask the secretary for a newer base, do not fetch" $?
! grep -qi 'your token is read-only' "$rules"; check "worker rules no longer claim a read-only token" $?
grep -qi 'stale' "$sec" && grep -q 'git fetch origin' "$sec"; check "secretary template: fetch in the project clone on a stale-base request" $?
grep -qi 'stale' "$dg" && grep -q 'git fetch origin' "$dg"; check "org-delegate SKILL: delegate-time fetch and the stale-base request" $?
! grep -q 'read-only `GH_TOKEN`' "$sec" "$dg"; check "no text says the worker carries a read-only GH_TOKEN" $?

# 5. The decision is recorded.
sed -n '/^## Q20\./,$p' "$here/docs/design/open-questions.md" | grep -q 'Decided (2026-11-14, owner): D'; check "Q20 records decision D, 2026-11-14" $?
! sed -n '/^## Q20\./,$p' "$here/docs/design/open-questions.md" | grep -q 'Decided (2026-11-10, owner): (d)'; check "Q20 no longer holds decision (d) as the current one" $?
grep -q '^## Decision' "$here/docs/design/worker-github-access.md"; check "worker-github-access.md has a Decision section" $?
! grep -q '^\*\*Not decided here' "$here/docs/design/worker-github-access.md"; check "worker-github-access.md no longer says not decided" $?

exit $fail
