# Sourced by the host probes that start claude (Issue #212). claude relinks ~/.local/bin/claude
# to the data folder it runs with; a probe must leave the host's link as it found it.
#   . "$(dirname "$0")/claude-link.sh"; claude_link_save    # before claude starts
#   claude_link_restore                                     # first line of the exit-trap cleanup
# claude_link_save also installs a minimal EXIT trap, so an early exit restores too; a probe's
# own later `trap cleanup EXIT` replaces it and calls claude_link_restore itself.
claude_link_save() {
  CLAUDE_LINK=$HOME/.local/bin/claude
  CLAUDE_LINK_WAS=$(readlink "$CLAUDE_LINK" 2>/dev/null)
  trap claude_link_restore EXIT; trap 'exit 130' INT TERM
}
claude_link_restore() {
  [ -n "${CLAUDE_LINK:-}" ] || return 0
  _now=$(readlink "$CLAUDE_LINK" 2>/dev/null)
  [ "$_now" = "$CLAUDE_LINK_WAS" ] && return 0
  echo "RESULT claude-link: FAIL (was '$CLAUDE_LINK_WAS', now '$_now')"
  if [ -n "$CLAUDE_LINK_WAS" ]; then ln -sfn "$CLAUDE_LINK_WAS" "$CLAUDE_LINK" && echo "   restored $CLAUDE_LINK -> $CLAUDE_LINK_WAS"; fi
}
