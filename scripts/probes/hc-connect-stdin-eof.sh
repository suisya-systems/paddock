#!/bin/sh
# Probe for Issue #74: does `hc connect` answer a request when its stdin
# reaches end-of-file right after the request line?
#
# Run from any shell where `hc` is on PATH and a herdr-core is reachable.
# About 10 seconds. Needs only hc and sh. It sends one read-only doc.get, so it
# changes nothing.
#   sh scripts/probes/hc-connect-stdin-eof.sh
# Paste the whole output back.
#
# How to read the output (each case prints "exit=N bytes=M" and the answer):
#   A  request, then EOF at once (printf | hc connect). If bytes=0, hc ended at
#      EOF before answering: this is the behaviour reported in Issue #74.
#   B  same request, but stdin held open for 1 s (the paddock workaround). If
#      this answers (bytes>0, a JSON line) while A does not, the only
#      difference is when stdin closes.
#   C  request read from a file (hc connect < file): EOF at once, no pipe.
#      Same reading as A.
#   D  stdin held open for 0.2 s: how short the hold can be (informational).
#   E  case A repeated 20 times against a real document (default org-state,
#      or the name in $1; pick a large one) with 20 repeats of B for contrast.
#      "answered" counts runs that printed a JSON line. Anything below 20/20
#      for A while B is 20/20 is the race the first measurement may have hit.
# Windows (where the first measurement was made): see hc-connect-stdin-eof.ps1.
# Expected by a reader of the docs: A and C answer like B (exit=0, one JSON
# line with "result" or a JSON-RPC "error"). The docs do not say what happens
# at EOF. Exit codes are those of hc itself, not of the pipeline's first stage.

DOC=probe74-nonexistent-doc
REQ='{"jsonrpc":"2.0","id":1,"method":"doc.get","params":{"name":"'"$DOC"'"}}'
TMP="${TMPDIR:-/tmp}/hc-connect-eof.$$"
trap 'rm -f "$TMP" "$TMP.req"' EXIT INT TERM

echo "== 0. context"
command -v hc >/dev/null 2>&1 || { echo "hc not on PATH"; exit 127; }
echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
hc --version 2>&1 | head -n 1
echo "request: $REQ"

show() { # label, exit code; the answer is in $TMP
  bytes=$(wc -c < "$TMP" | tr -d ' ')
  echo "-- $1: exit=$2 bytes=$bytes"
  head -c 400 "$TMP"; echo
}

echo "== A. request, then EOF at once"
printf '%s\n' "$REQ" | hc connect > "$TMP" 2>&1; show A $?

echo "== B. request, stdin held open 1 s"
{ printf '%s\n' "$REQ"; sleep 1; } | hc connect > "$TMP" 2>&1; show B $?

printf '%s\n' "$REQ" > "$TMP.req"
echo "== C. request from a file (EOF at once)"
hc connect < "$TMP.req" > "$TMP" 2>&1; show C $?

echo "== D. request, stdin held open 0.2 s"
{ printf '%s\n' "$REQ"; sleep 0.2; } | hc connect > "$TMP" 2>&1; show D $?

echo "== E. repeat against a real document: ${1:-org-state}"
RDOC="${1:-org-state}"
RREQ='{"jsonrpc":"2.0","id":1,"method":"doc.get","params":{"name":"'"$RDOC"'"}}'
a=0; b=0; i=0
while [ $i -lt 20 ]; do
  printf '%s\n' "$RREQ" | hc connect 2>&1 | grep -q '^{' && a=$((a+1))
  { printf '%s\n' "$RREQ"; sleep 1; } | hc connect 2>&1 | grep -q '^{' && b=$((b+1))
  i=$((i+1))
done
echo "-- E: EOF at once answered $a/20; held 1 s answered $b/20"
