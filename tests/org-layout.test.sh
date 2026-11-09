#!/usr/bin/env bash
# Acceptance test for the organization layout (layouts/paddock.json) and its mods.
# herdr-app is not available in CI (`herdr-app check` needs a display), so this checks
# the shape the screen depends on (docs/design/architecture.md section 7) with bash
# and node, which CI already uses for the mod check. `herdr-app check` and a
# screenshot are the host-side checks.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
layout=$here/layouts/paddock.json
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
# q <js expression over L (the layout) and nodes (every node and float)>: exit 0 when truthy.
q() {
  node -e '
    const fs = require("fs");
    const L = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const nodes = [];
    (function walk(n) { nodes.push(n); (n.children || []).forEach(walk); (n.floating || []).forEach(walk); })(L);
    const mod = (n, role) => n.content && n.content.mod && (!role || (n.content.props || {}).role === role);
    const term = (n) => n.content && ((typeof n.content.terminal === "string" && n.content.terminal.length > 0) || n.content.tab === "active");
    const within = (n, pred) => { const s = []; (function w(x) { s.push(x); (x.children || []).forEach(w); (x.floating || []).forEach(w); })(n); return s.some(pred); };
    process.exit(eval(process.argv[2]) ? 0 : 1);
  ' "$layout" "$1" 2>/dev/null
}

[ -f "$layout" ]; check "layouts/paddock.json exists" $?
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$layout" 2>/dev/null
check "layout parses as JSON" $?

# Ids are unique (commands address nodes by id).
q 'new Set(nodes.map((n) => n.id)).size === nodes.length && nodes.every((n) => n.id)'
check "every node has a unique id" $?

# Dark theme.
q '["graphite", "ink", "moss"].includes(L.theme)'
check "root sets a dark theme" $?

# No borders: no node draws a border or a divider, and the theme border colour (used by the
# floating frame) is transparent.
q '!nodes.some((n) => (n.border && n.border.width > 0) || (n.divider && n.divider.width > 0))'
check "no node has a border or divider" $?
q '!nodes.some((n) => { const f = n.content && n.content.pane; return f && ((f.border && f.border.width > 0) || (f.focus && f.focus.width > 0)); })'
check "no pane frame has a border" $?
q '/^#[0-9a-fA-F]{6}00$/.test((L.colors || {}).border || "")'
check "theme border colour is transparent" $?

# Regions, left to right: worker tiles, the secretary terminal, then the approval card.
# The secretary is shown by a terminal block or by the active-tab block (the secretary's pane
# adopted through its herdr.space / herdr.tab labels).
q 'L.type === "row" && L.children.length >= 3'
check "root is a row of at least three regions" $?
q 'within(L.children[0], (n) => mod(n, "workers"))'
check "left region holds the worker tiles (role workers)" $?
q 'L.children.slice(1, -1).some((c) => within(c, term))'
check "centre region shows a terminal (terminal block or active tab: the secretary)" $?
q 'L.children.slice(1, -1).some((c) => within(c, term) && !(c.size && c.size.px))'
check "secretary takes the remaining width (no fixed px size)" $?
q 'within(L.children[L.children.length - 1], (n) => mod(n, "approval"))'
check "right region holds the approval card (role approval)" $?

# Consults float over the window.
q 'nodes.some((n) => (n.floating || []).some((f) => mod(f, "consult")))'
check "the secretary's questions are a floating block (role consult)" $?

# Every mod the layout names is in the repository, parses, and handles its role.
mods=$(node -e '
  const L = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const out = new Set();
  (function walk(n) { if (n.content && n.content.mod) out.add(n.content.mod + " " + ((n.content.props || {}).role || ""));
    (n.children || []).forEach(walk); (n.floating || []).forEach(walk); })(L);
  console.log([...out].join("\n"));
' "$layout" 2>/dev/null)
[ -n "$mods" ]; check "the layout names at least one mod" $?
while read -r name role; do
  [ -n "$name" ] || continue
  d=$here/mods/$name
  case "$name" in org-*) true ;; *) false ;; esac; check "mod $name is paddock's own (mods/org-*)" $?
  [ -f "$d/main.js" ] && [ -f "$d/mod.json" ]; check "mods/$name has main.js and mod.json" $?
  node -e 'const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.exit(m.place === "none" ? 0 : 1)' "$d/mod.json" 2>/dev/null
  check "mods/$name/mod.json parses and places nothing by itself" $?
  node --check "$d/main.js" 2>/dev/null; check "mods/$name/main.js parses" $?
  if [ -n "$role" ]; then
    grep -q "\"$role\"" "$d/main.js" 2>/dev/null; check "mods/$name/main.js handles role $role" $?
  fi
done <<<"$mods"

# The docs point at the layout.
grep -q 'layouts/paddock.json' "$here/README.md"; check "README points at layouts/paddock.json" $?
grep -q 'layouts/paddock.json' "$here/docs/design/prototype-1.md"; check "prototype-1 points at layouts/paddock.json" $?
grep -q 'herdr.space=paddock' "$here/README.md"; check "README names the labels that bring the secretary into the centre" $?

exit $fail
