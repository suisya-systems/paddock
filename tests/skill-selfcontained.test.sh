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
# Scripts reach the repo through "$root" (the folder three levels above a script). Each file below is one source of
# truth that a copy of the skill would otherwise duplicate: the org command, a sibling skill's shared script, and the
# files org-start installs.
allow_script_files='scripts/org
skills/org-suspend/scripts/lib.sh skills/org-suspend/scripts/org-suspend.sh
skills/org-delegate/scripts/project.sh skills/org-escalation/scripts/org-escalation.sh skills/org-watch/scripts/org-watch.sh
templates/secretary.md templates/worker.md templates/curator.md templates/worker-settings.json layouts/paddock.json
skills/org-curate/scripts skills/org-curate/scripts/org-curate.sh
mods/org-agents/main.js mods/org-agents/mod.json mods/org-cockpit/main.js mods/org-cockpit/mod.json'
is_script_allowed() { # is_script_allowed <repo-relative path>
  local a
  for a in $allow_script_files; do [ "$1" = "$a" ] && return 0; done
  return 1
}
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
  scan_scripts "$root" || rc=1
  return $rc
}

# scan_scripts <repo-root>: the non-Markdown files under skills/ (shell scripts). Same Issue / PR rule, and
# every path that leaves the skill folder (a "../" token, or "$root/<path>") must be allowlisted.
# A token that resolves to the repo root itself is the root derivation: the paths used from it are checked below.
scan_scripts() {
  local root=$1 rc=0 f rel dir skill n line t resolved
  while IFS= read -r f; do
    rel=${f#"$root"/}
    dir=$(dirname "$f")
    skill=$(cut -d/ -f1-2 <<<"$rel")
    grep -nE '(^|[^A-Za-z0-9_&/-])#[0-9]+([^0-9A-Za-z-]|$)|/(issues|pull)/[0-9]+|\b(Issue|PR) ?[0-9]+' "$f" |
      sed "s|^|$rel:|; s|\$| (issue ref)|" | grep . && rc=1
    n=0
    while IFS= read -r line; do
      n=$((n + 1))
      while IFS= read -r t; do
        [ -z "$t" ] && continue
        case $t in
          '$root/'*) resolved=${t#\$root/} ;;
          *) resolved=$(realpath -m --relative-to="$root" "$dir/$t") ;;
        esac
        case $resolved/ in
          ./ | "$skill"/*) continue ;;
        esac
        is_script_allowed "$resolved" || { echo "$rel:$n: path $t (leaves the skill folder, not allowlisted)"; rc=1; }
      done < <(grep -oE '\.\.(/[A-Za-z0-9_.*-]+)*|\$root/[A-Za-z0-9_.*-]+(/[A-Za-z0-9_.*-]+)*' <<<"$line")
    done <"$f"
  done < <(find "$root/skills" -type f ! -name '*.md' | sort)
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

# Scripts: a clean one passes; each leak is flagged on line 3 of skills/a/scripts/x.sh.
mk good_sh
mkdir -p "$tmp/good_sh/skills/a/scripts"
printf '#!/usr/bin/env bash\n# See ../SKILL.md.\nroot=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)\nbash "$root/scripts/org" x\n. "$here/../../org-suspend/scripts/lib.sh"\n' >"$tmp/good_sh/skills/a/scripts/x.sh"
scan "$tmp/good_sh" >/dev/null; check "clean script passes" $?
for case in '# Issue #12: why' 'x=1 # fixes #12 (probe #52)' '. "$here/../../../lib/x.sh"' 'cat "$root/docs/x.md"' 'cat "$here/../../b/scripts/x.sh"'; do
  mk bad_sh
  mkdir -p "$tmp/bad_sh/skills/a/scripts"
  printf '#!/usr/bin/env bash\n# top\n%s\n' "$case" >"$tmp/bad_sh/skills/a/scripts/x.sh"
  out=$(scan "$tmp/bad_sh" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && grep -q 'skills/a/scripts/x.sh:3' <<<"$out"; check "flags script: $case" $?
done

# --- the real skills ---
out=$(scan "$here" 2>&1); rc=$?
[ "$rc" -eq 0 ]; check "skills/ has no Issue refs and no non-allowlisted outside links" $?
[ "$rc" -eq 0 ] || echo "$out" | cut -c1-170 | head -40

exit $fail
