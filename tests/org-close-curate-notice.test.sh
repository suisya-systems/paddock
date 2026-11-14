#!/usr/bin/env bash
# org-close ends with the curator count line (decision 0009). hc is a stub on PATH; --drop is used
# so no done record is needed. Needs only bash and coreutils.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-close/scripts/org-close.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

mkdir -p "$tmp/bin" "$tmp/stub"
cat > "$tmp/bin/hc" <<'EOF2'
#!/bin/sh
cmd=$1; shift
case "$cmd" in
  ls) echo '[]' ;;
  get) echo '{"error":{"kind":"not_found"}}'; exit 1 ;;
  connect) read -r req
    case "$req" in
      *doc.get*) printf '{"jsonrpc":"2.0","id":1,"result":{"value":{"work":[],"approvals":[]},"version":1}}\n' ;;
      *) printf '{"jsonrpc":"2.0","id":1,"result":{"version":2}}\n' ;;
    esac ;;
esac
exit 0
EOF2
chmod +x "$tmp/bin/hc"
export PADDOCK_STATE_DIR=$tmp/state PADDOCK_HC_HOLD=0 PADDOCK_WORKERS_DIR=$tmp/workers \
       PADDOCK_CORE_SOCKET_DIR=$tmp/sock PATH="$tmp/bin:$PATH"
unset PADDOCK_ORG_ID PADDOCK_SECRETARY_NAME
k=$PADDOCK_STATE_DIR/knowledge/raw; mkdir -p "$k"

for i in 1 2 3 4; do printf 'Task: t%s\n' "$i" > "$k/2026-11-1$i-n$i.md"; done
out=$(bash "$script" --task t1 --drop 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q '4 unreviewed raw note' <<<"$out" && ! grep -qi 'start the curator' <<<"$out"; check "4 notes: the count is shown, no start line ($out)" $?
printf 'Task: t5\n' > "$k/2026-11-15-n5.md"
out=$(bash "$script" --task t1 --drop 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -qi 'start the curator' <<<"$out"; check "5 notes: org-close says start the curator ($out)" $?
exit $fail
