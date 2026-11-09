#!/bin/sh
# Probe for Q19 / L-N6 (Issue #48): what happens to a template-launched
# secretary's workers when the secretary is killed, with and without
# --outlive-parent. Also: do --outlive-parent workers show in herdr-app's
# Agents sidebar?
#
# Run from the repo root, on a host where herdr core (hc) runs:
#   sh scripts/probes/outlive-parent.sh
# Takes about 1 minute (SIDEBAR_WAIT seconds, default 30, is the pause for
# looking at the Agents sidebar; set SIDEBAR_WAIT=0 to skip it).
# Needs: hc on PATH and a core that can start; POSIX sh only. For the sidebar
# part, a herdr-app window attached to the same core (do not set HC_SESSION
# unless the window is attached to that session). Starts four things, all
# named p48-*: a temporary template, a stand-in secretary and two workers;
# the cleanup trap kills and removes them and deletes the template.
#
# Reading the output (lines starting with "RESULT"):
#   RESULT with-outlive-parent  : survived | gone   (worker started WITH --outlive-parent)
#   RESULT without-outlive-parent: survived | gone  (worker started WITHOUT it)
#   Expected from the docs: with=survived, without=gone. Anything else is
#   the finding. "survived" means the worker's name is still in `hc ls` 3 s
#   after the kill; the BEFORE / AFTER blocks show the full rows (status,
#   parent) so a worker that stays listed as exited can be told apart.
#   RESULT precondition-failed means the setup did not work (see the lines
#   above it); then no conclusion about outlive-parent can be drawn.
# Sidebar: the script cannot see the window. During the pause, look at
# herdr-app's Agents sidebar and note which of p48-with / p48-without /
# p48-secretary are listed (the footer agent count too).

SEC=p48-secretary
WITH=p48-with
WITHOUT=p48-without
TPL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-core/templates"
TPL="$TPL_DIR/p48-secretary.md"
SIDEBAR_WAIT=${SIDEBAR_WAIT:-30}

# has NAME: true if NAME is a whole token in `hc ls` (p48-with must not match p48-without).
has() { hc ls 2>&1 | grep -Eq "(^|[^A-Za-z0-9_-])$1([^A-Za-z0-9_-]|\$)"; }

# Refuse to start over anything that already exists, before the trap is
# installed, so cleanup only ever touches what this run created.
if [ -e "$TPL" ]; then echo "RESULT precondition-failed: $TPL exists; remove it first"; exit 1; fi
for n in $SEC $WITH $WITHOUT; do
  if has "$n"; then echo "RESULT precondition-failed: terminal $n already exists"; exit 1; fi
done

WORK=$(mktemp -d) || exit 1
cleanup() {
  for n in $WITH $WITHOUT $SEC; do hc kill "$n" >/dev/null 2>&1; hc rm "$n" >/dev/null 2>&1; done
  rm -f "$TPL"
  rm -f "$WORK"/*; rmdir "$WORK" 2>/dev/null
}
trap cleanup EXIT INT TERM
mkdir -p "$TPL_DIR" || exit 1

# A worker: reports an OSC 7501 status (so it can count as an agent), then idles.
cat > "$WORK/worker.sh" <<'W'
#!/bin/sh
printf '\033]7501;state=working:app=probe\007'
sleep 600
W

# Stand-in secretary: started from a template, starts the two workers as its
# children, then idles. Run inside an hc terminal, so its `hc run` calls make
# it the parent.
cat > "$WORK/secretary.sh" <<S
#!/bin/sh
hc run --bg --name $WITH --outlive-parent -- sh "$WORK/worker.sh"
hc run --bg --name $WITHOUT -- sh "$WORK/worker.sh"
sleep 600
S
chmod +x "$WORK/secretary.sh"

cat > "$TPL" <<T
---
description: probe 48 stand-in secretary (temporary)
command: $WORK/secretary.sh
---
Probe 48 stand-in secretary. Ignore.
T

echo "== start the secretary from the template"
hc run --bg --name $SEC p48-secretary || { echo "RESULT precondition-failed: hc run failed"; exit 1; }

echo "== wait for both workers to be listed (up to 20 s)"
i=0
while [ $i -lt 20 ]; do
  if has $WITH && has $WITHOUT; then break; fi
  i=$((i + 1)); sleep 1
done
echo "== BEFORE kill (hc ls)"; hc ls 2>&1 | grep "p48-"
for n in $SEC $WITH $WITHOUT; do echo "-- hc get --json $n"; hc get --json "$n" 2>&1; done
if ! has $WITH || ! has $WITHOUT; then
  echo "RESULT precondition-failed: the secretary did not start both workers"; exit 1
fi

if [ "$SIDEBAR_WAIT" -gt 0 ]; then
  echo "== SIDEBAR: for the next $SIDEBAR_WAIT s, look at herdr-app's Agents sidebar."
  echo "   Note which of $SEC / $WITH / $WITHOUT are listed, and the footer agent count."
  sleep "$SIDEBAR_WAIT"
fi

echo "== kill the secretary"
hc kill $SEC; echo "hc kill exit: $?"
sleep 3
echo "== AFTER kill (hc ls)"; hc ls 2>&1 | grep "p48-"
for n in $WITH $WITHOUT; do echo "-- hc get --json $n"; hc get --json "$n" 2>&1; done

for pair in "with-outlive-parent:$WITH" "without-outlive-parent:$WITHOUT"; do
  label=${pair%%:*}; name=${pair#*:}
  if has "$name"; then echo "RESULT $label: survived"; else echo "RESULT $label: gone"; fi
done
echo "== cleanup runs now"
