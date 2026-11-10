#!/usr/bin/env bash
# The card sends its answer through the org script where org-start places it since Issue #128
# (PADDOCK_BIN_DIR, default ${XDG_DATA_HOME:-~/.local/share}/paddock/bin), and falls back to the
# older place beside the herdr-core templates only when that one is missing.
# Runs tests/org-card-answer.test.sh with an org wrapper in the new place that leaves a mark and
# hands over to the real scripts/org; that test itself covers the fallback (no wrapper).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

wrapper() { # wrapper <dir>: an org in <dir> that records each call, then runs the real one
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\necho used >> %q\nexec bash %q "$@"\n' "$tmp/mark" "$here/scripts/org" > "$1/org"
}

run_case() { # run_case <name> <env assignments...>
  local name=$1; shift
  : > "$tmp/mark"
  out=$(env -u PADDOCK_BIN_DIR -u XDG_DATA_HOME "$@" bash "$here/tests/org-card-answer.test.sh" 2>&1)
  st=$?
  [ "$st" -eq 0 ]; check "$name: the card answer test passes" $?
  [ -s "$tmp/mark" ]; check "$name: the answer went through the org script in the new place" $?
  [ "$fail" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/     | /'
}

wrapper "$tmp/bin"
run_case "PADDOCK_BIN_DIR" PADDOCK_BIN_DIR="$tmp/bin"
wrapper "$tmp/data/paddock/bin"
run_case "XDG_DATA_HOME default" XDG_DATA_HOME="$tmp/data"

exit $fail
