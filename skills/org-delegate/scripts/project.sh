# Sourced by org-delegate and org-pull-request. Needs awk.
# project_lookup <name>: reads the row named <name> in projects.md and sets project_path, project_secret and
# project_base (empty when the row or the table has no base or secret-block column). Returns 1 when there is no such row
# or its path is empty, 2 when the file is missing. The header row names the columns (name, path,
# base; any order, other columns ignored). projects.md is in the paddock config folder (Q14);
# PADDOCK_PROJECTS_FILE overrides it.
project_lookup() {
  local f=${PADDOCK_PROJECTS_FILE:-} cfg row
  if [ -z "$f" ]; then
    cfg=${XDG_CONFIG_HOME:-$HOME/.config}
    [ -n "${APPDATA:-}" ] && cfg=$APPDATA # Windows (Git Bash), as org-start
    f=$cfg/paddock/projects.md
  fi
  [ -f "$f" ] || return 2
  row=$(awk -F'|' -v want="$1" '
    function trim(s) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
    !hdr && /^[ \t]*\|/ { for (i = 2; i < NF; i++) c[tolower(trim($i))] = i; hdr = (c["name"] && c["path"]); next }
    hdr && /^[ \t]*\|/ && trim($(c["name"])) == want {
      print trim($(c["path"])) "\t" (c["base"] ? trim($(c["base"])) : "") "\t" (c["secret-block"] ? trim($(c["secret-block"])) : ""); found = 1; exit }
    END { exit !found }' "$f") || return 1
  project_path=${row%%$'\t'*}
  project_base=${row#*$'\t'}; project_secret=${project_base#*$'\t'}; project_base=${project_base%%$'\t'*}
  [ -n "$project_path" ]
}
