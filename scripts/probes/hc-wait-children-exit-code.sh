#!/bin/sh
# Probe for Issue #51 (REC-4): does `hc wait --children any` return a
# background child's exit code?
#
# Run from a terminal that hc launched (so it is the parent of what it starts),
# e.g. the secretary's terminal. About 10 seconds. Needs only hc and sh.
#   sh scripts/probes/hc-wait-children-exit-code.sh
# Run it under a dedicated hc-launched parent with no other children, so an
# unrelated child or message cannot end the wait early (that would read as FAIL).
# Paste the whole output back. It changes nothing but its own child terminal.
#
# How to read the output:
#   PASS  wait output names probe51-ci AND shows 3 (as exit code), and wait
#         returned after about 5 s.
#   PARTIAL  wait returns after about 5 s but the output has no 3, or does not
#         name the child: the exit is announced, the code is not (check the
#         "hc get" section for where the code lives).
#   FAIL  wait returns at once, times out, or errors: the child's exit does
#         not wake `hc wait --children`.
# The script's own exit status is `hc wait`'s, so 3 here is also a signal, but
# it is ambiguous (hc may use 3 for its own reasons); judge by the output.

NAME=probe51-ci

echo "== 0. context"
command -v hc >/dev/null 2>&1 || { echo "hc not on PATH: not an hc terminal"; exit 127; }
echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
hc --version 2>&1 | head -n 1

cleanup() { hc kill "$NAME" >/dev/null 2>&1; }
trap cleanup EXIT INT TERM
cleanup # a leftover from an earlier run would make --name clash

echo "== 1. hc run --bg"
hc run --bg --name "$NAME" -- sh -c 'sleep 5; exit 3'
echo "run exit: $?"

echo "== 2. hc wait --children any (expect to block ~5 s)"
start=$(date +%s)
hc wait --children any
rc=$?
end=$(date +%s)
echo "wait exit: $rc"
echo "wait elapsed: $((end - start)) s"

echo "== 3. hc get $NAME (after the exit)"
hc get "$NAME" 2>&1
echo "get exit: $?"

echo "== 4. hc ls"
hc ls 2>&1
echo "== done (the child is killed on exit, ignore 'no such terminal' noise)"
exit "$rc"
