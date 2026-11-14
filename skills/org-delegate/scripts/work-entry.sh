# Sourced by org-delegate.sh and resend.sh: the work entry of a delegated task in org-state.
# work_entry_json <task_id> <title> <since> <worktree> <task>: the entry, one line of JSON (strings escaped).
work_entry_json() {
  esc() { printf '%s\n' "$1" | tr -d '\000-\010\013\014\016-\037' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$(printf '\t')/\\\\t/g" -e "s/$(printf '\r')/\\\\r/g" \
    | awk 'NR>1{printf "%s","\\n"} {printf "%s",$0}'; }
  printf '{"task_id":"%s","title":"%s","since":"%s","worktree":"%s","task":"%s"}' "$1" "$(esc "$2")" "$3" "$(esc "$4")" "$(esc "$5")"
}
# work_entry_add <scripts/org path> <task_id> <entry>: add the entry at the end of "work" by a scan that skips string
# contents, so braces and brackets in the task do not matter. Status 0 when written.
work_entry_add() {
  ENTRY=$3 bash "$1" --as secretary doc update org-state --record work_added --task "$2" --text "$3" -- awk '
    { s = s $0 "\n" }
    END {
      e = ENVIRON["ENTRY"]
      if (s ~ /^[ \t\n]*(null)?[ \t\n]*$/) { printf "{\"work\":[%s],\"approvals\":[]}", e; exit }
      if (!match(s, /"work": *\[/)) {
        p = index(s, "{"); r = substr(s, p + 1)
        printf "%s\"work\":[%s]%s%s", substr(s, 1, p), e, (r ~ /^[ \t\n]*\}/ ? "" : ","), r; exit }
      a = RSTART + RLENGTH; n = length(s); q = 0; d = 1
      for (i = a; i <= n; i++) { c = substr(s, i, 1)
        if (q) { if (c == "\\") i++; else if (c == "\"") q = 0; continue }
        if (c == "\"") q = 1; else if (c == "[") d++; else if (c == "]" && --d == 0) break }
      printf "%s%s%s%s", substr(s, 1, i - 1), (substr(s, a, i - a) ~ /[^ \t\n]/ ? "," : ""), e, substr(s, i) }' >/dev/null 2>&1
}
