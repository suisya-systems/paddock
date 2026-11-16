#!/usr/bin/env bash
# Acceptance test for decision 0014 wave 3 unit 8 (option F): the secretary's standing rules are
# templates/secretary-rules.md, placed by org-start as <state>/secretary/AGENTS.md with a one-line
# CLAUDE.md (@AGENTS.md); the secretary runs with --cwd <state>/secretary (org-start and the handover
# script), its template command exports PADDOCK_HOME=<checkout> and loads the plugin from there, its
# settings deny Edit on the two files, the handover answers the new folder's trust dialog, every
# script path the secretary is given carries $PADDOCK_HOME/ (or ${CLAUDE_SKILL_DIR}/), and the template
# body is the opening task plus situations -> skills, inside the caps (body + rules < 12 KB, lines <= 400).
# hc and claude are stubs on PATH; no core runs. Needs only bash, grep, sed, awk and coreutils.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

rules=$here/templates/secretary-rules.md
tpl=$here/templates/secretary.md
body() { awk 'n >= 2 { print; next } /^---$/ { n++ }' "$1"; }

# 1. The rules file and the caps.
[ -s "$rules" ]; check "templates/secretary-rules.md exists and is not empty" $?
b=$(body "$tpl")
size=$(( $(printf '%s\n' "$b" | wc -c) + $(cat "$rules" 2>/dev/null | wc -c) ))
[ "$size" -lt 12288 ]; check "template body + rules file under 12 KB ($size bytes)" $?
long=$( { printf '%s\n' "$b"; cat "$rules" 2>/dev/null; } | awk 'length > 400 { n++ } END { print n + 0 }')
[ "$long" -eq 0 ]; check "no line over 400 characters in the template body or the rules file ($long found)" $?

# 2. The body: no script paths, and a situations -> skills list naming every skill the secretary may invoke.
! grep -qE '(scripts|skills)/[A-Za-z0-9_.-]+/|scripts/org' <<<"$b"; check "the template body names no script path" $?
missing=
for f in "$here"/skills/*/SKILL.md; do
  n=$(basename "$(dirname "$f")")
  awk 'NR == 1 && /^---$/ { fm = 1; next } fm && /^---$/ { exit } fm' "$f" | grep -qx 'disable-model-invocation: true' && continue
  grep -qF "paddock:$n" <<<"$b" || missing="$missing $n"
done
[ -z "$missing" ]; check "the template body names every model-invocable skill as paddock:<name> (missing:${missing:- none})" $?

# 3. The rules file carries the standing lines.
for k in 'PADDOCK_HOME' 'hc server stop' 'org-state' 'hc send' 'person'; do
  grep -qF -- "$k" "$rules" 2>/dev/null; check "the rules file has its standing line about '$k'" $?
done

# 4. Settings: Edit (which covers writing) is denied on the two files in the secretary's working folder.
s=$here/templates/secretary-settings.json
for r in 'Edit(./AGENTS.md)' 'Edit(./CLAUDE.md)'; do
  awk '/"deny"/ { d = 1 } d' "$s" | grep -qF "\"$r\""; check "secretary-settings.json denies $r" $?
done

# 5. org-start places the rules and starts the secretary in <state>/secretary; the placed template
# command exports PADDOCK_HOME=<checkout> and passes --plugin-dir <checkout>.
stubdir=$tmp/bin; mkdir -p "$stubdir" "$tmp/elsewhere" "$tmp/stub"
cat > "$stubdir/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/calls"
no='No, exit'; yes='Yes, I trust this folder'
dialog() {
  printf ' Quick safety check: Is this a project you created or one you trust?\n\n'
  if [ "$1" = 1 ]; then printf '   1. %s\n ❯ 2. %s\n' "$no" "$yes"; else printf ' ❯ 1. %s\n   2. %s\n' "$no" "$yes"; fi
}
cmd=$1; shift
case "$cmd" in
  ls) echo ok ;;
  connect) cat >/dev/null
       echo '{"jsonrpc":"2.0","id":1,"result":{"value":{"written_at":"x"},"version":1}}' ;;
  get) [ -f "$STUB/secretary" ] || { echo '{"error":{"kind":"not_found"}}'; exit 1; }
       if [ -f "$STUB/status" ]; then echo '{"name":"secretary","state":"live","status":{"app":"claude-code","state":"idle"}}'
       else echo '{"name":"secretary","state":"live","status":null}'; fi ;;
  kill) [ -f "$STUB/secretary" ] || exit 1 ;;
  rm) rm -f "$STUB/secretary" "$STUB/status" ;;
  run) : > "$STUB/secretary"
       if [ -n "${STUB_DIALOG:-}" ]; then dialog 0 > "$STUB/screen"
         echo '{"first_message":{"sent":false,"started":true,"turn":0}}'
       else : > "$STUB/status"; printf ' > \n' > "$STUB/screen"
         echo '{"first_message":{"sent":true,"started":true,"turn":0}}'; fi ;;
  read) cat "$STUB/screen" 2>/dev/null ;;
  keys) shift
        for k in "$@"; do
          case "$k" in
            down) ! grep -q 'Quick safety check' "$STUB/screen" || dialog 1 > "$STUB/screen" ;;
            enter) if grep -q '❯ 2. Yes, I trust this folder' "$STUB/screen"; then printf ' > \n' > "$STUB/screen"; : > "$STUB/status"
                   elif grep -q '❯ 1. No, exit' "$STUB/screen"; then : > "$STUB/exited"; fi ;;
          esac
        done ;;
  send) printf '%s\n<<END>>\n' "$2" >> "$STUB/sent" ;;
esac
exit 0
EOF2
cat > "$stubdir/claude" <<'EOF2'
#!/bin/sh
printf '%s|%s|%s\n' "${PADDOCK_HOME:-}" "$PWD" "$*" >> "$STUB/claude"
EOF2
chmod +x "$stubdir/hc" "$stubdir/claude"

st=$tmp/state; sdir=$st/secretary; bino=$tmp/orgbin; calls=$tmp/stub/calls
benv=(STUB="$tmp/stub" PATH="$stubdir:$PATH" PADDOCK_STATE_DIR="$st"
  PADDOCK_ORG_CONFIG_FILE="$tmp/cfg/org-config.md" PADDOCK_PROJECTS_FILE="$tmp/cfg/projects.md"
  PADDOCK_CORE_CONFIG_DIR="$here/tests/fixtures/core-notes-off" PADDOCK_CORE_TEMPLATES_DIR="$tmp/core/templates"
  PADDOCK_APP_MODS_DIR="$tmp/app/mods" PADDOCK_APP_LAYOUTS_DIR="$tmp/app/layouts" PADDOCK_BIN_DIR="$bino" PADDOCK_READY_TRIES=3)
fresh() { rm -rf "$tmp/stub"; mkdir -p "$tmp/stub"; : > "$calls"; }
go() { # go <script> [args...]: from another folder, outside any agent
  ( cd "$tmp/elsewhere" && env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u PADDOCK_SECRETARY_NAME \
      "${benv[@]}" "${extra[@]}" bash "$@" 2>&1 )
}
extra=()

fresh; out=$(go "$here/skills/org-start/scripts/org-start.sh"); rc=$?
[ "$rc" -eq 0 ]; check "org-start: exit 0 (got $rc)" $?
cmp -s "$rules" "$sdir/AGENTS.md"; check "org-start: places the rules as <state>/secretary/AGENTS.md" $?
[ "$(cat "$sdir/CLAUDE.md" 2>/dev/null)" = '@AGENTS.md' ]; check "org-start: places <state>/secretary/CLAUDE.md, whose only line is @AGENTS.md" $?
grep '^run ' "$calls" | grep -qF -- "--cwd $sdir "; check "org-start: starts the secretary with --cwd <state>/secretary" $?

cmd=$(sed -n 's/^command: //p' "$tmp/core/templates/secretary.md")
: > "$tmp/stub/claude"
( cd "$sdir" && env STUB="$tmp/stub" PATH="$stubdir:$PATH" PADDOCK_BIN_DIR="$bino" sh -c "$cmd" ) >/dev/null 2>&1
IFS='|' read -r ph pw pa < "$tmp/stub/claude" 2>/dev/null || { ph= pw= pa=; }
[ "$ph" = "$here" ]; check "template command: PADDOCK_HOME is the checkout ('$ph')" $?
[ "$pw" = "$sdir" ]; check "template command: claude runs in <state>/secretary" $?
case " $pa " in *" --plugin-dir $here "*) r=0 ;; *) r=1 ;; esac
check "template command: --plugin-dir is the checkout ('$pa')" $r
case " $pa " in *" --settings $bino/secretary-settings.json "*) r=0 ;; *) r=1 ;; esac
check "template command: still passes --settings from the bin folder" $r

# 6. --place-only (inside an agent) places them too, and says when changed rules reach the secretary.
rm -rf "$sdir"
out=$(cd "$tmp/elsewhere" && env "${benv[@]}" CLAUDECODE=1 bash "$here/skills/org-start/scripts/org-start.sh" --place-only 2>&1); rc=$?
[ "$rc" -eq 0 ] && cmp -s "$rules" "$sdir/AGENTS.md" && [ "$(cat "$sdir/CLAUDE.md" 2>/dev/null)" = '@AGENTS.md' ]
check "place-only: places AGENTS.md and CLAUDE.md in <state>/secretary" $?
printf 'old rules\n' > "$sdir/AGENTS.md"
out=$(cd "$tmp/elsewhere" && env "${benv[@]}" CLAUDECODE=1 bash "$here/skills/org-start/scripts/org-start.sh" --place-only 2>&1)
cmp -s "$rules" "$sdir/AGENTS.md" && grep -qi 'compaction' <<<"$out"
check "place-only: a changed rules file is placed again, with a line that it reaches the secretary at its next compaction" $?

# 7. The handover relaunches in <state>/secretary, answers the new folder's trust dialog, and
# refuses (ending nothing) when the rules were never placed.
fresh; : > "$tmp/stub/secretary"; : > "$tmp/stub/status"
out=$(go "$here/skills/secretary-handover/scripts/secretary-handover.sh"); rc=$?
[ "$rc" -eq 0 ] && grep '^run ' "$calls" | grep -qF -- "--cwd $sdir "
check "handover: relaunches with --cwd <state>/secretary (rc=$rc)" $?

fresh; : > "$tmp/stub/secretary"; : > "$tmp/stub/status"; extra=(STUB_DIALOG=1)
out=$(go "$here/skills/secretary-handover/scripts/secretary-handover.sh"); rc=$?; extra=()
d=$(grep -n -x 'keys secretary down' "$calls" | head -n 1 | cut -d: -f1)
e=$(grep -n -x 'keys secretary enter' "$calls" | head -n 1 | cut -d: -f1)
[ "$rc" -eq 0 ] && [ -n "$d" ] && [ -n "$e" ] && [ "$d" -lt "$e" ] && [ ! -f "$tmp/stub/exited" ]
check "handover: answers the trust dialog of the new folder (down, then enter on Yes; rc=$rc)" $?
first=$(body "$tpl" | head -n 1)
msg=$(sed '/^<<END>>$/q' "$tmp/stub/sent" 2>/dev/null | sed '$d')
[ "$(printf '%s\n' "$msg" | head -n 1)" = "$first" ] && grep -q 'Resume as the secretary from the handover' <<<"$msg"
check "handover: after the dialog, sends the first message again (template body and the resume task)" $?

rm -rf "$sdir"; fresh; : > "$tmp/stub/secretary"; : > "$tmp/stub/status"
out=$(go "$here/skills/secretary-handover/scripts/secretary-handover.sh"); rc=$?
[ "$rc" -ne 0 ] && ! grep -qE '^(kill|rm|run) ' "$calls" && grep -q 'org-start' <<<"$out"
check "handover: with no rules placed, refuses before ending anything and names org-start (rc=$rc)" $?

# 8. Every script path the secretary is given carries $PADDOCK_HOME/ (or ${CLAUDE_SKILL_DIR}/): no
# 'bash scripts/...' or 'bash skills/...' relative to a working folder that is no longer the checkout.
hits=
for f in "$tpl" "$rules" "$here"/skills/*/SKILL.md "$here"/skills/*/scripts/* "$here"/scripts/org "$here"/scripts/hooks/*; do
  [ -f "$f" ] || continue
  case $f in */SKILL.md)
    awk 'NR == 1 && /^---$/ { fm = 1; next } fm && /^---$/ { exit } fm' "$f" | grep -qx 'disable-model-invocation: true' && continue ;;
  esac
  h=$(grep -nE '(^|[^A-Za-z0-9_.-])(bash|sh) +["`]?(scripts|skills)/' "$f" | sed "s|^|${f#"$here"/}:|")
  [ -z "$h" ] || hits="$hits
$h"
done
[ -z "$hits" ]; check "no checkout-relative script path reaches the secretary${hits:+:$hits}" $?

exit $fail
