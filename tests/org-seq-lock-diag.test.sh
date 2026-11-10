#!/bin/bash
# Issue #145 diagnostic (temporary): print the runner's environment and, for parallel sends from
# one id, a trace of every lock step, so a duplicate seq seen only in CI can be explained.
# Always exits 0; grep the CI log for "DIAG".
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "DIAG bash=$BASH_VERSION uname=$(uname -sr) nproc=$(nproc 2>/dev/null) pid_max=$(cat /proc/sys/kernel/pid_max 2>/dev/null) ulimit_u=$(ulimit -u)"
echo "DIAG tmpfs=$(df -T "$tmp" 2>/dev/null | awk 'NR==2{print $2}') mv=$(mv --version 2>/dev/null | head -1) mkdir_v=$(mkdir --version 2>/dev/null | head -1) mkdir=$(command -v mkdir) sleep=$(command -v sleep) tail=$(command -v tail)"
echo "DIAG pidns=$(readlink /proc/self/ns/pid 2>/dev/null) uid=$(id -u)"

# A copy of scripts/org with one trace line per lock step (no forks: $EPOCHREALTIME, $BASHPID).
tr_org=$tmp/org
sed \
  -e 's|^  until mkdir "\$lk" 2>/dev/null && excl "\$lk/pid" "\$me"; do$|  echo "$EPOCHREALTIME $me START" >> "$state/trace"\n&|' \
  -e 's|^      o=\$(cat "\$lk/pid" 2>/dev/null)$|&; k=0; kill -0 "$o" 2>/dev/null \|\| k=$?; echo "$EPOCHREALTIME $me CHECK n=$n o=$o kill=$k" >> "$state/trace"|' \
  -e 's|^            && rm -f "\$lk/pid" && rmdir "\$lk" 2>/dev/null$|            \&\& echo "$EPOCHREALTIME $me BREAK o=$o" >> "$state/trace" \&\& rm -f "$lk/pid" \&\& rmdir "$lk" 2>/dev/null|' \
  -e 's|^  printf .{"seq":%s,.*$|  echo "$EPOCHREALTIME $me ACQ n=$n ino=$(ls -di "$lk" \| cut -d" " -f1) ents=$(ls -A "$lk" \| tr "\\n" ,)" >> "$state/trace"\n&|' \
  -e 's|^  rm -f "\$lk/pid"; rmdir "\$lk" 2>/dev/null$|  echo "$EPOCHREALTIME $me WROTE seq=$(tail -n 1 "$d/$id.jsonl" \| cut -c1-12) pidfile=$(cat "$lk/pid" 2>/dev/null)" >> "$state/trace"\n  rm -f "$lk/pid"; rmdir "$lk"; echo "$EPOCHREALTIME $me REL rmdir=$?" >> "$state/trace"|' \
  "$here/scripts/org" > "$tr_org"
for w in START CHECK BREAK ACQ WROTE REL; do grep -q "$w" "$tr_org" || echo "DIAG trace step $w not injected"; done

seqs() { sed -n 's/^{"seq":\([0-9]*\),.*/\1/p' "$1"/events/*/"$2".jsonl 2>/dev/null | sort -n | tr '\n' ' '; }
run() { # run <label> <script> <rounds>
  local s=$tmp/$1 bad=0 r i
  for r in $(seq 1 "$3"); do
    for i in 1 2 3 4 5 6 7 8; do env -u PADDOCK_ORG_ID -u PADDOCK_NOW PADDOCK_STATE_DIR="$s" bash "$2" --as "r$r" send_message secretary "p$i" >/dev/null 2>>"$s.err" & done
    wait
    g=$(seqs "$s" "r$r")
    if [ "$g" != "1 2 3 4 5 6 7 8 " ]; then
      bad=$((bad + 1)); echo "DIAG $1 round r$r got: $g"
      sed -n 's/^\({"seq":[0-9]*\).*"text":"\([^"]*\)".*/DIAG   line \1 \2/p' "$s"/events/*/"r$r".jsonl
    fi
    [ ! -f "$s/trace" ] || { [ "$g" = "1 2 3 4 5 6 7 8 " ] || sed 's/^/DIAG   trace /' "$s/trace"; : > "$s/trace"; }
  done
  echo "DIAG $1: $bad of $3 rounds had a wrong seq list; stderr: $(sort "$s.err" 2>/dev/null | uniq -c | head -5 | tr '\n' ' ')"
}
mkdir -p "$tmp/plain" "$tmp/traced"
run plain "$here/scripts/org" 60
run traced "$tr_org" 60
exit 0
