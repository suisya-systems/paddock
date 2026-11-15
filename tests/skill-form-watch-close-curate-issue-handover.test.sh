#!/usr/bin/env bash
# Decision 0014, wave 2 unit 6: org-watch, org-close, org-curate, org-issue and secretary-handover
# take the SKILL.md form (when_to_use, caps, allowed-tools for their own script calls), their scripts
# end every failure with one `next:` line, and the template lines for them (L28-L30, L58-L65, L69-L75,
# L92) moved into the skills. Needs only bash and coreutils; no hc, gh or core runs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tpl=$here/templates/secretary.md
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

fm() { awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$1"; }
fmval() { fm "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -n 1; }
body() { awk 'c >= 2 { print } $0 == "---" { c++ }' "$1"; }

skills="org-watch org-close org-curate org-issue secretary-handover"
for s in $skills; do
  f=$here/skills/$s/SKILL.md
  w=$(fmval "$f" when_to_use)
  [ -n "$w" ]; check "$s: when_to_use is present" $?
  [ $(( ${#w} + $(fmval "$f" description | wc -c) )) -lt 1536 ]; check "$s: description + when_to_use under 1,536 characters" $?
  [ "$(body "$f" | wc -c)" -lt 12288 ]; check "$s: body under 12 KB" $?
done

# allowed-tools: the skill's own script calls, in the form H5 measured (${CLAUDE_SKILL_DIR}).
for pair in org-close:org-close.sh org-close:merge-local.sh org-curate:org-curate.sh org-issue:org-issue.sh; do
  s=${pair%%:*}; sc=${pair#*:}
  fmval "$here/skills/$s/SKILL.md" allowed-tools | grep -qF "Bash(bash \${CLAUDE_SKILL_DIR}/scripts/$sc *)"
  check "$s: allowed-tools pre-approves scripts/$sc" $?
done

# next: line on a non-zero exit (a bad call is enough to reach one).
last_err() { "$@" 2>&1 >/dev/null | tail -n 1; }
export PADDOCK_STATE_DIR=$tmp/state
for c in \
  "org-issue:bash $here/skills/org-issue/scripts/org-issue.sh --kind build" \
  "org-close:bash $here/skills/org-close/scripts/org-close.sh --task BAD" \
  "org-close merge-local:bash $here/skills/org-close/scripts/merge-local.sh" \
  "org-curate:bash $here/skills/org-curate/scripts/org-curate.sh save"; do
  name=${c%%:*}; cmd=${c#*:}
  # shellcheck disable=SC2086
  l=$(last_err $cmd </dev/null)
  case $l in next:\ *) r=0 ;; *) r=1 ;; esac
  check "$name: a bad call ends with a next: line" $r
done

# The template: moved lines are gone, the situations point at the skills, the standing rules stay.
for p in 'skills/org-close/scripts' 'skills/org-curate/scripts' 'skills/org-issue/scripts' 'skills/secretary-handover/scripts' 'wait --children' 'last_exchange'; do
  ! grep -qF -- "$p" "$tpl" "$here/templates/secretary-rules.md"; check "template and rules file do not carry: $p" $?
done
for s in $skills; do
  grep -qF "paddock:$s" "$tpl"; check "template names the skill paddock:$s" $?
done
grep -Eq 'Never `hc kill` a worker.s terminal before that worker.s report is in the mailbox' "$here/templates/secretary-rules.md"; check "rules file keeps: never kill before the report is in" $?
grep -Eq 'end your turns idle' "$here/templates/secretary-rules.md"; check "rules file keeps: end your turns idle (the watcher wakes you)" $?

# The skills hold what moved.
has() { grep -qF -- "$2" "$here/skills/$1/SKILL.md"; check "$1 holds: $2" $?; }
has org-watch 'You have mail: run bash "$PADDOCK_HOME/scripts/org" --as secretary check_messages and act on it.'
has org-watch 'wait --children'
has org-watch '"reason":"message"'
has org-watch 'CI success|failure on PR'
has org-curate '## Where it applies'
has org-curate 'save --task <task_id> --topic'
has org-curate 'skill-candidates.md'
has org-issue 'decide|build|followup'
has org-close 'never `hc kill`'
has org-close '--drop'
has secretary-handover 'last_exchange'
has secretary-handover 'unrecorded_decisions'
has secretary-handover 'open_threads'
has secretary-handover 'doc set secretary-handover'
exit $fail
