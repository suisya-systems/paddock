# First-run checks shared by org-start (and --check), prototype-3.sh prepare and prototype-3-setup.sh
# (Issue #328, decision 0007). Source it (POSIX sh); it defines functions only and runs nothing.
# Every check is read-only: it never writes the core's config (L-N1) and never calls hc.

# fr_trusted DIR: is DIR itself recorded as trusted in the agent's config? Not a folder above it: trust
# follows the git repository (Q13, reopened). The key is not a documented interface.
# ponytail: braces inside strings are not skipped; fine for this file.
fr_trusted() {
  fr_cf=${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json
  [ -r "$fr_cf" ] || return 1
  fr_d=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  tr '\n\r' '  ' < "$fr_cf" | awk -v k="\"$fr_d\"" '{
      s = $0; i = index(s, k); if (!i) exit 1
      j = i + length(k); while (substr(s, j, 1) == " ") j++
      if (substr(s, j, 1) != ":") exit 1
      j++; while (substr(s, j, 1) == " ") j++
      if (substr(s, j, 1) != "{") exit 1
      depth = 0
      for (n = j; n <= length(s); n++) { c = substr(s, n, 1)
        if (c == "{") depth++; else if (c == "}") { depth--; if (depth == 0) break } }
      exit (substr(s, j, n - j + 1) ~ /"hasTrustDialogAccepted" *: *true/) ? 0 : 1 }'
}

# fr_notes_ok CONFDIR: Issue #264 (decision 0002). Only config.toml counts (the file the core reads), and
# only its top level: lines before the first [table] heading. On failure FR_NOTES_FIX holds the fix.
fr_notes_ok() {
  awk '/^[[:space:]]*\[/{exit} /^[[:space:]]*notes[[:space:]]*=[[:space:]]*false([[:space:]#]|$)/{f=1} END{exit !f}' "$1/config.toml" 2>/dev/null && return 0
  FR_NOTES_FIX="add the line 'notes = false' at the top of $1/config.toml, then restart the core if the change does not take effect (org-start does not write it)"
  return 1
}

# fr_core_path: Issue #305. Every terminal takes the running core's PATH; without hc's folder on it the
# hooks exit 127 and no approval card appears. Read from <proc>/<core pid>/environ (Linux and WSL only),
# never from this shell's PATH (the Run 6 case) and with no hc call. PADDOCK_PROC_DIR replaces /proc in tests.
# Returns 0 hc is on the core's PATH, 1 it is not (FR_PATH_FIX), 2 cannot tell (FR_PATH_WHY).
fr_core_path() {
  fr_pid=$(pgrep -f '(^|/)herdr-core serve' 2>/dev/null | head -n 1)
  if [ -z "$fr_pid" ]; then
    FR_PATH_WHY="no core is running; the first hc command starts one from this shell"; return 2
  fi
  fr_cpath=$(tr '\0' '\n' < "${PADDOCK_PROC_DIR:-/proc}/$fr_pid/environ" 2>/dev/null | sed -n 's/^PATH=//p')
  if [ -z "$fr_cpath" ]; then
    FR_PATH_WHY="the core's environment is not readable here (/proc/<pid>/environ exists on Linux and WSL only), so its PATH was not checked"; return 2
  fi
  PATH=$fr_cpath command -v hc >/dev/null 2>&1 && return 0
  fr_hcdir=$(dirname "$(command -v hc)")
  FR_PATH_FIX="hc is not on the core's PATH (hc is in $fr_hcdir), so its terminals cannot run hc and no approval card appears: stop herdr-core, then start herdr again from a login shell that has that folder on PATH"
  return 1
}
