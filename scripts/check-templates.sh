#!/usr/bin/env bash
# Check that every templates/*.md starts with a front matter block (--- ... ---)
# holding a non-empty `description:` and `command:`. Run from the repo root.
# Lists every bad template as file: reason and exits 1 if there are any.
set -u
rc=0
for f in templates/*.md; do
  [ -e "$f" ] || continue
  if [ "$(head -n 1 "$f")" != "---" ]; then echo "$f: no front matter"; rc=1; continue; fi
  header=$(sed -n '2,${/^---[[:space:]]*$/q;p;}' "$f")
  if ! sed -n '2,$p' "$f" | grep -q '^---[[:space:]]*$'; then echo "$f: unclosed front matter"; rc=1; continue; fi
  for key in description command; do
    val=$(grep -m1 "^$key:" <<<"$header" | sed "s/^$key:[[:space:]]*//;s/[[:space:]]*\$//")
    if [ -z "$val" ]; then echo "$f: missing or empty $key"; rc=1; fi
  done
done
exit $rc
