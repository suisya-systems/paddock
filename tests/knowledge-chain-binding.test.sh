#!/usr/bin/env bash
# org-curate chain: archived notes still resolve, the approved entry is bound to the skill, and
# only Markdown is scanned for Issue numbers and URLs. Needs only bash and coreutils.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$here/skills/org-curate/scripts/org-curate.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
export PADDOCK_STATE_DIR=$tmp/state
k=$PADDOCK_STATE_DIR/knowledge; repo=$tmp/repo
build() {
  rm -rf "$PADDOCK_STATE_DIR" "$repo"; mkdir -p "$k/raw/archive" "$k/curated" "$repo/skills/s/references"
  for i in 1 2 3; do printf 'Task: t%s\n\n## Facts\nf\n' "$i" > "$k/raw/2026-11-1$i-n$i.md"; done
  { echo "When: Use it when x happens."; for i in 1 2 3; do echo "- raw/2026-11-1$i-n$i.md"; done; } > "$k/curated/p.md"
  printf -- '- **pattern**: p\n- **notes**: raw/2026-11-11-n1.md raw/2026-11-12-n2.md raw/2026-11-13-n3.md\n- **when**: Use it when x happens.\n- **skill**: s\n- **status**: approved\n- **decided**: 2026-11-20\n' > "$k/skill-candidates.md"
  printf -- '---\nname: s\ndescription: d.\n---\n# s\n' > "$repo/skills/s/SKILL.md"
  printf 'n1 2026-11-11-n1.md 2026-11-12-n2.md 2026-11-13-n3.md\n' > "$repo/skills/s/references/rationale.md"
}
chain() { bash "$script" chain --pattern p --skill "${1:-s}" --repo "$repo" 2>&1; }
build; chain >/dev/null; check "baseline chain holds" $?
build; mv "$k/raw/2026-11-12-n2.md" "$k/raw/archive/"
out=$(chain); check "a note archived after the entry was written still counts ($out)" $?
build; out=$(chain other); rc=$?; [ "$rc" -ne 0 ] && grep -q 'link 3' <<<"$out"; check "a skill the entry does not name fails link 3" $?
build; printf "Task: t4\n\n## Facts\nf\n" > "$k/raw/2026-11-14-n4.md"; sed -i "s|^- raw/2026-11-13-n3.md|&\n- raw/2026-11-14-n4.md|" "$k/curated/p.md"
chain >/dev/null; check "a note added to the pattern after the entry was queued does not break the chain" $?
build; mkdir -p "$repo/skills/s/scripts"; echo 'curl https://api.example.com/x' > "$repo/skills/s/scripts/s.sh"
chain >/dev/null; check "a URL in a script does not fail link 4" $?
build; printf "x" > "$k/raw/archive/$(date +%F)-dup.md"
printf "## Facts\nf\n\n## Judgment\nj\n\n## Grounds\ng\n\n## Where it applies\nw\n" | bash "$script" save --task t9 --topic dup >/dev/null 2>&1; rc=$?
[ "$rc" -eq 4 ] && [ ! -e "$k/raw/$(date +%F)-dup.md" ]; check "save refuses a name that exists in raw/archive" $?
build; sed -i "s/^- \*\*when\*\*:.*/- **when**: Use it. Also then./" "$k/skill-candidates.md"
out=$(chain); rc=$?; [ "$rc" -ne 0 ] && grep -q "link 2" <<<"$out"; check "a two-sentence trigger in the queue entry fails link 2" $?
exit $fail
