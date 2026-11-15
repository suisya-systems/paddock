# Claude Code's folder-trust dialog on the secretary's own working folder, shared by org-start and
# secretary-handover. Source it (POSIX sh); it defines a function only. Q13 (a): answered only for the
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
