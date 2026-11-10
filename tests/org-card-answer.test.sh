#!/usr/bin/env bash
# Acceptance test for answering an approval from its card (Issue #65).
# herdr-app is not available in CI, so the mod (mods/org-cockpit/main.js, role "approval")
# runs under node with stub "gpui-kit", "gpui-base" and "herdr" modules. The stub `exec`
# answers the org-state read itself and runs every other command for real, so the answer
# goes through the real scripts/org into a temporary mailbox.
# Checked: a click on the card's Yes / No sends `ANSWER <approval id> yes|no` from `person`
# to `secretary` through the mailbox, for the oldest approval; a second click sends nothing
# more; the mod never writes org-state; the card is gone once the secretary removes the entry.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

# org is where org-start places it: <herdr-core templates>/org.
export XDG_CONFIG_HOME=$tmp/config HOME=$tmp/home
mkdir -p "$XDG_CONFIG_HOME/herdr-core/templates" "$HOME"
cp "$here/scripts/org" "$XDG_CONFIG_HOME/herdr-core/templates/org"
unset PADDOCK_CORE_TEMPLATES_DIR PADDOCK_ORG_ID

# The mod with its imports resolved from stub packages beside it.
mkdir -p "$tmp/m/node_modules/gpui-kit" "$tmp/m/node_modules/gpui-base" "$tmp/m/node_modules/herdr"
cp "$here/mods/org-cockpit/main.js" "$tmp/m/main.mjs"
for p in gpui-kit gpui-base herdr; do
  printf '{"name":"%s","type":"module","main":"index.js"}\n' "$p" > "$tmp/m/node_modules/$p/package.json"
done
cat > "$tmp/m/node_modules/gpui-kit/index.js" <<'EOF'
// An element records its children, id and click handler; every other style call is a no-op.
export class View {}
export function el(kind) {
  const e = { kind, kids: [], _id: null, _click: null };
  const p = new Proxy(e, {
    get(t, k) {
      if (k in t) return t[k];
      if (k === "then" || typeof k === "symbol") return undefined;
      return (...a) => {
        if (k === "child") t.kids.push(a[0]);
        else if (k === "children") t.kids.push(...a[0]);
        else if (k === "when") { if (a[0]) a[1](p); }
        else if (k === "id") t._id = a[0];
        else if (k === "on_click") t._click = a[0];
        return p;
      };
    },
  });
  return p;
}
export const div = () => el("div");
export const svg = () => el("svg");
EOF
cat > "$tmp/m/node_modules/gpui-base/index.js" <<'EOF'
import { el } from "gpui-kit";
export const v_flex = () => el("v_flex");
export const h_flex = () => el("h_flex");
EOF
cat > "$tmp/m/node_modules/herdr/index.js" <<'EOF'
import { spawnSync } from "node:child_process";
const H = globalThis.__h;
export async function exec(cmd, args = [], opts = {}) {
  H.calls.push([cmd, ...args].join(" "));
  if (args.join(" ").includes("hc connect")) // the org-state read
    return { code: 0, stdout: JSON.stringify({ jsonrpc: "2.0", id: 1, result: H.doc }) + "\n", stderr: "" };
  const r = spawnSync(cmd, args, { encoding: "utf8" });
  return { code: r.status, stdout: r.stdout, stderr: r.stderr };
}
export async function hc() { return { code: 0, stdout: "", stderr: "" }; }
export const run = (...a) => { H.runs.push(a); };
export const props = () => ({ role: "approval" });
export const settings = () => ({});
export const window = () => ({ platform: "linux" });
export const panes = () => [];
export const terminals = () => [
  { address: "t1", name: "w-task-a", state: "live", status: "blocked", labels: { task_id: "task-a" } },
  { address: "t2", name: "w-task-b", state: "live", status: "blocked", labels: { task_id: "task-b" } },
  { address: "t9", name: "secretary", state: "live", status: "working", labels: {} },
];
export const theme = () => new Proxy({}, { get: () => "#aa5500" });
EOF

# drive <answer>: render the card, click the button whose text starts with <answer> twice,
# then remove the approvals and refresh. Prints one result line per step for the checks.
cat > "$tmp/m/drive.mjs" <<'EOF'
const answer = process.argv[2];
const OLD = "task-a-20261110T090000Z", NEW = "task-b-20261110T091500Z";
globalThis.__h = { calls: [], runs: [], doc: { version: 3, value: { work: [], approvals: [
  { id: NEW, task_id: "task-b", question: "Merge PR 12?", asked_at: "2026-11-10T09:15:00Z" },
  { id: OLD, task_id: "task-a", question: "Allow npm install?", asked_at: "2026-11-10T09:00:00Z" },
] } } };
const { default: Cockpit } = await import("./main.mjs");
const pending = [];
const cx = { timer: { every() {} }, spawn(fn) { const p = Promise.resolve().then(() => fn(cx)); pending.push(p); return p; }, notify() {} };
const settle = async () => { for (let i = 0; i < 50; i++) { await Promise.allSettled(pending.splice(0)); await new Promise((r) => setTimeout(r, 20)); if (!pending.length) return; } };
const text = (n) => (n == null || n === false ? "" : typeof n === "string" || typeof n === "number" ? String(n) : (n.kids || []).map(text).join(""));
const all = (n, out = []) => { if (n && typeof n === "object" && n.kids) { out.push(n); n.kids.forEach((k) => all(k, out)); } return out; };
const button = (tree, word) => all(tree).find((n) => n._click && new RegExp(`^\\s*${word}\\b`, "i").test(text(n)));

const v = new Cockpit();
v.init({}, cx);
await settle();
let tree = v.render(cx);
const b = button(tree, answer);
console.log(`button ${b ? "found" : "missing"}`);
console.log(`open ${button(tree, "Open") ? "found" : "missing"}`);
if (b) {
  // A double click: the second must send nothing (the card may meanwhile show the next approval).
  b._click({}, {}, cx); b._click({}, {}, cx); await settle();
  b._click({}, {}, cx); await settle();
}
console.log(`writes ${globalThis.__h.calls.filter((c) => /doc\.set|\bdoc (set|update)\b/.test(c)).length}`);
globalThis.__h.doc = { version: 4, value: { work: [], approvals: [] } };
v.refresh(cx); await settle();
tree = v.render(cx);
console.log(`after-removal ${["Yes", "No"].some((w) => button(tree, w)) ? "buttons" : "none"}`);
EOF

run_case() { # run_case <answer>
  export PADDOCK_STATE_DIR=$tmp/state-$1
  out=$(cd "$tmp/m" && node drive.mjs "$1" 2>&1)
  echo "$out" | grep -q '^button found$'; check "$1: the approval card has a $1 button" $?
  echo "$out" | grep -q '^open found$'; check "$1: the card still has an Open control (the secretary's pane, Issue #127)" $?
  msgs=$(bash "$here/scripts/org" --as secretary check_messages --peek 2>&1)
  n=$(printf '%s\n' "$msgs" | grep -c '^\[person#')
  [ "$n" -eq 1 ]; check "$1: exactly one message reaches the secretary, even after more clicks (got $n)" $?
  printf '%s\n' "$msgs" | grep -qx "ANSWER task-a-20261110T090000Z $2"
  check "$1: it reads 'ANSWER <oldest approval id> $2'" $?
  echo "$out" | grep -q '^writes 0$'; check "$1: the mod never writes org-state" $?
  echo "$out" | grep -q '^after-removal none$'; check "$1: the card is gone once the secretary removes the entry" $?
  [ "$fail" -eq 0 ] || printf '%s\n%s\n' "$out" "$msgs" | sed 's/^/     | /'
}

command -v node >/dev/null 2>&1; check "node is available" $?
run_case Yes yes
run_case No no

exit $fail
