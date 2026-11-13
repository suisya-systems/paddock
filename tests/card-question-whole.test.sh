#!/usr/bin/env bash
# Acceptance test for Issue #306: the approval card shows the whole question. In Run 7 it stopped at
# "May the worker add paddock-proto3.txt at the repository root of", so the person could not tell
# what was being decided. Every surface that draws the question (the cockpit's approval card, the
# cockpit's "secretary is asking you" band, the org-agents card) must wrap it without a height
# limit: no max_h / h and no overflow_hidden on the text or on anything around it.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
command -v node >/dev/null 2>&1; check "node is available" $?

Q='May the worker add paddock-proto3.txt at the repository root of the throwaway fixture repository, and nothing else?'

for mod in org-cockpit org-agents; do
  m=$tmp/$mod; mkdir -p "$m/node_modules/gpui-kit" "$m/node_modules/gpui-base" "$m/node_modules/herdr"
  cp "$here/mods/$mod/main.js" "$m/main.mjs"
  for p in gpui-kit gpui-base herdr; do
    printf '{"name":"%s","type":"module","main":"index.js"}\n' "$p" > "$m/node_modules/$p/package.json"
  done
  cat > "$m/node_modules/gpui-kit/index.js" <<'EOF'
export class View {}
export function el(kind) {
  const e = { kind, kids: [], calls: [] };
  const p = new Proxy(e, {
    get(t, k) {
      if (k in t) return t[k];
      if (k === "then" || typeof k === "symbol") return undefined;
      return (...a) => {
        t.calls.push(k);
        if (k === "child") t.kids.push(a[0]);
        else if (k === "children") t.kids.push(...a[0]);
        else if (k === "when") { if (a[0]) a[1](p); }
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
EOF
  cat > "$m/node_modules/herdr/index.js" <<'EOF'
const H = globalThis.__h;
export async function exec() {
  return { code: 0, stdout: JSON.stringify({ jsonrpc: "2.0", id: 1, result: H.doc }) + "\n", stderr: "" };
}
export async function hc() { return { code: 0, stdout: "", stderr: "" }; }
export const run = () => {};
export const props = () => ({ role: process.env.ROLE });
export const settings = () => ({});
export const window = () => ({ platform: "linux" });
export const panes = () => [];
export const terminals = () => H.terminals;
export const theme = () => new Proxy({}, { get: () => "#aa5500" });
EOF
done

# drive <mod> <role> <terminals json>: render, then print "text <all text>" and "clamped <n>" where n counts
# the clamps (max_h, h, overflow_hidden) on the question's own node and every ancestor.
cat > "$tmp/drive.mjs" <<'EOF'
const [dir, q, terms] = process.argv.slice(2);
const entry = { id: "t-1", task_id: "t", question: q, asked_at: "2026-11-13T09:00:00Z" };
globalThis.__h = { terminals: JSON.parse(terms), doc: { version: 3, value: { work: [], approvals: [entry] } } };
const { default: Mod } = await import(`${dir}/main.mjs`);
const pending = [];
const cx = { timer: { every() {} }, spawn(fn) { const p = Promise.resolve().then(() => fn(cx)); pending.push(p); return p; }, notify() {} };
const v = new Mod();
v.init({}, cx);
for (let i = 0; i < 20; i++) { await Promise.allSettled(pending.splice(0)); await new Promise((r) => setTimeout(r, 20)); }
const tree = v.render(cx);
const text = (n) => (n == null || n === false ? "" : typeof n === "string" || typeof n === "number" ? String(n) : (n.kids || []).map(text).join(" "));
const CLAMP = new Set(["max_h", "h", "overflow_hidden"]);
let clamped = -1;
const walk = (n, inherited) => {
  if (!n || typeof n !== "object" || !n.kids) return;
  const own = inherited + n.calls.filter((c) => CLAMP.has(c)).length;
  if (n.kids.some((k) => k === q)) clamped = own;
  n.kids.forEach((k) => walk(k, own));
};
walk(tree, 0);
console.log(`text ${text(tree).replace(/\s+/g, " ")}`);
console.log(`clamped ${clamped}`);
EOF

run() { (cd "$tmp" && ROLE=$2 node drive.mjs "$tmp/$1" "$Q" "$3" 2>&1); }
SEC='[{"address":"t9","name":"secretary","state":"live","status":"blocked","labels":{},"report":{"msg":"'"$Q"'"}}]'
NONE='[]'

out=$(run org-cockpit approval "$NONE")
grep -qF "$Q" <<<"$out"; check "cockpit approval card: the whole question is in the card" $?
grep -q '^clamped 0$' <<<"$out"; check "cockpit approval card: no height limit on the question" $?

out=$(run org-cockpit consult "$SEC")
grep -qF "$Q" <<<"$out"; check "cockpit consult band: the whole question is in the band" $?
grep -q '^clamped 0$' <<<"$out"; check "cockpit consult band: no height limit on the question" $?
[ "$fail" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/     | /'

out=$(run org-agents x "$NONE")
grep -qF "$Q" <<<"$out"; check "org-agents card: the whole question is in the card" $?
grep -q '^clamped 0$' <<<"$out"; check "org-agents card: no height limit on the question" $?
[ "$fail" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/     | /'
exit $fail
