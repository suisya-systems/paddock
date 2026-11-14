#!/usr/bin/env bash
# Acceptance chain of decision 0009, links 1 to 4, on a fixture folder: fake raw notes, a fake
# queue and a fake skill built from templates/skill/. Link 5 (a later task uses the skill) is shown
# by one real run, not here. Needs only bash and coreutils.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-curate/scripts/org-curate.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

tpl=$here/templates/skill
[ -f "$tpl/SKILL.md" ] && [ -f "$tpl/references/rationale.md" ]; check "templates/skill/ has SKILL.md and references/rationale.md" $?
grep -q '^name:' "$tpl/SKILL.md" 2>/dev/null && grep -q '^description:' "$tpl/SKILL.md" 2>/dev/null; check "the template SKILL.md has name and description" $?

export PADDOCK_STATE_DIR=$tmp/state
k=$PADDOCK_STATE_DIR/knowledge
repo=$tmp/repo
build() { # build: a complete chain for pattern lock-sweep, skill name lock-sweep
  rm -rf "$PADDOCK_STATE_DIR" "$repo"; mkdir -p "$k/raw" "$k/curated" "$repo/skills"
  local i; for i in 1 2 3; do
    printf 'Task: t%s\n\n## Facts\nf\n\n## Judgment\nj\n\n## Grounds\ng\n\n## Where it applies\nw\n' "$i" > "$k/raw/2026-11-1$i-lock-$i.md"
  done
  { echo "# lock-sweep"; echo "When: Use it when a killed worker leaves a lock in the clone."; echo
    echo "- raw/2026-11-11-lock-1.md"; echo "- raw/2026-11-12-lock-2.md"; echo "- raw/2026-11-13-lock-3.md"; } > "$k/curated/lock-sweep.md"
  cat > "$k/skill-candidates.md" <<'EOF2'
# Skill candidates

- **pattern**: lock-sweep
- **date**: 2026-11-20
- **notes**: raw/2026-11-11-lock-1.md raw/2026-11-12-lock-2.md raw/2026-11-13-lock-3.md
- **when**: Use it when a killed worker leaves a lock in the clone.
- **skill**: lock-sweep
- **status**: approved
- **decided**: 2026-11-21
EOF2
  mkdir -p "$repo/skills/lock-sweep/references"
  printf -- '---\nname: lock-sweep\ndescription: Remove the lock a killed worker leaves in the clone.\n---\n\n# lock-sweep\n\nUse it when a killed worker leaves a lock in the clone.\n' > "$repo/skills/lock-sweep/SKILL.md"
  printf '# Why\n\nFrom these notes: 2026-11-11-lock-1.md 2026-11-12-lock-2.md 2026-11-13-lock-3.md\n' > "$repo/skills/lock-sweep/references/rationale.md"
}
chain() { bash "$script" chain --pattern lock-sweep --skill lock-sweep --repo "$repo" 2>&1; }

build; out=$(chain); rc=$?
[ "$rc" -eq 0 ]; check "a complete chain passes links 1 to 4 ($out)" $?
for n in 1 2 3 4; do grep -q "link $n" <<<"$out"; check "the output reports link $n" $?; done

build; rm "$k/raw/2026-11-13-lock-3.md"
out=$(chain); rc=$?; [ "$rc" -ne 0 ] && grep -q 'link 1' <<<"$out"; check "link 1 fails with fewer than 3 notes ($out)" $?

build; printf 'Task: t1\n\n## Facts\nf\n' > "$k/raw/2026-11-13-lock-3.md"
out=$(chain); rc=$?; [ "$rc" -ne 0 ] && grep -q 'link 1' <<<"$out"; check "link 1 fails when 2 of the 3 notes are from one task" $?

build; : > "$k/skill-candidates.md"
out=$(chain); rc=$?; [ "$rc" -ne 0 ] && grep -q 'link 2' <<<"$out"; check "link 2 fails with no queue entry" $?

build; sed -i 's/^- \*\*when\*\*:.*/- **when**: /' "$k/skill-candidates.md"
out=$(chain); rc=$?; [ "$rc" -ne 0 ] && grep -q 'link 2' <<<"$out"; check "link 2 fails with no trigger sentence" $?

build; sed -i 's/ raw\/2026-11-13-lock-3.md//' "$k/skill-candidates.md"
out=$(chain); rc=$?; [ "$rc" -ne 0 ] && grep -q 'link 2' <<<"$out"; check "link 2 fails when the entry does not list the notes" $?

build; sed -i 's/approved/pending/' "$k/skill-candidates.md"
out=$(chain); rc=$?; [ "$rc" -ne 0 ] && grep -q 'link 3' <<<"$out"; check "link 3 fails while the entry is pending (no skill without the owner)" $?

build; sed -i 's/^- \*\*decided\*\*:.*/- **decided**: /' "$k/skill-candidates.md"
out=$(chain); rc=$?; [ "$rc" -ne 0 ] && grep -q 'link 3' <<<"$out"; check "link 3 fails with no decision date" $?

build; rm -r "$repo/skills/lock-sweep"
out=$(chain); rc=$?; [ "$rc" -ne 0 ] && grep -q 'link 4' <<<"$out"; check "link 4 fails with no skill folder" $?

build; printf '# Why\n\nNo notes named.\n' > "$repo/skills/lock-sweep/references/rationale.md"
out=$(chain); rc=$?; [ "$rc" -ne 0 ] && grep -q 'link 4' <<<"$out"; check "link 4 fails when rationale.md does not name the raw notes" $?

build; printf '\nSee #123 and https://example.com\n' >> "$repo/skills/lock-sweep/SKILL.md"
out=$(chain); rc=$?; [ "$rc" -ne 0 ] && grep -q 'link 4' <<<"$out"; check "link 4 fails on an Issue number or URL in the skill" $?

build; sed -i 's/^name: lock-sweep/name: other/' "$repo/skills/lock-sweep/SKILL.md"
out=$(chain); rc=$?; [ "$rc" -ne 0 ] && grep -q 'link 4' <<<"$out"; check "link 4 fails when the front matter name is not the folder name" $?

exit $fail
