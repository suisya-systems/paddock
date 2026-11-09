#!/bin/sh
# Probe for Issue #55 (MON-12): can a secretary-like agent watch a CI run by
# starting the run-watch command as a background child terminal
# (`hc run --bg --rm --no-notify --name ci -- gh run watch <id> --exit-status`)
# and `hc wait` on it, receiving the command's exit code when the run ends?
#
# Run from the repo root, inside a terminal that hc launched (so it is the
# parent of what it starts), on a host where herdr core (hc) runs:
#   sh scripts/probes/ci-watch-child.sh [CMD [EXPECT]]
#   CMD     the run-watch stand-in, run as `sh -c "$CMD"`.
#           Default: 'sleep 20; exit 3'. EXPECT is its exit code (default 3).
#           Real use: sh scripts/probes/ci-watch-child.sh 'gh run watch 123 --exit-status' 0
#           CMD must not contain a single quote (part B embeds it in quotes).
#   SKIP_GH=1  skip part C (the real `gh run watch`).
# Takes about 2.5 minutes with the default (five waits of about 20 s, plus the
# template-launched parent). Needs hc, sh, grep, date, mktemp; part C needs
# `gh` authenticated on the host and the repo root as the working directory.
# Starts only terminals named p55-*, plus a temporary template p55-parent; the
# cleanup trap kills and removes them and deletes the template. Prints only
# presence/absence of variables, never values. Paste the whole output back.
#
# Parts:
#   A  from THIS terminal, four `hc wait` forms, each on a fresh child:
#        A1 hc wait ci                    A2 hc wait --json ci
#        A3 hc wait --children any        A4 hc wait --json --children any
#      (a form hc rejects is recorded as such, not retried in another order).
#   B  from a PARENT terminal launched from a template (the parent runs
#      `hc run --bg --rm --no-notify` + `hc wait ci`, as the secretary would).
#      After the wait, the parent reads its own stdin for 3 s: any note typed
#      into it by hc would show there ("parent stdin bytes").
#   C  one real `gh run watch` on the latest completed run of this repo, with
#      `--exit-status`, if gh is authenticated. Recorded separately.
#
# Reading the output. Each case prints its raw `hc wait` output between
# "-- wait output" and "-- end", then one line:
#   RESULT <case>: wait_rc=<hc wait's own exit status> elapsed=<s> output=<verdict>
# with <verdict>:
#   named+code   output names the child (p55-ci) AND shows the expected code
#                -> PASS: the exit code arrives in `hc wait`'s output.
#   code-only    shows the expected code but not the name
#   name-only    names the child but the code is missing -> PARTIAL: the exit is
#                announced, the code lives elsewhere (see the `hc get` lines)
#   neither      -> FAIL (or hc rejected the form: read the raw output)
#   rejected     hc wait exited with a usage / parse error at once (elapsed ~0)
# Also read wait_rc: if it equals the child's code, `hc wait` passes the code
# through as its own exit status (the script can use `$?`); if it is 0 (the
# REC-4 probe saw 0), the code must be parsed from the output text.
# elapsed should be about the child's runtime (20 s by default); ~0 with the
# child still running means the wait did not block.
# Part B adds: "parent stdin bytes: 0" = --no-notify kept the parent's input
# clean; anything above 0 = something was typed into the parent (then also
# check the quoted "parent stdin" text).
# Part C RESULT lines: gh-run-id, gh-conclusion (the run's real conclusion;
# success -> expect code 0, failure -> expect 1), then the usual RESULT line
# with EXPECT set from the conclusion. "gh not authenticated" is not a failure.
# After `--rm` the child may be gone when you look: `hc get` lines that say
# "no such terminal" are themselves a finding (--rm removed it), not noise.

CMD=${1:-'sleep 20; exit 3'}
EXPECT=${2:-3}
CHILD=p55-ci
PARENT=p55-parent
TPL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-core/templates"
TPL="$TPL_DIR/$PARENT.md"

has() { hc ls 2>&1 | grep -Eq "(^|[^A-Za-z0-9_-])$1([^A-Za-z0-9_-]|\$)"; }

echo "== 0. context"
command -v hc >/dev/null 2>&1 || { echo "RESULT precondition-failed: hc not on PATH"; exit 127; }
echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "hc: $(hc --version 2>&1 | head -n 1)"
echo "cmd: $CMD (expect exit $EXPECT)"
if command -v gh >/dev/null 2>&1; then echo "gh: $(gh --version 2>&1 | head -n 1)"; else echo "gh: not installed"; fi
if [ -n "${CLAUDE_CODE_VERSION:-}" ]; then echo "CLAUDE_CODE_VERSION: set"; fi
for n in $CHILD $PARENT; do
  if has "$n"; then echo "RESULT precondition-failed: terminal $n already exists"; exit 1; fi
done
if [ -e "$TPL" ]; then echo "RESULT precondition-failed: $TPL exists; remove it first"; exit 1; fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/probe55.XXXXXX") || exit 1
cleanup() {
  for n in $CHILD $PARENT; do hc kill "$n" >/dev/null 2>&1; hc rm "$n" >/dev/null 2>&1; done
  rm -f "$TPL"
  rm -f "$WORK"/*; rmdir "$WORK" 2>/dev/null
}
trap cleanup EXIT INT TERM
mkdir -p "$TPL_DIR" || exit 1

# case.sh LABEL CMD CHILD_ARGS_EXTRA WAIT_ARGS...: starts the child as the
# secretary would, waits, saves the raw output, rc and elapsed to $WORK.
cat > "$WORK/case.sh" <<'C'
#!/bin/sh
label=$1; cmd=$2; shift 2
out=$WORK/$label
hc run --bg --rm --no-notify --name p55-ci -- sh -c "$cmd" > "$out.run" 2>&1
echo $? > "$out.runrc"
start=$(date +%s)
hc wait "$@" > "$out.wait" 2>&1
echo $? > "$out.waitrc"
echo $(( $(date +%s) - start )) > "$out.elapsed"
hc get p55-ci > "$out.get" 2>&1
C

# report LABEL EXPECT: prints the saved case and the RESULT line.
report() {
  l=$1; ex=$2; o=$WORK/$l
  echo "-- $l: run rc=$(cat "$o.runrc" 2>/dev/null) ($(cat "$o.run" 2>/dev/null | head -n 1))"
  echo "-- wait output"; cat "$o.wait" 2>/dev/null; echo "-- end"
  echo "-- hc get after the wait:"; cat "$o.get" 2>/dev/null
  rc=$(cat "$o.waitrc" 2>/dev/null); el=$(cat "$o.elapsed" 2>/dev/null)
  name=no; code=no
  grep -q "$CHILD" "$o.wait" 2>/dev/null && name=yes
  # the JSON field, or the text form "exit N" (REC-4); a bare number would match "turn":0
  grep -Eq "\"exit_code\":$ex([^0-9]|\$)|exit $ex([^0-9]|\$)" "$o.wait" 2>/dev/null && code=yes
  if [ "${el:-0}" -lt 1 ] && grep -Eqi "usage|unknown|unexpected|invalid|error" "$o.wait" 2>/dev/null; then v=rejected
  elif [ $name = yes ] && [ $code = yes ]; then v=named+code
  elif [ $code = yes ]; then v=code-only
  elif [ $name = yes ]; then v=name-only
  else v=neither; fi
  echo "RESULT $l: wait_rc=${rc:-?} elapsed=${el:-?} output=$v"
  hc kill $CHILD >/dev/null 2>&1; hc rm $CHILD >/dev/null 2>&1
}

direct() { # LABEL EXPECT CMD WAIT_ARGS...
  l=$1; ex=$2; c=$3; shift 3
  echo "== $l: hc wait $*"
  WORK=$WORK sh "$WORK/case.sh" "$l" "$c" "$@"
  report "$l" "$ex"
}

echo "== A. from this terminal"
direct A1-wait-name "$EXPECT" "$CMD" $CHILD
direct A2-wait-name-json "$EXPECT" "$CMD" --json $CHILD
direct A3-wait-children "$EXPECT" "$CMD" --children any
direct A4-wait-children-json "$EXPECT" "$CMD" --json --children any

echo "== B. from a parent terminal launched from a template"
cat > "$WORK/parent.sh" <<P
#!/bin/sh
WORK="$WORK" sh "$WORK/case.sh" B-parent '$CMD' $CHILD
timeout 3 cat > "$WORK/B-parent.stdin" 2>/dev/null
echo done > "$WORK/B-parent.done"
sleep 600
P
cat > "$TPL" <<T
---
description: probe 55 stand-in secretary (temporary)
command: sh $WORK/parent.sh
---
Probe 55 stand-in secretary. Ignore.
T
hc run --bg --name $PARENT $PARENT || { echo "RESULT B-parent: precondition-failed: hc run failed"; }
i=0
while [ ! -f "$WORK/B-parent.done" ] && [ $i -lt 120 ]; do i=$((i + 1)); sleep 1; done
if [ -f "$WORK/B-parent.done" ]; then
  echo "-- hc get --json $PARENT"; hc get --json $PARENT 2>&1
  report B-parent "$EXPECT"
  bytes=$(wc -c < "$WORK/B-parent.stdin" 2>/dev/null || echo "?")
  echo "RESULT B-parent: parent stdin bytes: $bytes"
  [ "${bytes:-0}" != 0 ] && { echo "-- parent stdin"; cat "$WORK/B-parent.stdin"; echo "-- end"; }
else
  echo "RESULT B-parent: timeout (parent did not finish in 120 s)"
fi

if [ "${SKIP_GH:-}" = 1 ]; then echo "== C. skipped (SKIP_GH=1)"
elif ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  echo "== C. gh not installed or not authenticated; skipped"
else
  echo "== C. real gh run watch on the latest completed run"
  id=$(gh run list --status completed --limit 1 --json databaseId -q '.[0].databaseId' 2>&1)
  concl=$(gh run list --status completed --limit 1 --json conclusion -q '.[0].conclusion' 2>&1)
  echo "RESULT gh-run-id: $id"
  echo "RESULT gh-conclusion: $concl"
  case $id in ''|*[!0-9]*) echo "RESULT C-gh: no completed run found (see the line above)";;
  *)
    if [ "$concl" = success ]; then ex=0; else ex=1; fi
    direct C-gh "$ex" "gh run watch $id --exit-status" $CHILD ;;
  esac
fi
echo "== done; paste everything above back =="
