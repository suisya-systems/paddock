#!/bin/sh
# Secretary Bash guard: a PreToolUse hook (templates/secretary-settings.json). Exit 2 with a reason
# on stderr refuses the call; exit 0 lets it through.
# - hc keys / a forced hc send: keys reach a worker only through org-escalation.sh (L-N3, Issue #260).
# - long blocking calls (Issue #378): while a shell call runs the secretary takes no input, so a CI
#   watch (gh pr checks --watch, gh run watch), a sleep over 5 s and a loop that sleeps are refused.
# Only the command text is matched, after heredoc bodies and quoted text with a space in it are cut out
# (a command substitution in it is kept), so a task
# text or a PR body that mentions these commands passes. The arguments of `sh -c` / `bash -c` are kept.
# A skill script's own calls (org-pull-request runs gh pr checks --watch) are not seen: only the top line.
# ponytail: sed cuts the command out of the payload (no JSON parser in plain shell); an escaped
# backslash before n reads as a newline. A command hidden behind eval, a variable or a script file is
# not seen: this is a guard against habit, not a sandbox.
payload=$(tr '\n' ' ')
cmd=$(printf '%s\n' "$payload" | sed -n 's/.*"command" *: *"\(\([^"\\]\|\\.\)*\)".*/\1/p')
[ -n "$cmd" ] || cmd=$payload   # not found: match the whole payload, as the old one-line hook did
text=$(printf '%s\n' "$cmd" | sed 's/\\n/\
/g; s/\\t/	/g; s/\\"/"/g; s/\\\\/\\/g' | awk '
  # drop heredoc bodies: after a line with <<WORD (not <<<), skip up to the line that is WORD
  # an unquoted word (<<EOF) still runs $(...) and `...` in the body: keep those
  n > 0 { l = $0; if (strip[q]) sub(/^\t+/, "", l); if (l == word[q]) { q++; if (q > n) n = 0; next }
          if (!lit[q]) while (match(l, /\$\([^)]*\)|`[^`]*`/)) { print substr(l, RSTART, RLENGTH); l = substr(l, RSTART + RLENGTH) }
          next }
  {
    print; s = $0
    while ((i = index(s, "<<")) > 0) {
      pre = substr(s, 1, i - 1); s = substr(s, i + 2)
      if (substr(pre, length(pre)) == "<" || substr(s, 1, 1) == "<") { sub(/^<+/, "", s); continue }
      d = 0; if (substr(s, 1, 1) == "-") { d = 1; s = substr(s, 2) }
      if (!match(s, /^[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) continue
      w = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH); l = (w ~ /["\047]/); gsub(/[ \t"\047]/, "", w)
      if (n == 0) q = 1
      n++; word[n] = w; strip[n] = d; lit[n] = l
    }
  }' | tr '\n' ';' | sed "s/-c[[:space:]]*'\([^']*\)'/-c \1/g; s/-c[[:space:]]*\"\([^\"]*\)\"/-c \1/g")
# a command substitution runs even inside double quotes (not single): keep it; a quoted single word (sleep "60") is
# an argument, not prose: unquote it; a quoted string with a space in it is text: cut it out
subs=$(printf '%s\n' "$text" | sed "s/'[^']*'//g" | grep -o '\$([^)]*)\|`[^`]*`' | tr '\n' ';')
text="$(printf '%s\n' "$text" | sed -E "s/'([^'[:space:]]*)'/\\1/g; s/\"([^\"[:space:]]*)\"/\\1/g; s/'[^']*'/''/g; s/\"[^\"]*\"/\"\"/g");$subs"
b='(^|[^[:alnum:]_.-])'   # a command word starts here
# what a background terminal runs (hc run --bg ...) does not block: cut it out for the blocking checks
# ponytail: everything after `hc run ... --bg` on the joined text is cut, a blocking call chained after it passes
fg=$(printf '%s\n' "$text" | sed -E "s/${b}hc[[:space:]]+run[[:space:]]+([^;&|]*[[:space:]])?--bg([[:space:]].*)?\$/\\1/")
refuse() { echo "org: refused: $1" >&2; exit 2; }
wait_hint='while a shell call runs you take no input. Run it in a background terminal (hc run --bg), or let the skill watch it (org-pull-request: hc wait ci-<pr>), then end the turn in org wait --children, which also returns when the person types (Issue #378)'

printf '%s\n' "$text" | grep -Eq "${b}hc[[:space:]]+(keys([[:space:]]|;|$)|send([[:space:]][^;&|]*)?[[:space:]](--force|-f)([[:space:]]|;|$))" &&
  refuse 'keys reach a worker only through org-escalation.sh prompt or answer, after a fresh screen read (L-N3, Issue #260)'
printf '%s\n' "$fg" | grep -Eq "${b}gh[[:space:]]+(pr[[:space:]]+checks[^;&|]*[[:space:]]--watch|run[[:space:]]+watch)([[:space:]=]|;|$)" &&
  refuse "a CI watch blocks you: $wait_hint"
printf '%s\n' "$fg" | grep -Eq "${b}(while|until|for)[[:space:]].*${b}do([[:space:]]|;)(.*${b})?sleep([[:space:]]|;|$)" &&
  refuse "a polling loop blocks you: $wait_hint"
# sleep: more than 5 seconds, a unit of minutes or more, or infinity
printf '%s\n' "$fg" | grep -Eo "${b}sleep[[:space:]]+[^;&|)\`]*" | sed 's/.*sleep[[:space:]]*//' | tr ' \t' '\n\n' |
  awk '/^[0-9.]+s?$/ { if ($0 + 0 > 5) bad = 1; next } /^[0-9.]+[mhd]$/ || /^inf/ { bad = 1 } END { exit !bad }' &&
  refuse "a sleep over 5 seconds blocks you: $wait_hint"
exit 0
