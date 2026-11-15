#!/usr/bin/env bash
# Decision 0014, wave 1 unit 1: paddock's skills load as a plugin. The checkout has a plugin
# manifest, the secretary template passes --plugin-dir, the skill template declares when_to_use,
# and every skill (and the template) has a front matter with name and description.
# Wave 2 closing: every skill also needs when_to_use, name equal to its folder, description plus
# when_to_use under 1,536 characters (D4), and a body under 12 KB (decision 0014 parts 3 and 4).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

fm() { awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$1"; } # the front matter lines
fmkey() { fm "$1" | grep -Eq "^$2:[[:space:]]*[^[:space:]]"; } # key present with a non-empty value

fmval() { fm "$1" | sed -n "s/^$2:[[:space:]]*//p"; } # a key's value (front matter values are one line)
body() { awk 'NR == 1 { next } b { print } $0 == "---" { b = 1 }' "$1"; } # everything after the front matter

manifest=$here/.claude-plugin/plugin.json
[ -f "$manifest" ]; check ".claude-plugin/plugin.json exists" $?
grep -Eq '"name"[[:space:]]*:[[:space:]]*"paddock"' "$manifest" 2>/dev/null; check "plugin.json names the plugin paddock" $?
if command -v node >/dev/null 2>&1; then
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$manifest" 2>/dev/null; check "plugin.json is valid JSON" $?
fi

cmd=$(sed -n 's/^command: //p' "$here/templates/secretary.md")
case $cmd in *'--plugin-dir "$PADDOCK_HOME"'*) r=0 ;; *) r=1 ;; esac
check "the secretary template command passes --plugin-dir \$PADDOCK_HOME (the checkout; its working folder is its own)" $r
case $cmd in *'--settings "$bd/secretary-settings.json"'*) r=0 ;; *) r=1 ;; esac
check "the template command keeps --settings" $r

fmkey "$here/templates/skill/SKILL.md" when_to_use; check "templates/skill/SKILL.md declares when_to_use" $?

n=0
for f in "$here"/skills/*/SKILL.md "$here/templates/skill/SKILL.md"; do
  n=$((n + 1))
  rel=${f#"$here"/}
  fmkey "$f" name; check "$rel has name" $?
  fmkey "$f" description; check "$rel has description" $?
  fmkey "$f" when_to_use; check "$rel has when_to_use" $?
  case $rel in
    skills/*) [ "$(fmval "$f" name)" = "$(basename "$(dirname "$f")")" ]; check "$rel name equals its folder" $? ;;
  esac
  len=$(( $(fmval "$f" description | wc -m) + $(fmval "$f" when_to_use | wc -m) ))
  [ "$len" -lt 1536 ]; check "$rel description + when_to_use is under 1,536 characters ($len)" $?
  size=$(body "$f" | wc -c)
  [ "$size" -lt 12288 ]; check "$rel body is under 12 KB ($size bytes)" $?
done
[ "$n" -gt 1 ]; check "at least one skill was found" $?
exit $fail
