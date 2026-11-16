#!/bin/sh
# Secretary guard: a PreToolUse hook on Bash, Read, Grep, Glob and Agent (templates/secretary-settings.json). Exit 2 with a reason
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
refuse() { echo "org: refused: $1" >&2; exit 2; }

# Repository guard (Read, Grep, Glob, Agent and Bash): a folder under $HOME is the person's own unless it is
# paddock's (state, checkout, projects, workers, local, bin, config, ~/.claude, $TMPDIR) or a path in projects.md.
# ponytail: paths are matched as text: ~/x, $HOME/x, ${HOME}/x and the literal home path. A relative path, a cd
# chain or a path built in a variable slips through. Read, Grep and Glob: their path fields, whole; Agent: the
# words of its prompt (a path with a space in a prompt is cut at the space); Bash: the words, and quoted arguments whole.
H=${HOME%/}
cfg=${XDG_CONFIG_HOME:-$H/.config}; [ -n "${APPDATA:-}" ] && cfg=$APPDATA
roots="${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$H/.local/state}/paddock}
${PADDOCK_HOME:-}
${PADDOCK_PROJECTS_DIR:-$H/paddock-projects}
${PADDOCK_WORKERS_DIR:-$H/paddock-workers}
${PADDOCK_LOCAL_DIR:-$H/paddock-local}
${PADDOCK_BIN_DIR:-${XDG_DATA_HOME:-$H/.local/share}/paddock/bin}
$cfg/paddock
$H/.claude
${TMPDIR:-}
${CLAUDE_TMPDIR:-}
$(awk -F'|' 'function t(s) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
  !h && /^[ \t]*\|/ { for (i = 2; i < NF; i++) if (tolower(t($i)) == "path") p = i; h = p; next }
  h && /^[ \t]*\|/ && t($p) ~ /^[\/~]/ { print t($p) }' "${PADDOCK_PROJECTS_FILE:-$cfg/paddock/projects.md}" 2>/dev/null)"
hp="(~|\\\$HOME|\\\$\{HOME\}|$H)"   # a home prefix, matched only when / or the end follows it
exempt='s#scripts/org[^;&|]*[[:space:]]config[[:space:]]+project[^;&|]*##g'   # registering a path names it
# toks <text>: the words that start with a home prefix (a=~/x and --dir=~/x too), one per line
toks() { printf '%s\n' "$1" | tr -s "[:space:];&|<>()\`'\",\\\\" '\n' | grep -oE "(^|[^[:alnum:]_.\$/~-])$hp(/.*)?\$" | sed -E 's#^[^~$/]##'; }
# whole: the input lines that are a path from their start (a quoted argument or a tool field: spaces kept)
whole() { grep -E "^$hp(/|\$)"; }
path_guard() { # path_guard < paths: refuse the first one under $HOME outside the roots
  [ -n "$H" ] || return 0
  sed -E "s#^(~|\\\$HOME|\\\$\{HOME\})#$H#" |
    { r=$(printf '%s\n' "$roots" | sed "s#^~#$H#; s#/*\$##" | grep .)
      IFS='
'
      while read -r p; do
        case /$p/ in */../*) echo "$p"; return ;; esac
        p=${p%/}; ok=
        for x in $r; do case $p/ in "$x"/*) ok=1; break ;; esac; done
        [ -n "$ok" ] || { echo "$p"; return; }
      done; } |
    { read -r bad || return 0
      echo "org: refused: $bad is the person's own folder, not in projects.md: never read, search or change it. For a repository run paddock:org-clone (OWNER/NAME); a path the person named goes in with config project add" >&2; return 1; }
}
case $payload in
  *'"tool_name"'*) tool=$(printf '%s\n' "$payload" | sed -n 's/.*"tool_name" *: *"\([^"]*\)".*/\1/p') ;;
  *) tool=Bash ;;
esac
case $tool in
  Bash) ;;
  Agent) toks "$payload" | path_guard || exit 2; exit 0 ;;
  *) printf '%s\n' "$payload" | grep -oE '"(file_path|path|pattern|notebook_path)" *: *"([^"\\]|\\.)*"' |
       sed -E 's/^"[^"]*" *: *"//; s/"$//' | whole | path_guard || exit 2; exit 0 ;;
esac

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
quoted=$(printf '%s\n' "$text" | sed -E "$exempt" | grep -oE "\"[^\"]*\"|'[^']*'" | sed -E 's/^.(.*).$/\1/')
subs=$(printf '%s\n' "$text" | sed "s/'[^']*'//g" | grep -o '\$([^)]*)\|`[^`]*`' | tr '\n' ';')
text="$(printf '%s\n' "$text" | sed -E "s/'([^'[:space:]]*)'/\\1/g; s/\"([^\"[:space:]]*)\"/\\1/g; s/'[^']*'/''/g; s/\"[^\"]*\"/\"\"/g");$subs"
b='(^|[^[:alnum:]_.-])'   # a command word starts here
# what a background terminal runs (hc run --bg ...) does not block: cut it out for the blocking checks
# ponytail: everything after `hc run ... --bg` on the joined text is cut, a blocking call chained after it passes
fg=$(printf '%s\n' "$text" | sed -E "s/${b}hc[[:space:]]+run[[:space:]]+([^;&|]*[[:space:]])?--bg([[:space:]].*)?\$/\\1/")
wait_hint='while a shell call runs you take no input. Run it in a background terminal (hc run --bg), or let the watcher watch CI (org-pull-request writes ci_requested), then end the turn: the watcher wakes you on mail (decision 0013)'

printf '%s\n' "$text" | grep -Eq "${b}hc[[:space:]]+(keys([[:space:]]|;|$)|send([[:space:]][^;&|]*)?[[:space:]](--force|-f)([[:space:]]|;|$))" &&
  refuse 'keys reach a worker only through org-escalation.sh prompt or answer, after a fresh screen read (L-N3, Issue #260)'
printf '%s\n' "$fg" | grep -Eq "${b}gh[[:space:]]+(pr[[:space:]]+checks[^;&|]*[[:space:]]--watch|run[[:space:]]+watch)([^[:alnum:]_-]|$)" &&
  refuse "a CI watch blocks you: $wait_hint"
printf '%s\n' "$fg" | grep -Eq "${b}(while|until|for)[[:space:]].*${b}do([[:space:]]|;)(.*${b})?sleep([[:space:]]|;|$)" &&
  refuse "a polling loop blocks you: $wait_hint"
# sleep: more than 5 seconds, a unit of minutes or more, or infinity
# (GNU sleep adds its arguments: one line per sleep call, summed)
printf '%s\n' "$fg" | grep -Eo "${b}sleep[[:space:]]+[^;&|)\`]*" | sed 's/.*sleep[[:space:]]*//' |
  awk '{ t = 0; for (i = 1; i <= NF; i++) { v = $i; u = 1; if (v ~ /^inf/) t += 1e9
           else if (v ~ /^[0-9.]+[smhd]?$/) { if (v ~ /m$/) u = 60; else if (v ~ /h$/) u = 3600; else if (v ~ /d$/) u = 86400; t += (v + 0) * u } }
         if (t > 5) bad = 1 } END { exit !bad }' &&
  refuse "a sleep over 5 seconds blocks you: $wait_hint"
{ printf '%s\n' "$quoted" | grep '[[:space:]]' | whole; toks "$(printf '%s\n' "$text" | sed -E "$exempt")"; } | path_guard || exit 2
exit 0
