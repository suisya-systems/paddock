#!/bin/sh
# Premise reminder (Issue #219, inventory HK-10): a UserPromptSubmit hook for the secretary. It also
# records the person's chat-line token (Issue #444, below).
# When the person's prompt carries a number with a unit, a setting name or a claim about behaviour,
# print one line (Claude Code adds hook stdout to the turn): read or search once and cite a source
# before agreeing or disagreeing. Never blocks: every path exits 0, an unreadable payload prints nothing.
# ponytail: the prompt string is cut out of the payload with sed (no JSON parser in plain shell); \uXXXX
# escapes stay as written. The reminder is a hint, a miss costs nothing.
prompt=$(sed -n 's/.*"prompt" *: *"\(\([^"\\]\|\\.\)*\)".*/\1/p' 2>/dev/null) || exit 0
# Issue #444: a line the person typed moves the token in <state>/secretary/person-line, which a hidden
# proposal of the secretary's own (org-escalation ask --self) compares with the one it recorded: a
# moved token withdraws it. The watcher's wake line and a secretary's first message (org-start,
# secretary-handover) are not the person. The token is unique per line (time in ns and the pid).
# ponytail: any other text sent into the secretary with hc send counts as the person.
case $prompt in
  ''|'You have mail: run '*|'You are the secretary of a paddock organization.'*) ;;
  *) d=${PADDOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/paddock}/secretary
     mkdir -p "$d" 2>/dev/null && printf '%s-%s\n' "$(date -u +%Y%m%dT%H%M%S%N)" "$$" > "$d/person-line.new" 2>/dev/null \
       && mv -f "$d/person-line.new" "$d/person-line" 2>/dev/null ;;
esac
printf '%s\n' "$prompt" | LC_ALL=C grep -Eiq '[0-9](\.[0-9]+)? ?(%|(ms|s|sec|secs|seconds?|min|mins|minutes?|h|hours?|days?|[kmgt]i?b|px|x|times|retries|workers?|lines?|files?)\b)|\b[A-Z][A-Z0-9]*_[A-Z0-9_]+\b|--[a-z][a-z-]+|\b[a-z]+\.[a-z]+\.[a-z.]+|\b(always|never|by default|defaults? to|ignores?|doesn.t|does not|only when|is safe|will (fail|not|retry))\b|(デフォルト|必ず|常に|仕様|のはず)' 2>/dev/null || exit 0
echo "Premise check: the message states a number, a setting or a behaviour. Verify before agreeing or disagreeing: read or search once and cite the source."
exit 0
