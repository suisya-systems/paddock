#!/bin/bash
# Regression cases for scripts/org found in review, kept apart from the acceptance test
# tests/org-commands.test.sh: a CR in message text, a "version" key inside a document value,
# and an update command that prints a value and then fails. hc is a stub on PATH.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/scripts/org
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/calls"
[ "$1" = connect ] || exit 0
read -r req
case "$req" in
  *doc.get*) printf '{"jsonrpc":"2.0","id":1,"result":{"value":%s,"version":%s}}\n' "$(cat "$STUB/docval")" "$(cat "$STUB/docver")" ;;
  *doc.set*) echo "$req" > "$STUB/set-request"; echo '{"jsonrpc":"2.0","id":1,"result":{"version":9}}' ;;
esac
EOF2
chmod +x "$stubdir/hc"
export STUB=$tmp/stub; mkdir -p "$STUB"; : > "$STUB/calls"
org() { env -u PADDOCK_ORG_ID -u PADDOCK_NOW PADDOCK_HC_HOLD=0 PADDOCK_STATE_DIR="$tmp/state" PATH="$stubdir:$PATH" bash "$script" "$@" 2>&1; }

# 1. CRLF text: the file holds no raw CR and the text comes back with its CR.
org --as w1 send_message secretary "$(printf 'a\r\nb')" >/dev/null
f=$(ls "$tmp"/state/events/*/w1.jsonl)
[ "$(tr -cd '\r' < "$f" | wc -c)" -eq 0 ] && grep -q '"text":"a\\r\\nb"' "$f"; check "a CR in a message is escaped as \\r" $?
out=$(org --as secretary check_messages | tr -d '\r'); grep -q '^b$' <<<"$out"; check "the CRLF message is read back" $?

# 2. A value with a nested "version" key is read whole.
echo '{"nested":{"a":1,"version":2}}' > "$STUB/docval"; echo 3 > "$STUB/docver"
out=$(org --as w1 doc get org-state); [ "$out" = '{"nested":{"a":1,"version":2}}' ]; check "doc get keeps a nested version key" $?
org --as secretary doc update org-state -- sed "s/\"a\":1/\"a\":9/" >/dev/null; r=$?
grep -q '"value":{"nested":{"a":9,"version":2}},"version":3}}$' "$STUB/set-request"; check "doc update writes the whole value back with the envelope version (exit $r)" $?

# 3. An update command that prints a value and then fails writes nothing.
rm -f "$STUB/set-request"
org --as secretary doc update org-state -- sh -c 'printf "{}"; exit 1' >/dev/null; r=$?
[ "$r" -eq 10 ] && [ ! -e "$STUB/set-request" ]; check "a failing update command exits 10 and sets nothing" $?

# 5. Parallel sends from one id get distinct, increasing seq numbers.
for i in 1 2 3 4 5 6 7 8; do org --as w8 send_message secretary "p$i" >/dev/null & done; wait
seqs=$(sed -n 's/^{"seq":\([0-9]*\),.*/\1/p' "$tmp"/state/events/*/w8.jsonl | sort -n | tr '\n' ' ')
[ "$seqs" = "1 2 3 4 5 6 7 8 " ]; check "8 parallel sends from one id get seq 1..8 (got: $seqs)" $?
[ ! -d "$tmp/state/events/w8.lock" ]; check "the per-id lock is released" $?

# 4. PADDOCK_SECRETARY_NAME is a terminal name; the mailbox id `secretary` still writes documents.
echo null > "$STUB/docval"; echo 1 > "$STUB/docver"
echo "{}" | env PADDOCK_SECRETARY_NAME=boss PADDOCK_HC_HOLD=0 PADDOCK_STATE_DIR="$tmp/state" PATH="$stubdir:$PATH" bash "$script" --as secretary doc set org-state >/dev/null 2>&1; r=$?
[ "$r" -eq 0 ]; check "--as secretary writes a document even with PADDOCK_SECRETARY_NAME set" $?

exit $fail
