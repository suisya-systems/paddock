#!/usr/bin/env bash
# Acceptance test for Issue #284: the approval card is in the person's conversation language.
#   org-escalation ask takes --lang <code> and keeps it in the approval entry; the cockpit card's
#   fixed words (title, Recommended, waiting, "Not written", ...) follow it; an entry without a
#   language (or with one the mod has no words for) keeps the English card.
#   The secretary template resolves `auto` from the language the person writes in, not from the
#   locale, and says the card text is written in the conversation language.
# Harness: the stubs of org-escalation-context.test.sh (hc documents only; mod under node).
#   The secretary template and the org-escalation skill name the fields.
# The mod runs under node with stub "gpui-kit", "gpui-base" and "herdr" modules (as in
# org-card-who-answers.test.sh); the stub also records every style call, so the test can tell
# a cut text (truncate, max_h) from one that scrolls. hc is a documents-only stub.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

# ---- org-escalation ask: the fields and their checks --------------------------

script=$here/skills/org-escalation/scripts/org-escalation.sh
stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF'
#!/bin/sh
[ "$1" = connect ] || exit 0
read -r req
method=$(printf '%s' "$req" | sed 's/.*"method":"\([^"]*\)".*/\1/')
name=$(printf '%s' "$req" | sed 's/.*"name":"\([^"]*\)".*/\1/')
ver() { cat "$STUB/docver-$name" 2>/dev/null || echo 0; }
val() { cat "$STUB/docval-$name" 2>/dev/null || echo null; }
case "$method" in
  doc.get) printf '{"jsonrpc":"2.0","id":1,"result":{"value":%s,"version":%s}}\n' "$(val)" "$(ver)" ;;
  doc.set)
    v=$(printf '%s' "$req" | sed 's/.*"version":\([0-9]*\)}}$/\1/')
    printf '%s' "$req" | sed 's/.*"value":\(.*\),"version":[0-9]*}}$/\1/' > "$STUB/docval-$name"
    echo $(( v + 1 )) > "$STUB/docver-$name"
    printf '{"jsonrpc":"2.0","id":1,"result":{"version":%s}}\n' "$(ver)" ;;
esac
exit 0
EOF
chmod +x "$stubdir/hc"
export STUB=$tmp/stub; mkdir -p "$STUB"
setdoc() { rm -f "$STUB"/docver-*; printf '%s\n' "$1" > "$STUB/docval-org-state"; }
doc() { cat "$STUB/docval-org-state"; }
esc() {
  env -u PADDOCK_ORG_ID -u PADDOCK_SECRETARY_NAME PADDOCK_HC_HOLD=0 PADDOCK_NOW=2026-11-12T01:02:03Z \
      PADDOCK_STATE_DIR="$tmp/state" PATH="$stubdir:$PATH" bash "$script" "$@" >/dev/null 2>&1
}
# field <name>: the entry's value for <name> as node reads it ("-" when absent).
field() { node -e 'const a=(JSON.parse(process.argv[1]).approvals||[])[0]||{}; const v=a[process.argv[2]]; console.log(v===undefined?"-":v)' "$(doc)" "$1"; }

command -v node >/dev/null 2>&1; check "node is available" $?


mkdir -p "$tmp/m/node_modules/gpui-kit" "$tmp/m/node_modules/gpui-base" "$tmp/m/node_modules/herdr"
cp "$here/mods/org-cockpit/main.js" "$tmp/m/main.mjs"
for p in gpui-kit gpui-base herdr; do
  printf '{"name":"%s","type":"module","main":"index.js"}\n' "$p" > "$tmp/m/node_modules/$p/package.json"
done
cat > "$tmp/m/node_modules/gpui-kit/index.js" <<'EOF'
// An element records its children, id, click handler and the name of every other call.
export class View {}
export function el(kind) {
  const e = { kind, kids: [], ops: [], _id: null, _click: null };
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
        else t.ops.push(k);
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
const H = globalThis.__h;
export async function exec(cmd, args = []) {
  if (args.join(" ").includes("hc connect"))
    return { code: 0, stdout: JSON.stringify({ jsonrpc: "2.0", id: 1, result: H.doc }) + "\n", stderr: "" };
  return { code: 0, stdout: "", stderr: "" };
}
export async function hc() { return { code: 0, stdout: "", stderr: "" }; }
export const run = () => {};
export const props = () => ({ role: "approval" });
export const settings = () => ({});
export const window = () => ({ platform: "linux" });
export const panes = () => [];
export const terminals = () => [
  { address: "t1", name: "w-task-a", state: "live", status: "blocked", labels: { task_id: "task-a" } },
  { address: "t9", name: "secretary", state: "live", status: "working", labels: {} },
];
export const theme = () => new Proxy({}, { get: () => "#aa5500" });
EOF

# drive <org-state value json>: render the approval card and print
#   text <all text>, yes <Yes control's text>, no <No control's text>,
#   cut <n>: how many given strings sit in a node (or under an ancestor) that truncates or caps
#            its height with no scrolling ancestor, i.e. would be cut with no way to read the rest.
cat > "$tmp/m/drive.mjs" <<'EOF'
const value = JSON.parse(process.argv[2]);
const longs = JSON.parse(process.argv[3] || "[]");
globalThis.__h = { doc: { version: 3, value } };
const { default: Cockpit } = await import("./main.mjs");
const pending = [];
const cx = { timer: { every() {} }, spawn(fn) { const p = Promise.resolve().then(() => fn(cx)); pending.push(p); return p; }, notify() {} };
const settle = async () => { for (let i = 0; i < 50; i++) { await Promise.allSettled(pending.splice(0)); await new Promise((r) => setTimeout(r, 20)); if (!pending.length) return; } };
const text = (n) => (n == null || n === false ? "" : typeof n === "string" || typeof n === "number" ? String(n) : (n.kids || []).map(text).join(" "));
const all = (n, out = []) => { if (n && typeof n === "object" && n.kids) { out.push(n); n.kids.forEach((k) => all(k, out)); } return out; };
const v = new Cockpit();
v.init({}, cx);
await settle();
const tree = v.render(cx);
const clicks = all(tree).filter((n) => n._click);
const yes = clicks.find((n) => /^\s*Yes\b/.test(text(n)));
const no = clicks.find((n) => /^\s*No\b/.test(text(n)));
console.log(`text ${text(tree).replace(/\s+/g, " ")}`);
console.log(`yes ${yes ? text(yes).replace(/\s+/g, " ") : "-"}`);
console.log(`no ${no ? text(no).replace(/\s+/g, " ") : "-"}`);
// Walk with the ancestor chain; a string under a cutting node with no scrolling node between is cut.
const CUT = new Set(["truncate", "max_h", "line_clamp", "text_ellipsis"]);
const SCROLL = new Set(["overflow_y_scrollbar", "overflow_scrollbar", "overflow_y_scroll", "overflow_scroll"]);
let cut = 0;
const walk = (n, chain) => {
  if (typeof n === "string") {
    if (!longs.some((l) => n.includes(l))) return;
    let scrolled = false, isCut = false;
    for (let i = chain.length - 1; i >= 0; i--) {
      const ops = chain[i].ops || [];
      if (ops.some((o) => SCROLL.has(o))) { scrolled = true; break; }
      if (ops.some((o) => CUT.has(o))) { isCut = true; break; }
    }
    if (isCut && !scrolled) { cut++; console.log(`cut-at ${n.slice(0, 40)}`); }
    return;
  }
  if (n && typeof n === "object" && n.kids) n.kids.forEach((k) => walk(k, [...chain, n]));
};
walk(tree, []);
console.log(`cut ${cut}`);
EOF
card() { (cd "$tmp/m" && node drive.mjs "$@" 2>&1); }
has() { printf '%s\n' "$1" | grep -q -- "$2"; }
line() { printf '%s\n' "$1" | sed -n "s/^$2 //p"; }

# ---- ask --lang ----------------------------------------------------------------

setdoc '{"approvals":[]}'
esc ask --task t1 --question "マージしてよいですか。" --lang ja; check "ask --lang ja succeeds" $?
[ "$(field lang)" = "ja" ]; check "ask keeps lang" $?
setdoc '{"approvals":[]}'
esc ask --task t2 --question "Merge?"; check "ask without --lang succeeds" $?
[ "$(field lang)" = "-" ]; check "and writes no lang field" $?
for bad in "" "japanese!" "$(printf 'x%.0s' $(seq 20))"; do
  setdoc '{"approvals":[]}'
  esc ask --task t3 --question "Merge?" --lang "$bad"; st=$?
  [ "$st" -eq 2 ] && [ "$(doc)" = '{"approvals":[]}' ]; check "ask rejects --lang '$bad' (exit 2, nothing written; got $st)" $?
done

# ---- the card's fixed words ----------------------------------------------------

entry() { # entry <lang or ""> <question>
  node -e '
const [lang, q] = process.argv.slice(1);
const a = { id: "task-a-20261112T010203Z", task_id: "task-a", question: q, asked_at: "2026-11-12T01:02:03Z",
  background: "CI is green.", if_yes: "Merge.", if_no: "Wait.", recommend: "yes", why: "Nothing blocks." };
if (lang) a.lang = lang;
console.log(JSON.stringify({ work: [{ task_id: "task-a", title: "T" }], approvals: [a] }));' "$1" "$2"
}
EN='ASKING YOU|Recommended|waiting|Not written|Open the secretary|Nothing waiting'
out=$(card "$(entry en "Merge?")"); t=$(line "$out" text)
has "$t" "THE SECRETARY IS ASKING YOU"; check "lang en: the English card is kept" $?
out=$(card "$(entry "" "Merge?")"); t=$(line "$out" text)
has "$t" "THE SECRETARY IS ASKING YOU"; check "no lang: the English card is kept" $?
out=$(card "$(entry xx "Merge?")"); t=$(line "$out" text)
has "$t" "THE SECRETARY IS ASKING YOU"; check "unknown lang: the English card is kept" $?
out=$(card "$(entry ja "マージしてよいですか。")"); t=$(line "$out" text)
printf '%s' "$t" | grep -Eq "$EN"; [ $? -ne 0 ]; check "lang ja: no English fixed word is left on the card" $?
has "$t" "マージしてよいですか。"; check "lang ja: the secretary's question is shown as written" $?
bare='{"work":[],"approvals":[{"id":"task-a-1","task_id":"task-a","lang":"ja","asked_at":"2026-11-12T01:02:03Z"}]}'
out=$(card "$bare"); t=$(line "$out" text)
printf '%s' "$t" | grep -Eq "$EN|No question was written|Approval "; [ $? -ne 0 ]; check "lang ja: the fallback texts of a bare entry are Japanese" $?
[ "$fail" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/     | /'

# ---- the secretary's rules -----------------------------------------------------

tpl=$here/templates/secretary.md
grep -q -- "--lang" "$tpl"; check "the secretary template names --lang" $?
grep -q -- "--lang" "$here/skills/org-escalation/SKILL.md"; check "the org-escalation skill names --lang" $?
grep -i "auto" "$tpl" | grep -q "locale the session runs in, or"; [ $? -ne 0 ]; check "auto no longer starts from the locale" $?
grep -iq "card" "$tpl" && grep -i "card" "$tpl" | grep -iq "conversation language"; check "the template puts the card text in the conversation language" $?

[ "$fail" -eq 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
