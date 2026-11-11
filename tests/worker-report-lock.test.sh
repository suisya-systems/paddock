#!/bin/bash
# Issue #245: a lock that cannot be created (the sandbox or the folder's mode refuses the mkdir) is
# not a lock that is held. report says so at once, names the refusal, and does not wait out
# $PADDOCK_LOCK_WAIT; a lock a live process holds still reads as held.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
org=$here/scripts/org
tmp=$(mktemp -d)
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
o() { env -u PADDOCK_ORG_ID -u PADDOCK_NOW PADDOCK_STATE_DIR="$tmp/state" "$@"; }

# 1. The lock folder locks/<id> exists but refuses a new entry (as the worker's sandbox did).
o bash "$org" --as secretary own_files w-a >/dev/null || { echo "FAIL own_files"; exit 1; }
if [ "$(id -u)" -eq 0 ]; then
  echo "FAIL part 1 needs a non-root user (root writes read-only folders)"; fail=1
else
  chmod a-w "$tmp/state/locks/w-a"
  t0=$SECONDS
  out=$(o PADDOCK_LOCK_WAIT=30 bash "$org" --as w-a report start --task a "Starting." 2>&1); rc=$?
  took=$((SECONDS - t0))
  [ "$rc" -eq 5 ]; check "a lock that cannot be created exits 5 (rc $rc)" $?
  grep -q 'cannot create' <<<"$out" && ! grep -q 'is held' <<<"$out"
  check "the message says the lock cannot be created, not that it is held (${out:0:200})" $?
  [ "$took" -lt 10 ]; check "it does not wait out PADDOCK_LOCK_WAIT (took ${took}s of 30)" $?
  chmod u+w "$tmp/state/locks/w-a"
fi

# 2. A lock a live process holds still reads as held, with its pid.
mkdir -p "$tmp/state/locks/w-b/lock"; echo $$ > "$tmp/state/locks/w-b/lock/pid"
out=$(o PADDOCK_LOCK_WAIT=1 bash "$org" --as w-b report start --task b "Starting." 2>&1); rc=$?
[ "$rc" -eq 5 ] && grep -q "is held (pid $$)" <<<"$out"; check "a live holder's lock still reads as held (rc $rc: ${out:0:200})" $?

# 3. Issue #245, measured on the host (scripts/probes/worker-lock.sh): Claude Code merges an Edit deny
# rule into the sandbox's denyWrite, and a denyWrite on the state folder beats the per-task allowWrite
# of the worker's own files, so no Edit deny in the worker settings may cover them.
settings=$here/templates/worker-settings.json
own="~/.local/state/paddock/locks/w-x/lock ~/.local/state/paddock/events/2026-11/w-x.jsonl ~/.local/state/paddock/events/w-x.seq"
bad=$(node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const own = process.argv[2].split(" ");
  for (const r of (s.permissions && s.permissions.deny) || []) {
    const m = /^Edit\((.*)\)$/.exec(r); if (!m) continue;
    const q = m[1].replace(/\/\*\*$/, "");
    if (q === "**" || own.some(p => p === q || p.startsWith(q + "/"))) console.log(r);
  }' "$settings" "$own" 2>&1)
[ -z "$bad" ]; check "no Edit deny in the worker settings covers the worker's own state files (found: $bad)" $?

# 4. The file tools, which run outside the sandbox, are still kept out of the state folder: a
# PreToolUse hook on Edit/Write/NotebookEdit refuses a path there (exit 2) and lets others through.
hook=$(node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const h = ((s.hooks && s.hooks.PreToolUse) || []).find(e => /Write/.test(e.matcher) && /Edit/.test(e.matcher) && /NotebookEdit/.test(e.matcher));
  if (h) process.stdout.write(h.hooks[0].command)' "$settings" 2>/dev/null)
[ -n "$hook" ]; check "the worker settings have a PreToolUse hook on Edit, Write and NotebookEdit" $?
st=$tmp/home/.local/state/paddock; mkdir -p "$st/events" "$tmp/home/wt"
ln -s "$st/events" "$tmp/home/wt/link"
run_hook() { printf '%s' "$1" | env -u PADDOCK_STATE_DIR -u XDG_STATE_HOME HOME="$tmp/home" sh -c "$hook" >/dev/null 2>&1; }
for p in "$st/events/2026-11/secretary.jsonl" "$st/settings/w-x.json" "$tmp/home/wt/../.local/state/paddock/x" "$tmp/home/wt/link/w-y.jsonl" "~/.local/state/paddock/events/w-x.seq"; do
  run_hook "{\"session_id\":\"s\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$p\",\"content\":\"x\"}}"
  [ $? -eq 2 ]; check "the hook refuses Write to $p" $?
done
run_hook "{\"tool_name\":\"NotebookEdit\",\"tool_input\":{\"notebook_path\":\"$st/n.ipynb\",\"new_source\":\"x\"}}"
[ $? -eq 2 ]; check "the hook refuses NotebookEdit in the state folder" $?
run_hook "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$tmp/home/wt/a.txt\",\"old_string\":\"\\\"file_path\\\":\\\"$st/x\\\"\",\"new_string\":\"y\"}}"
[ $? -eq 0 ]; check "the hook lets an Edit in the worktree through (a state path in the text does not count)" $?
run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$tmp/home/.local/state/paddock-other/b\",\"content\":\"x\"}}"
[ $? -eq 0 ]; check "the hook lets a Write beside the state folder through (paddock-other)" $?

[ "$fail" -eq 0 ]
