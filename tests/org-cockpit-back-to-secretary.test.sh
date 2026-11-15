#!/usr/bin/env bash
# Issue #389: a worker peeked from its tile and kept holds the centre. The workers rail always shows
# "Back to the secretary"; one click parks every kept worker (herdr's "Send back": it is a tile
# again) and focuses the secretary's pane, so the secretary is in the centre. gpui-kit and herdr
# are stubs; no app, no core.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
command -v node >/dev/null 2>&1; check "node is available" $?

m=$tmp/m
mkdir -p "$m/node_modules/gpui-kit" "$m/node_modules/gpui-base" "$m/node_modules/herdr"
cp "$here/mods/org-cockpit/main.js" "$m/main.mjs"
for p in gpui-kit gpui-base herdr; do
  printf '{"name":"%s","type":"module","main":"index.js"}\n' "$p" > "$m/node_modules/$p/package.json"
done
cat > "$m/node_modules/gpui-kit/index.js" <<'EOF'
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
cat > "$m/node_modules/gpui-base/index.js" <<'EOF'
import { el } from "gpui-kit";
export const v_flex = () => el("v_flex");
export const h_flex = () => el("h_flex");
// The note field: a state whose value a test sets through globalThis.__note.
export const InputState = { new: () => { let v = ""; const s = { value: () => v, set_value: (x) => { v = x; }, on: () => true }; globalThis.__note = s; return s; } };
export const Input = { new: () => el("input") };
EOF
cat > "$m/node_modules/herdr/index.js" <<'EOF'
const H = globalThis.__h;
export async function exec() { return { code: 0, stdout: JSON.stringify({ jsonrpc: "2.0", id: 1, result: { version: 1, value: H.value } }) + "\n", stderr: "" }; }
export async function hc() { return { code: 0, stdout: "", stderr: "" }; }
export const run = (cmd, args) => { H.runs.push(`${cmd} ${args?.terminal ?? ""}`); };
export const props = () => ({ role: "workers" });
export const settings = () => ({});
export const window = () => ({ platform: "linux" });
export const panes = () => H.panes.map((terminal) => ({ terminal }));
export const terminals = () => H.terms;
export const theme = () => new Proxy({}, { get: () => "#aa5500" });
EOF
# drive <kept addresses> <secretary live: 1|0> <org-state value>: prints the button text, then each run call.
cat > "$m/drive.mjs" <<'EOF'
const [kept, live, value] = [process.argv[2].split(",").filter(Boolean), process.argv[3] === "1", JSON.parse(process.argv[4])];
const terms = [
  { address: "t1", name: "w-a", state: "live", status: "working", labels: { task_id: "a" } },
  { address: "t2", name: "w-b", state: "live", status: "idle", labels: { task_id: "b" } },
];
if (live) terms.push({ address: "t9", name: "secretary", state: "live", status: "idle", labels: { "herdr.space": "paddock" } });
globalThis.__h = { runs: [], panes: [...kept, ...(live ? ["t9"] : [])], terms, value };
const { default: Cockpit } = await import("./main.mjs");
const pending = [];
const cx = { timer: { every() {} }, spawn(fn) { const p = Promise.resolve().then(() => fn(cx)); pending.push(p); return p; }, notify() {} };
const v = new Cockpit();
v.init({}, cx);
for (let i = 0; i < 20 && pending.length; i++) await Promise.allSettled(pending.splice(0));
const text = (n) => (n == null || n === false ? "" : typeof n === "string" ? n : (n.kids || []).map(text).join(" "));
const find = (n) => (n && n.kids ? (n._id === "back-to-secretary" ? n : n.kids.map(find).find(Boolean)) : null);
const b = find(v.render(cx));
if (!b) { console.log("button -"); process.exit(0); }
console.log(`button ${text(b).trim()}`);
b._click();
for (const r of globalThis.__h.runs) console.log(`run ${r}`);
EOF
drive() { (cd "$m" && node drive.mjs "$@" 2>&1); }
runs() { printf '%s\n' "$1" | sed -n 's/^run //p' | tr '\n' ';'; }

out=$(drive "" 1 '{}')
printf '%s\n' "$out" | grep -qx "button Back to the secretary"; check "the button shows with no worker kept ($out)" $?
[ "$(runs "$out")" = "pane.focus t9;" ]; check "nothing kept: one click only focuses the secretary" $?

out=$(drive "t1" 1 '{}')
[ "$(runs "$out")" = "terminal.park t1;pane.focus t9;" ]; check "a kept worker is parked back to its tile, then the secretary focused ($(runs "$out"))" $?

out=$(drive "t1,t2" 1 '{}')
[ "$(runs "$out")" = "terminal.park t1;terminal.park t2;pane.focus t9;" ]; check "every kept worker is parked" $?

out=$(drive "t1" 0 '{}')
printf '%s\n' "$out" | grep -qx "button The secretary is not running" && [ "$(runs "$out")" = "terminal.park t1;" ]
check "secretary down: the button says so, still parks, focuses nothing" $?

out=$(drive "" 1 '{"conversation_lang":"ja"}')
printf '%s\n' "$out" | grep -qx "button 窓口に戻る"; check "lang ja: the button speaks Japanese" $?

[ "$fail" -eq 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
