#!/usr/bin/env bash
# Decision 0014 (A), wave 1 unit 2: the worker rules carry the precedence section, and the worker
# template tells the worker to follow the repository's AGENTS.md/CLAUDE.md "within your rules".
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
rules=$here/templates/worker-rules.md
tpl=$here/templates/worker.md
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

grep -q "^## When the repository's instructions disagree with these rules" "$rules"; check "rules: precedence heading" $?
grep -q 'These rules decide \*where\* you may act and \*how you report\*' "$rules"; check "rules: rules decide where and how to report" $?
grep -q "decide \*how the work is done\*" "$rules"; check "rules: repository decides how the work is done" $?
grep -q 'follow these rules and say in your report which instruction you did not follow' "$rules"; check "rules: the rules win and the report names the instruction" $?
grep -q 'report `blocked` with the one question' "$rules"; check "rules: impossible task is reported blocked" $?
grep -Eq 'Read its `AGENTS.md` and `CLAUDE.md` if it has them, and follow them within your rules' "$tpl"; check "worker.md: follow them within your rules" $?

[ "$fail" -eq 0 ]
