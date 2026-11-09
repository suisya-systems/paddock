#!/usr/bin/env bash
# Acceptance test for scripts/check-templates.sh. Needs only bash and coreutils.
# Fixtures are built under a temp dir; the script runs from each fixture's root.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/scripts/check-templates.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

[ -f "$script" ]; check "script exists" $?

mk() { # mk <name> <file body>: one template in a fixture repo
  mkdir -p "$tmp/$1/templates"
  printf '%b' "$2" > "$tmp/$1/templates/t.md"
}
run() { out=$(cd "$tmp/$1" && bash "$script" 2>&1); rc=$?; }
bad() { # bad <name> <body> <label>: the header must be rejected and named
  mk "$1" "$2"; run "$1"
  [ "$rc" -ne 0 ] && [ "$rc" -ne 127 ]; check "$3 exits non-zero" $?
  grep -q 't.md' <<<"$out"; check "$3 names the file" $?
}

mk good '---\ndescription: A role.\ncommand: claude\n---\nBody\n'
run good; [ "$rc" -eq 0 ]; check "good header exits 0" $?

bad nodesc '---\ncommand: claude\n---\nBody\n' "missing description"
bad nocmd '---\ndescription: A role.\n---\nBody\n' "missing command"
bad emptycmd '---\ndescription: A role.\ncommand:   \n---\nBody\n' "empty command"
bad nofront 'Body only\n' "no front matter"
bad unclosed '---\ndescription: A role.\ncommand: claude\nBody\n' "unclosed header"

# One bad template among good ones still fails.
mk mixed '---\ndescription: A role.\ncommand: claude\n---\n'
printf -- '---\ncommand: x\n---\n' > "$tmp/mixed/templates/u.md"
run mixed; [ "$rc" -ne 0 ] && grep -q 'u.md' <<<"$out"; check "one bad template fails the run" $?

# The real repo templates must be clean.
(cd "$here" && bash "$script" >/dev/null 2>&1); check "repo templates exit 0" $?

exit $fail
