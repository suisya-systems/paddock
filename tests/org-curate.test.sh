#!/usr/bin/env bash
# Acceptance test for skills/org-curate (decision 0009): saving a raw note, the count that starts
# the curator, the two gates, and the case where a pattern qualifies only after two cycles.
# Needs only bash and coreutils; every folder is a throwaway one.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-curate/scripts/org-curate.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

[ -f "$script" ]; check "script exists" $?
[ -f "$here/skills/org-curate/SKILL.md" ]; check "SKILL.md exists" $?
bash -n "$script" 2>/dev/null; check "script parses" $?

export PADDOCK_STATE_DIR=$tmp/state
k=$PADDOCK_STATE_DIR/knowledge
oc() { bash "$script" "$@" 2>&1; }
reset() { rm -rf "$PADDOCK_STATE_DIR"; mkdir -p "$k/raw" "$k/raw/archive" "$k/curated"; }
note() { # note <dir under raw> <file> <task>: a raw note as save writes it
  printf 'Task: %s\n\n## Facts\nf\n\n## Judgment\nj\n\n## Grounds\ng\n\n## Where it applies\nw\n' "$3" > "$k/raw/${1:+$1/}$2"
}
curated() { # curated <pattern> <when> <raw file>...
  local p=$1 w=$2; shift 2
  { echo "# $p"; echo "When: $w"; echo; for f in "$@"; do echo "- raw/$f"; done; } > "$k/curated/$p.md"
}
note_text() { printf '## Facts\nf\n\n## Judgment\nj\n\n## Grounds\ng\n\n## Where it applies\nw\n'; }

# --- save ---
reset
note_text | oc save --task t1 --topic lock-wait >/dev/null; rc=$?
f=$(ls "$k"/raw/*-lock-wait.md 2>/dev/null | head -1)
[ "$rc" -eq 0 ] && [ -n "$f" ] && [ "$(head -1 "$f")" = "Task: t1" ] && grep -q '^## Where it applies' "$f"; check "save writes raw/<date>-<topic>.md with a Task line" $?
note_text | oc save --task t1 --topic lock-wait >/dev/null; rc=$?
[ "$rc" -ne 0 ] && [ "$(ls "$k"/raw | grep -c lock-wait)" -eq 1 ]; check "save never overwrites a note" $?
printf '## Facts\nonly\n' | oc save --task t1 --topic thin >/dev/null; rc=$?
[ "$rc" -ne 0 ] && ! ls "$k"/raw/*-thin.md >/dev/null 2>&1; check "save refuses a note without the four headings" $?
note_text | oc save --task 'bad id' --topic x >/dev/null; rc=$?; [ "$rc" -ne 0 ]; check "save refuses a bad task id" $?
note_text | oc save --task t2 --topic '../x' >/dev/null; rc=$?; [ "$rc" -ne 0 ]; check "save refuses a topic that is not kebab-case" $?

# --- count ---
reset
for i in 1 2 3 4; do note "" "2026-11-1$i-a$i.md" "t$i"; done
out=$(oc count); rc=$?
[ "$rc" -eq 0 ] && grep -q '4 unreviewed raw note' <<<"$out" && ! grep -qi 'start the curator' <<<"$out"; check "4 notes: counted, no start line ($out)" $?
note "" 2026-11-15-a5.md t5
out=$(oc count)
grep -q '5 unreviewed raw note' <<<"$out" && grep -qi 'start the curator' <<<"$out"; check "5 unreviewed notes: one line says start the curator ($out)" $?
touch "$k/last-curated"; sleep 1
out=$(oc count); grep -q '0 unreviewed raw note' <<<"$out" && ! grep -qi 'start the curator' <<<"$out"; check "notes older than last-curated are not counted" $?
note "" 2026-11-16-a6.md t6
out=$(oc count); grep -q '1 unreviewed raw note' <<<"$out"; check "a note newer than last-curated is counted" $?
mv "$k/raw/2026-11-16-a6.md" "$k/raw/archive/"
out=$(oc count); grep -q '0 unreviewed raw note' <<<"$out"; check "raw/archive is not counted by the start rule" $?
for i in 1 2 3 4 5; do printf -- '- **pattern**: p%s\n- **status**: pending\n' "$i" >> "$k/skill-candidates.md"; done
out=$(oc count); grep -q '5 pending candidate' <<<"$out" && grep -qi 'start the curator' <<<"$out"; check "5 pending candidates start the curator ($out)" $?
reset; out=$(oc count); rc=$?
[ "$rc" -eq 0 ] && grep -q '0 unreviewed raw note' <<<"$out"; check "no knowledge folder at all: counts 0" $?
rm -rf "$PADDOCK_STATE_DIR"; out=$(oc count); rc=$?
[ "$rc" -eq 0 ] && grep -q '0 unreviewed raw note' <<<"$out"; check "no state folder at all: counts 0" $?

# --- the gates ---
reset
note "" 2026-11-10-a.md t1; note "" 2026-11-11-b.md t2; note "" 2026-11-12-c.md t3
curated p1 "Use it when a worker is killed in a command." 2026-11-10-a.md 2026-11-11-b.md 2026-11-12-c.md
out=$(oc candidates); rc=$?
[ "$rc" -eq 0 ] && grep -q '^p1	3	' <<<"$out"; check "3 notes from 3 tasks and a one-sentence trigger: a candidate ($out)" $?

reset
note "" 2026-11-10-a.md t1; note "" 2026-11-11-b.md t1; note "" 2026-11-12-c.md t2
curated p1 "Use it when a worker is killed in a command." 2026-11-10-a.md 2026-11-11-b.md 2026-11-12-c.md
out=$(oc candidates); [ -z "$out" ]; check "3 notes from only 2 tasks: no candidate" $?

reset
note "" 2026-11-10-a.md t1; note "" 2026-11-11-b.md t2; note "" 2026-11-12-c.md t3
curated p1 "" 2026-11-10-a.md 2026-11-11-b.md 2026-11-12-c.md
out=$(oc candidates); [ -z "$out" ]; check "no trigger sentence: no candidate" $?
curated p1 "Use it when a worker is killed. Also when it is not." 2026-11-10-a.md 2026-11-11-b.md 2026-11-12-c.md
out=$(oc candidates); [ -z "$out" ]; check "a trigger of two sentences: no candidate" $?
curated p1 "Use it when a worker is killed." 2026-11-10-a.md 2026-11-11-b.md 2026-11-99-gone.md
out=$(oc candidates); [ -z "$out" ]; check "a listed note that does not exist does not count" $?

# Notes in raw/archive still count.
reset
note archive 2026-11-10-a.md t1; note "" 2026-11-11-b.md t2; note archive 2026-11-12-c.md t3
curated p1 "Use it when a worker is killed." archive/2026-11-10-a.md 2026-11-11-b.md archive/2026-11-12-c.md
out=$(oc candidates); grep -q '^p1	3	' <<<"$out"; check "notes in raw/archive count toward the gate" $?

# A pattern already in the queue is not proposed again.
printf -- '- **pattern**: p1\n- **status**: rejected\n' > "$k/skill-candidates.md"
out=$(oc candidates); [ -z "$out" ]; check "a queued pattern (any status) is not proposed again" $?

# --- a note that qualifies only after waiting two cycles ---
reset
note "" 2026-11-10-a.md t1; note "" 2026-11-11-b.md t2
curated p1 "Use it when a worker is killed in a command." 2026-11-10-a.md 2026-11-11-b.md
out=$(oc candidates); [ -z "$out" ]; check "cycle 1: 2 notes from 2 tasks, no candidate" $?
oc finish >/dev/null; [ -f "$k/last-curated" ]; check "cycle 1: finish touches last-curated" $?
[ -f "$k/raw/2026-11-10-a.md" ] && [ -f "$k/raw/2026-11-11-b.md" ]; check "cycle 1: the notes that did not qualify stay in raw/" $?
sleep 1
note "" 2026-11-13-c.md t1
curated p1 "Use it when a worker is killed in a command." 2026-11-10-a.md 2026-11-11-b.md 2026-11-13-c.md
out=$(oc candidates); [ -z "$out" ]; check "cycle 2: a third note from an already counted task, still no candidate" $?
oc finish >/dev/null; sleep 1
note "" 2026-11-14-d.md t3
curated p1 "Use it when a worker is killed in a command." 2026-11-10-a.md 2026-11-11-b.md 2026-11-13-c.md 2026-11-14-d.md
out=$(oc candidates)
grep -q '^p1	3	' <<<"$out" && grep -q '2026-11-10-a.md' <<<"$out" && grep -q '2026-11-14-d.md' <<<"$out"; check "cycle 3: the old notes, read again, qualify with the new one ($out)" $?
[ -f "$k/raw/2026-11-10-a.md" ] && [ -f "$k/raw/2026-11-11-b.md" ] && [ -f "$k/raw/2026-11-13-c.md" ]; check "the gate moves and deletes nothing" $?

# --- the templates and rules the loop is built from ---
c=$here/templates/curator.md
[ -f "$c" ] && (cd "$here" && bash scripts/check-templates.sh >/dev/null 2>&1); check "templates/curator.md exists and its header passes check-templates" $?
for pat in 'raw/archive' 'org-curate.sh candidates' 'org-curate.sh finish' 'secretary' 'different tasks' 'one sentence'; do
  grep -qF -- "$pat" "$c" 2>/dev/null; check "curator template says: $pat" $?
done
grep -qiE 'all (the )?(accumulated |kept )?(raw )?notes|every (raw )?note' "$c" 2>/dev/null; check "curator template says it reads all notes every run" $?
grep -qiE 'keep|kept' "$c" 2>/dev/null && grep -qiE 'never (create|write) a skill|creates? no skill|no skill' "$c" 2>/dev/null; check "curator template keeps notes and creates no skill" $?
grep -q '## Where it applies' "$here/templates/worker-rules.md"; check "worker rules ask for the four-heading note at the end of the report" $?
grep -q 'org-curate.sh save' "$here/templates/secretary.md"; check "secretary rules save the note and start the curator" $?
grep -q 'org-curate.sh count' "$here/skills/org-close/scripts/org-close.sh"; check "org-close prints the curator count" $?

exit $fail
