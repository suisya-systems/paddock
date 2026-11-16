#!/usr/bin/env bash
# Issue #447: in human mode org-pull-request raises the merge card itself (org-escalation ask) on a
# green watched head, once per head, and merges only on the rerun with --approved once
# org-escalation remove --text yes found the yes in the person's own file. A card for a head that
# moved is withdrawn. Stubbed gh and hc (documents only), the real scripts/org and org-escalation,
# a local bare repository as origin: nothing reaches GitHub and no core runs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
script=$here/skills/org-pull-request/scripts/org-pull-request.sh
org=$here/scripts/org

stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/gh" <<'EOF2'
#!/bin/sh
echo "gh $*" >> "$STUB/calls"
case "$1 $2" in
  "pr create") echo "https://github.com/o/r/pull/42" ;;
  "pr view") case "$*" in *state*) echo "${STUB_STATE:-OPEN}" ;; *) echo "${STUB_HEAD:-$(cat "$STUB/head")}" ;; esac ;;
  "pr checks") exit "${STUB_CHECKS_RC:-0}" ;;
esac
exit 0
EOF2
chmod +x "$stubdir/gh"
. "$here/tests/hc-doc-stub.sh"; hc_doc_stub "$stubdir"

origin=$tmp/origin.git; wt=$tmp/wt
git init -q --bare "$origin"; git clone -q "$origin" "$wt" 2>/dev/null
gitc() { git -C "$wt" -c user.name=t -c user.email=t@t "$@"; }
gitc checkout -q -b feat/x; gitc commit -q --allow-empty -m one

export STUB=$tmp/stub
state=$tmp/state; calls=$STUB/calls
reset() { rm -rf "$STUB" "$state"; mkdir -p "$STUB" "$state"; : > "$calls"
  git -C "$wt" rev-parse HEAD > "$STUB/head"; printf '%s\n' "${DOC:-null}" > "$STUB/docval-org-state"; }
penv() { env -u PADDOCK_NOW -u PADDOCK_ORG_ID -u PADDOCK_SECRETARY_NAME PADDOCK_STATE_DIR="$state" PADDOCK_HC_HOLD=0 \
  PADDOCK_ORG_CONFIG_FILE="$tmp/none.md" PATH="$stubdir:$PATH" "$@"; }
run() { penv ${ENVX:-} bash "$script" --worktree "$wt" --repo o/r "$@" 2>&1; }
watcher() { penv bash "$org" --as watcher ci_completed --pr 42 --sha "$(git -C "$wt" rev-parse HEAD)" --repo o/r \
  --run-id 777 --exit-code 0 >/dev/null; }
say() { penv bash "$org" --as "$1" send_message secretary "$2" >/dev/null; }   # a line in <sender>'s history file
cards() { penv bash "$here/skills/org-escalation/scripts/org-escalation.sh" list 2>/dev/null; }
ncards() { cards | grep -c 'PR #42 '; }
merged() { grep -q '^gh pr merge' "$calls"; }
body=$tmp/body.md; printf 'Body\n' > "$body"
green() { reset; run --title t --body-file "$body" --task-id t1 >/dev/null; watcher; : > "$calls"; }  # PR opened, CI green
idof() { printf '%s\n' "$1" | sed -n 's/.*--approved \([A-Za-z0-9_-]*\).*/\1/p' | head -1; }

# Green in human mode: exactly one card, the rerun raises no second.
green; out=$(run --pr 42); rc=$?
s7=$(git -C "$wt" rev-parse --short=7 HEAD)
[ "$rc" -eq 0 ] && [ "$(ncards)" -eq 1 ] && ! merged; check "green, human: exit 0, one merge card, not merged ($out)" $?
id=$(idof "$out")
[ -n "$id" ] && cards | grep -qx "$id	t1	Merge PR #42 (o/r, head $(git -C "$wt" rev-parse HEAD))?"; check "the card is for task t1 and names the PR and its full head" $?
grep -q '^next: .*merge card .* up.*--approved '"$id" <<<"$out" && grep -q -- "--text no" <<<"$out"
check "next: says the card is up, gives the --approved rerun and the checked no" $?
d=$(cat "$STUB/docval-org-state")
grep -q 'pull/42' <<<"$d" && grep -q 'run 777' <<<"$d" && grep -q 'diff review' <<<"$d" \
  && grep -q '"recommend":"yes"' <<<"$d" && grep -q '"if_yes"' <<<"$d" && grep -q '"if_no"' <<<"$d"
check "the card's background names the PR URL, the watcher's run and the review; if-yes, if-no, recommend yes" $?
out=$(run --pr 42); rc=$?
[ "$rc" -eq 0 ] && [ "$(ncards)" -eq 1 ] && grep -q 'up already' <<<"$out" && grep -q -- "--approved $id" <<<"$out"
check "a rerun raises no second card and names the same one ($out)" $?

# --approved: merged only with the ANSWER in the person's own file.
out=$(run --pr 42 --approved "$id"); rc=$?
[ "$rc" -eq 15 ] && ! merged && [ "$(ncards)" -eq 1 ]; check "--approved with no answer: exit 15, not merged, card kept" $?
say w-t1 "ANSWER $id yes"
out=$(run --pr 42 --approved "$id"); rc=$?
[ "$rc" -eq 15 ] && ! merged && [ "$(ncards)" -eq 1 ]; check "an ANSWER only in another sender's file: not merged ($out)" $?
grep -q '^next: do not merge' <<<"$out" && grep -q -- "remove --id $id --text no" <<<"$out"
check "a refused yes: next: says do not merge, and how to act on a no" $?
say person "ANSWER $id no"
out=$(run --pr 42 --approved "$id"); rc=$?
[ "$rc" -eq 15 ] && ! merged; check "a no answer never merges" $?
say person "ANSWER $id yes"
out=$(run --pr 42 --approved "$id"); rc=$?
head=$(git -C "$wt" rev-parse HEAD)
[ "$rc" -eq 0 ] && grep -Eq "^gh pr merge 42 .*--squash .*--match-head-commit $head( |\$)" "$calls" \
  && ! grep -Eq -- '--admin|--auto' "$calls"; check "the person's yes: merged on the watched head, no --admin/--auto ($out)" $?
grep -q '^gh pr checks 42 .*--required' "$calls" && [ "$(ncards)" -eq 0 ]; check "required checks read; the card is removed" $?

# A head that moved after the card was raised: withdrawn, not merged, CI requested again.
green; out=$(run --pr 42); id=$(idof "$out")
gitc commit -q --allow-empty -m two
say person "ANSWER $id yes"
out=$(run --pr 42 --approved "$id"); rc=$?
[ "$rc" -eq 4 ] && ! merged && [ "$(ncards)" -eq 0 ] && grep -q "withdrawn" <<<"$out"
check "head moved after the card: card withdrawn, not merged ($out)" $?
grep '"kind":"ci_requested"' "$state"/events/*/secretary.jsonl | grep -q "\"sha\":\"$(git -C "$wt" rev-parse HEAD)\""
check "head moved: CI is requested for the new head" $?
watcher; out=$(run --pr 42); rc=$?
[ "$rc" -eq 0 ] && [ "$(ncards)" -eq 1 ] && cards | grep -q "head $(git -C "$wt" rev-parse HEAD))"
check "the new head, once green, gets its own card" $?

# The PR head on GitHub moved under an approved card: withdrawn, exit 10, not merged.
green; out=$(run --pr 42); id=$(idof "$out"); say person "ANSWER $id yes"
out=$(ENVX=STUB_HEAD=0000000000000000000000000000000000000000 run --pr 42 --approved "$id"); rc=$?
[ "$rc" -eq 10 ] && ! merged && [ "$(ncards)" -eq 0 ]; check "the PR head moved: exit 10, card withdrawn, not merged" $?

# Only the exact merge card of this task counts: another approval that merely looks like one is
# neither taken as the card nor withdrawn.
green; old=0123456789abcdef0123456789abcdef01234567
for a in "t1:Merge PR #42 (o/r, head $old)? Also tag a release" "t2:Merge PR #42 (o/r, head $old)?"; do
  penv bash "$here/skills/org-escalation/scripts/org-escalation.sh" ask --task "${a%%:*}" --question "${a#*:}" >/dev/null
  sleep 1   # approval ids hold the second
done
out=$(run --pr 42); rc=$?
[ "$rc" -eq 0 ] && [ "$(ncards)" -eq 3 ] && ! grep -q withdrawn <<<"$out" && grep -q 'raised for head' <<<"$out"
check "a look-alike question or another task's card is not the merge card and is not withdrawn ($out)" $?

# The person merged by hand while the card was up: the rerun withdraws it.
green; out=$(run --pr 42); id=$(idof "$out")
out=$(ENVX=STUB_STATE=MERGED run --pr 42); rc=$?
[ "$rc" -eq 0 ] && [ "$(ncards)" -eq 0 ] && grep -q "Merge card $id withdrawn" <<<"$out" && ! merged
check "merged by hand: the rerun withdraws the open merge card ($out)" $?

# The conversation language from org-state (org-escalation lang).
DOC='{"conversation_lang":"ja"}' green; out=$(run --pr 42)
d=$(cat "$STUB/docval-org-state")
grep -q '"lang":"ja"' <<<"$d" && grep -q 'マージしますか' <<<"$d"; check "lang ja: the card is written in Japanese with --lang ja" $?

# No --approved in acceptance mode, and none without --pr.
reset; out=$(run --pr 42 --mode acceptance --approved x-1); rc=$?
[ "$rc" -eq 2 ] && ! merged; check "--approved in acceptance mode exits 2" $?
out=$(run --title t --body-file "$body" --approved x-1); rc=$?
[ "$rc" -eq 2 ]; check "--approved without --pr exits 2" $?
reset; out=$(run --title t --body-file "$body" --task-id T.1); rc=$?
[ "$rc" -eq 2 ] && ! grep -q '^gh pr create' "$calls"; check "a task id the merge card cannot take exits 2 before the PR is opened" $?

exit "$fail"
