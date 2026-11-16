#!/usr/bin/env bash
# The cockpit's worker preview (lastLines in mods/org-cockpit/main.js) shows the work above the
# prompt row, not the input box, status line or footer hints below it. The function is cut out of
# the mod and run on screens shaped like `hc read` output.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
fn=$(sed -n '/^const CHROME = /,/^}/p' "$here/mods/org-cockpit/main.js")
[ -n "$fn" ]; check "lastLines is found in the mod" $?

run() { FN="$fn" node -e 'eval(process.env.FN + "; globalThis.f = lastLines"); let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => console.log(JSON.stringify(f(s, +process.argv[1]))))' "$1"; }

screen='● Bash(bash tests/org-cockpit.test.sh)
  ⎿  ok   node is available
     ok   the rail renders
● Running the full test suite now.
✻ Crunching… (12s · esc to interrupt)

╭────────────────────────────────────────────╮
│ ❯                                          │
╰────────────────────────────────────────────╯
  [PONYTAIL] full · opus · 42% context
  ⏵⏵ auto mode on (shift+tab to cycle)       ? for shortcuts'
got=$(printf '%s\n' "$screen" | run 2)
[ "$got" = '["ok   the rail renders","● Running the full test suite now."]' ]; check "work lines above the ❯ prompt, not the status line ($got)" $?

bare='● Running the full test suite now.
────────────────────────────────────
❯ fix the test
────────────────────────────────────
  [PONYTAIL] full'
got=$(printf '%s\n' "$bare" | run 2)
[ "$got" = '["● Running the full test suite now."]' ]; check "an unboxed ❯ prompt with typed text is cut too ($got)" $?

noprompt='org-watch: pass 3
org-watch: cannot reach the core (hc ls failed)
? for shortcuts'
got=$(printf '%s\n' "$noprompt" | run 2)
[ "$got" = '["org-watch: pass 3","org-watch: cannot reach the core (hc ls failed)"]' ]; check "no prompt row keeps the old filter ($got)" $?
got=$(printf '%s\n' "$noprompt" | run 1)
[ "$got" = '["org-watch: cannot reach the core (hc ls failed)"]' ]; check "one line, as the watcher strip asks ($got)" $?

exit $fail
