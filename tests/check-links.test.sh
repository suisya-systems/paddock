#!/usr/bin/env bash
# Acceptance test for scripts/check-links.sh. Needs only bash and coreutils.
# Fixtures are built under a temp dir so they are never scanned as repo docs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/scripts/check-links.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

[ -f "$script" ]; check "script exists" $?

# Broken fixture: missing file, missing anchor, and a good link between them.
mkdir -p "$tmp/bad/docs"
cat > "$tmp/bad/README.md" <<'MD'
# Title

See [gone](docs/missing.md) for details.
See [ok](docs/a.md#real-heading) here.
See [bad anchor](docs/a.md#no-such-heading) here.
See [web](https://example.com/nope) and [mail](mailto:x@example.com).
MD
printf '# A\n\n## Real Heading\n' > "$tmp/bad/docs/a.md"
out=$(cd "$tmp/bad" && bash "$script" 2>&1); rc=$?
[ "$rc" -ne 0 ] && [ "$rc" -ne 127 ]; check "broken fixture exits non-zero" $?
grep -q 'README.md:3' <<<"$out"; check "reports missing file as file:line" $?
grep -q 'README.md:5' <<<"$out"; check "reports missing anchor as file:line" $?
! grep -q 'README.md:4' <<<"$out"; check "does not flag the valid link" $?
! grep -q 'README.md:6' <<<"$out"; check "ignores external URLs" $?

# GitHub-style ids: punctuation dropped, spaces to hyphens, duplicates get -1.
mkdir -p "$tmp/good"
cat > "$tmp/good/a.md" <<'MD'
# What is it? (Q1)

## Same
## Same

[x](#what-is-it-q1) [y](#same-1) [z](b.md#sec-2-things)
MD
printf '## Sec 2: Things\n' > "$tmp/good/b.md"
(cd "$tmp/good" && bash "$script" >/dev/null 2>&1); check "valid fixture exits 0" $?

# The real repo docs must be clean.
(cd "$here" && bash "$script" >/dev/null 2>&1); check "repo docs exit 0" $?

exit $fail
