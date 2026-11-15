#!/usr/bin/env bash
# Decision 0014, wave 1 unit 1: paddock's skills load as a plugin. The checkout has a plugin
# manifest, the secretary template passes --plugin-dir, the skill template declares when_to_use,
# and every skill (and the template) has a front matter with name and description.
# Only name and description are required until wave 2 lands; then when_to_use and the caps.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

fm() { awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$1"; } # the front matter lines
fmkey() { fm "$1" | grep -Eq "^$2:[[:space:]]*[^[:space:]]"; } # key present with a non-empty value

manifest=$here/.claude-plugin/plugin.json
[ -f "$manifest" ]; check ".claude-plugin/plugin.json exists" $?
grep -Eq '"name"[[:space:]]*:[[:space:]]*"paddock"' "$manifest" 2>/dev/null; check "plugin.json names the plugin paddock" $?
if command -v node >/dev/null 2>&1; then
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$manifest" 2>/dev/null; check "plugin.json is valid JSON" $?
fi

cmd=$(sed -n 's/^command: //p' "$here/templates/secretary.md")
case $cmd in *'--plugin-dir "$PWD"'*) r=0 ;; *) r=1 ;; esac
check "the secretary template command passes --plugin-dir (the checkout is its working folder)" $r
case $cmd in *'--settings "$bd/secretary-settings.json"'*) r=0 ;; *) r=1 ;; esac
check "the template command keeps --settings" $r

fmkey "$here/templates/skill/SKILL.md" when_to_use; check "templates/skill/SKILL.md declares when_to_use" $?

n=0
for f in "$here"/skills/*/SKILL.md "$here/templates/skill/SKILL.md"; do
  n=$((n + 1))
  rel=${f#"$here"/}
  fmkey "$f" name; check "$rel has name" $?
  fmkey "$f" description; check "$rel has description" $?
done
[ "$n" -gt 1 ]; check "at least one skill was found" $?
exit $fail
