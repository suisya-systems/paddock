# Claude Code's folder-trust dialog on the secretary's own working folder, shared by org-start and
# secretary-handover. Source it (POSIX sh); it defines functions only. td_answer, Q13 (a): answered only for the
# secretary's own folder, never for a worktree; the cursor is checked on the screen before Enter
# (the dialog's default is "No, exit").
# td_answer NAME: 0 answered, 1 no dialog on the screen, 2 the cursor did not reach "Yes" (nothing confirmed).
td_answer() {
  hc read "$1" 2>/dev/null | grep -Eq 'Quick safety check|Yes, I trust this folder' || return 1
  hc keys "$1" down >/dev/null 2>&1; sleep 1
  hc read "$1" 2>/dev/null | grep -q '❯.*Yes, I trust this folder' || return 2
  hc keys "$1" enter >/dev/null 2>&1
  return 0
}
# Current Claude Code reports a status while the dialog is up (hc 0.1.20: blocked, kind permission, msg
# "trust this folder"), so "has a status" alone does not mean started. resend.sh and org-escalation use these too.
# td_trust_status JSON: the one-line `hc get --json` output holds that status. A tool prompt's blocked one does not.
td_trust_status() {
  printf '%s' "$1" | grep -Eq '"state": *"blocked"' && printf '%s' "$1" | grep -Eq '"kind": *"permission"' \
    && printf '%s' "$1" | grep -Eqi '"msg": *"[^"]*trust this folder'
}
# td_started NAME: NAME reports a status, and it is not the folder-trust one.
td_started() {
  td_j=$(hc get --json "$1" 2>/dev/null | tr -d '\n')
  printf '%s' "$td_j" | grep -Eq '"status": *\{' && ! td_trust_status "$td_j"
}
