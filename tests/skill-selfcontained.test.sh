#!/usr/bin/env bash
# Acceptance test: skills are self-contained. Needs only bash, grep, sed and coreutils.
# Every skills/**/*.md file must have
#   - no Issue / PR number or URL (history belongs in references/rationale.md as content, or in commit messages), and
#   - no link that leaves its skill folder, except to the short allowlist below
#     (a sibling skill's SKILL.md, or a single source of truth that would drift if copied).
# Fixtures are built under a temp dir; the last case scans the real skills/.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

# Allowlist: repo-relative paths a skill may link to when it leaves its own folder.
allow_decisions='docs/decisions/0002-org-mailbox-not-hc-send.md docs/decisions/0004-records-documents-and-jsonl.md'
allow_templates='templates/secretary.md'
is_allowed() { # is_allowed <repo-relative path>
  case $1 in
    skills/*/SKILL.md) return 0 ;; # a sibling skill
  esac
  local a
  for a in $allow_decisions $allow_templates; do [ "$1" = "$a" ] && return 0; done
  return 1
}

# scan <repo-root>: print file:line: reason for each violation; exit 1 if any.
scan() {
  local root=$1 rc=0 f rel dir skill n t path resolved
  while IFS= read -r f; do
    rel=${f#"$root"/}
    dir=$(dirname "$f")
    skill=$(cut -d/ -f1-2 <<<"$rel")
    # Issue / PR numbers and URLs: "#123", ".../issues/123", ".../pull/123", "Issue 123", "PR 123".
    # An anchor like "#71-approvals" (digits then "-text") is not a number, so it is not matched.
    grep -nE '(^|[^A-Za-z0-9_&/-])#[0-9]+([^0-9A-Za-z-]|$)|/(issues|pull)/[0-9]+|\b(Issue|PR) ?[0-9]+' "$f" |
      sed "s|^|$rel:|; s|\$| (issue ref)|" | grep . && rc=1
    # URLs: none allowed (a link to the web is a link out of the folder).
    grep -nE 'https?://' "$f" | sed "s|^|$rel:|; s|\$| (URL)|" | grep . && rc=1
    # Relative links [text](target): inside the skill folder must exist; outside must be allowlisted.
    n=0
    while IFS= read -r line; do
      n=$((n + 1))
      while IFS= read -r t; do
        t=${t#](}; t=${t%)}; path=${t%%#*}
        [ -z "$path" ] && continue
        case $path in mailto:* | /*) echo "$rel:$n: link $t (absolute or scheme)"; rc=1; continue ;; esac
        resolved=$(realpath -m --relative-to="$root" "$dir/$path")
        case $resolved/ in
          "$skill"/*) [ -e "$root/$resolved" ] || { echo "$rel:$n: link $t (missing in skill folder)"; rc=1; } ;;
          *) is_allowed "$resolved" || { echo "$rel:$n: link $t (leaves the skill folder, not allowlisted)"; rc=1; } ;;
        esac
      done < <(grep -oE '\]\([^)]*\)' <<<"$line")
    done <"$f"
  done < <(find "$root/skills" -name '*.md' | sort)
  return $rc
}

# --- fixtures ---
mk() { mkdir -p "$tmp/$1/skills/a" "$tmp/$1/skills/b" "$tmp/$1/docs/decisions" "$tmp/$1/docs/design"; }
mk good
printf '# A\n\nSee [b](../b/SKILL.md) and [rationale](references/rationale.md#why).\n' >"$tmp/good/skills/a/SKILL.md"
mkdir -p "$tmp/good/skills/a/references"
printf '# Why\n\nContent only.\n' >"$tmp/good/skills/a/references/rationale.md"
printf '# B\nUses [d](../../docs/decisions/0004-records-documents-and-jsonl.md) and [self](#b).\n' >"$tmp/good/skills/b/SKILL.md"
scan "$tmp/good" >/dev/null; check "clean fixture passes" $?

for case in 'fixes #12 here' 'see [x](https://github.com/o/r/issues/12)' 'PR 7 did it' 'see https://example.com' \
  'see [d](../../docs/design/prototype-1.md)' 'see [g](references/gone.md)' 'see [o](../../templates/other.md)'; do
  mk bad
  printf '# A\n\n%s\n' "$case" >"$tmp/bad/skills/a/SKILL.md"
  : >"$tmp/bad/skills/b/SKILL.md"
  out=$(scan "$tmp/bad" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && grep -q 'skills/a/SKILL.md:3' <<<"$out"; check "flags: $case" $?
done

# --- the real skills ---
out=$(scan "$here" 2>&1); rc=$?
[ "$rc" -eq 0 ]; check "skills/ has no Issue refs and no non-allowlisted outside links" $?
[ "$rc" -eq 0 ] || echo "$out" | cut -c1-170 | head -40

exit $fail
