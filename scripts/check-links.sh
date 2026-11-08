#!/usr/bin/env bash
# Check that relative Markdown links [text](path#anchor) resolve.
# Run from the repo root. Needs only bash, grep, sed and coreutils.
# Lists every broken link as file:line and exits 1 if there are any.
# External links (http, https, mailto, any scheme) and absolute paths are skipped.
set -u
LC_ALL=${LC_ALL:-C.UTF-8}

if [ -e .git ] && command -v git >/dev/null; then
  files=$(git ls-files '*.md')
else
  files=$(find . -name '*.md' -not -path './.git/*' -not -path '*/node_modules/*' | sed 's|^\./||')
fi

declare -A ids # file -> newline-separated heading ids, built on first use

heading_ids() { # print GitHub-style ids of the headings in $1
  local line text id n
  local -A seen=()
  local fence=0
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in '```'* | '~~~'*) fence=$((1 - fence)); continue ;; esac
    [ "$fence" -eq 1 ] && continue
    [[ $line =~ ^\ {0,3}\#{1,6}[[:space:]]+(.*)$ ]] || continue
    text=${BASH_REMATCH[1]}
    text=$(sed -E 's/[[:space:]]+#+[[:space:]]*$//' <<<"$text") # closing #s
    id=${text,,}
    id=$(sed -E 's/[^[:alnum:] _-]//g; s/ /-/g' <<<"$id")
    n=${seen[$id]:-0}
    seen[$id]=$((n + 1))
    if [ "$n" -eq 0 ]; then echo "$id"; else echo "$id-$n"; fi
  done <"$1"
}

bad=0
report() { echo "$1:$2: $3"; bad=1; }

for f in $files; do
  dir=$(dirname "$f")
  lineno=0
  fence=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case $line in '```'* | '~~~'*) fence=$((1 - fence)); continue ;; esac
    [ "$fence" -eq 1 ] && continue
    line=$(sed 's/`[^`]*`//g' <<<"$line") # links inside code spans do not count
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      target=${m#\](}; target=${target%\)}
      target=${target%% *}                 # drop an optional "title"
      target=${target#<}; target=${target%>}
      [[ $target =~ ^[A-Za-z][A-Za-z0-9+.-]*: ]] && continue # http:, mailto:, ...
      case $target in /* | '') continue ;; esac
      path=${target%%#*}
      anchor=
      [[ $target == *'#'* ]] && anchor=${target#*#}
      if [ -z "$path" ]; then dest=$f; else dest=$dir/$path; fi
      if [ ! -e "$dest" ]; then report "$f" "$lineno" "missing file: $target"; continue; fi
      [ -n "$anchor" ] || continue
      if [ ! -f "$dest" ] || [[ $dest != *.md ]]; then continue; fi # anchors are checked in Markdown only
      [ -n "${ids[$dest]+x}" ] || ids[$dest]=$(heading_ids "$dest")
      grep -qxF -- "${anchor,,}" <<<"${ids[$dest]}" || report "$f" "$lineno" "missing anchor: $target"
    done < <(grep -oE '\]\([^)]*\)' <<<"$line")
  done <"$f"
done

if [ "$bad" -ne 0 ]; then echo "check-links: broken links found" >&2; exit 1; fi
echo "check-links: ok"
