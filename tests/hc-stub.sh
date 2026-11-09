#!/usr/bin/env bash
# Shared test helper for the org-suspend, org-resume and org-down tests. Source it; it
# defines check(), reset(), run_script(), line() and writes a stub hc into $stubdir.
# Needs only bash and coreutils: no core runs.
#
# Stub state lives in $STUB. "term-<name>" exists while a terminal of that name exists
# and holds its task_id label (empty = unlabelled). "state-<name>" holds its status
# (default idle; "none" = no status object). "doc" holds the org-state answer.
# Every call is appended to $STUB/calls. Knobs (environment of the script under test):
#   STUB_LS_FAIL=1       hc ls fails (core unreachable)
#   STUB_CONT_FAIL=1     a run from template worker-continue reports first_message.sent false
#   STUB_FRESH_FAIL=1    a run from template worker reports first_message.sent false
#   STUB_KILL_FAIL=1     hc kill fails
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/calls"
cmd=$1; shift
name=; tpl=; label=; skip=
for a in "$@"; do
  if [ -n "$skip" ]; then
    case "$skip" in label) label=${a#task_id=} ;; esac
    case "$skip" in name) name=$a ;; esac
    skip=; continue
  fi
  case "$a" in
    --name) skip=name ;; --label) skip=label ;; --cwd) skip=cwd ;;
    --*) ;;
    *) if [ "$cmd" = run ]; then [ -n "$tpl" ] || tpl=$a; else name=$a; fi ;;
  esac
done
case "$cmd" in
  ls) [ -z "${STUB_LS_FAIL:-}" ] || { echo 'hc: connection refused' >&2; exit 1; }
      first=1; printf '['
      for f in "$STUB"/term-*; do [ -e "$f" ] || continue
        [ -n "$first" ] || printf ','; first=; printf '{"name":"%s"}' "${f##*/term-}"; done
      printf ']\n'; exit 0 ;;
  connect) cat >/dev/null; cat "$STUB/doc" 2>/dev/null \
             || echo '{"jsonrpc":"2.0","id":1,"result":{"value":null,"version":0}}'; exit 0 ;;
  get) [ -f "$STUB/term-$name" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       lab=$(cat "$STUB/term-$name"); st=$(cat "$STUB/state-$name" 2>/dev/null || echo idle)
       l='{}'; [ -z "$lab" ] || l="{\"task_id\":\"$lab\"}"
       s="{\"app\":\"claude-code\",\"state\":\"$st\"}"; [ "$st" != none ] || s=null
       printf '{\n  "name": "%s",\n  "state": "live",\n  "labels": %s,\n  "status": %s\n}\n' "$name" "$l" "$s"; exit 0 ;;
  kill) [ -z "${STUB_KILL_FAIL:-}" ] || exit 1; [ -f "$STUB/term-$name" ] || exit 1; echo '{"killed":true}'; exit 0 ;;
  rm) rm -f "$STUB/term-$name" "$STUB/state-$name"; echo '{"removed":true}'; exit 0 ;;
  run) printf '%s' "$label" > "$STUB/term-$name"
       sent=true
       [ "$tpl" != worker-continue ] || [ -z "${STUB_CONT_FAIL:-}" ] || sent=false
       [ "$tpl" != worker ] || [ -z "${STUB_FRESH_FAIL:-}" ] || sent=false
       echo "{\"first_message\":{\"sent\":$sent,\"started\":true,\"turn\":0}}"; exit 0 ;;
esac
exit 0
EOF2
chmod +x "$stubdir/hc"

# A real git repo stands in for a worker's worktree.
wt=$tmp/wt1; mkdir -p "$wt"
gitc() { git -C "$wt" -c user.name=t -c user.email=t@t "$@"; }
git -C "$wt" init -q 2>/dev/null; gitc commit -q --allow-empty -m one

reset() { # fresh stub state with the org-state document naming t1 (worktree $wt) and t2
  rm -rf "$tmp/stub" "$tmp/state"; mkdir -p "$tmp/stub" "$tmp/state"; : > "$tmp/stub/calls"
  cat > "$tmp/stub/doc" <<EOF3
{"jsonrpc":"2.0","id":1,"result":{"value":{"work":[{"task_id":"t1","title":"Alpha","since":"2026-11-10T01:00:00Z","worktree":"$wt","task":"Do alpha \"carefully\""},{"task_id":"t2","title":"Beta","since":"2026-11-10T02:00:00Z","worktree":"$tmp/missing","task":"Do beta"}],"approvals":[]},"version":3}}
EOF3
}
term() { printf '%s' "${2:-}" > "$tmp/stub/term-$1"; } # term <name> [task_id]
run_script() { # run_script <script> [args...]; extra env via ENVX (space separated)
  local s=$1; shift
  env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u PADDOCK_SECRETARY_NAME \
      STUB="$tmp/stub" PADDOCK_STATE_DIR="$tmp/state" PADDOCK_READY_TRIES=1 PATH="$stubdir:$PATH" \
      ${ENVX:-} bash "$s" "$@" 2>&1
}
calls=$tmp/stub/calls
line() { grep -n "$1" "$calls" | head -1 | cut -d: -f1; } # line <regex> in the call log
