#!/bin/bash
# Issue #145, second cause: on a GitHub ubuntu runner, mkdir reported success to the loser of a
# race for the same folder (check, then create; a failed create counted as success when the
# folder was there). A mkdir stub on PATH does the same; parallel sends must still get 1..8.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/scripts/org
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
real_mkdir=$(command -v mkdir)

mkdir -p "$tmp/bin"
cat > "$tmp/bin/mkdir" <<EOF
#!/bin/sh
[ "\$1" = -p ] && exec "$real_mkdir" "\$@"
[ -e "\$1" ] && { echo "mkdir: \$1: File exists" >&2; exit 1; }
sleep 0.01
"$real_mkdir" "\$1" 2>/dev/null || [ -d "\$1" ]
EOF
chmod +x "$tmp/bin/mkdir"


bad=
for round in $(seq 1 20); do
  for i in 1 2 3 4 5 6 7 8; do
    env -u PADDOCK_ORG_ID -u PADDOCK_NOW PATH="$tmp/bin:$PATH" PADDOCK_STATE_DIR="$tmp/state" \
      bash "$script" --as "r$round" send_message secretary "p$i" >/dev/null 2>&1 &
  done
  wait
  g=$(sed -n 's/^{"seq":\([0-9]*\),.*/\1/p' "$tmp"/state/events/*/"r$round".jsonl 2>/dev/null | sort -n | tr '\n' ' ')
  [ "$g" = "1 2 3 4 5 6 7 8 " ] || bad="$bad r$round($g)"
  [ ! -e "$tmp/state/events/r$round.lock" ] || bad="$bad r$round(lock left)"
done
[ -z "$bad" ]; check "20 rounds of 8 parallel sends with a racy mkdir each get seq 1..8 (bad:${bad:- none})" $?

exit $fail
