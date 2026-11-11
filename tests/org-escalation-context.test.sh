#!/usr/bin/env bash
# Acceptance test for Issue #258: the approval card says what is being decided.
#   org-escalation ask takes the context the person needs, written by the secretary:
#     --background, --if-yes, --if-no, --recommend yes|no with --why. Each is optional, checked
#     and kept in the approval entry in org-state.
#   The card shows the task's title (from the work entry), the question and that context, never
#     cut without a way to read the rest; an entry without the context says what was not written.
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

setdoc '{"approvals":[]}'
esc ask --task t1 --question "Merge PR 12 now?" \
  --background "PR 12 adds the \"context\" fields; CI is green." \
  --if-yes "The secretary merges PR 12 and closes the task." \
  --if-no "The PR stays open and the worker waits." \
  --recommend yes --why "Review found nothing blocking."
check "ask with every context field succeeds" $?
[ "$(field background)" = 'PR 12 adds the "context" fields; CI is green.' ]; check "ask keeps background (quotes escaped as JSON)" $?
[ "$(field if_yes)" = "The secretary merges PR 12 and closes the task." ]; check "ask keeps if_yes" $?
[ "$(field if_no)" = "The PR stays open and the worker waits." ]; check "ask keeps if_no" $?
[ "$(field recommend)" = "yes" ]; check "ask keeps recommend" $?
[ "$(field why)" = "Review found nothing blocking." ]; check "ask keeps why" $?
[ "$(field question)" = "Merge PR 12 now?" ]; check "ask still keeps the question" $?

setdoc '{"approvals":[]}'
esc ask --task t2 --question "Merge?"; check "ask without context still succeeds" $?
[ "$(field background)$(field if_yes)$(field if_no)$(field recommend)$(field why)" = "-----" ]
check "and writes no empty context fields" $?

setdoc '{"approvals":[]}'
esc ask --task t3 --question "Merge?" --background "$(printf 'line one\nline two')"
[ "$(field background)" = "line one line two" ]; check "control characters in background become spaces" $?

rejects() { # rejects <name> <args...>: exit 2 and nothing written
  setdoc '{"approvals":[]}'
  esc ask --task t4 --question "Merge?" "${@:2}"; local st=$?
  [ "$st" -eq 2 ] && [ "$(doc)" = '{"approvals":[]}' ]; check "ask rejects $1 (exit 2, nothing written; got $st)" $?
}
rejects "--recommend maybe" --recommend maybe --why "because"
rejects "--recommend without --why" --recommend no
rejects "--why without --recommend" --why "because"
rejects "an empty --if-yes" --if-yes "   "
rejects "a --background over 600 bytes" --background "$(printf 'b%.0s' $(seq 601))"
rejects "an --if-no over 300 bytes" --if-no "$(printf 'n%.0s' $(seq 301))"
rejects "a --why over 400 bytes" --recommend yes --why "$(printf 'w%.0s' $(seq 401))"

# ---- the card ----------------------------------------------------------------

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

LONGQ="May I add paddock-proto3.txt at the repository root, next to README.md, so that the Prototype 3 runbook has a file whose change it can follow from the worker to the pull request and back?"
LONGB=$(printf 'Background sentence that keeps going. %.0s' $(seq 14))
full=$(node -e '
const [q, b] = process.argv.slice(1);
console.log(JSON.stringify({
  work: [{ task_id: "task-a", title: "Prototype 3 marker file", since: "2026-11-12T00:00:00Z" }],
  approvals: [{ id: "task-a-20261112T010203Z", task_id: "task-a", question: q, asked_at: "2026-11-12T01:02:03Z",
    answer_in: "secretary", background: b, if_yes: "The worker adds the file and opens the PR.",
    if_no: "The worker drops the file and reports done.", recommend: "no", why: "The runbook can use docs/ instead." }],
}));' "$LONGQ" "$LONGB")
out=$(card "$full" "$(node -e 'console.log(JSON.stringify(process.argv.slice(1)))' "$LONGQ" "$LONGB")")
t=$(line "$out" text)
has "$t" "Prototype 3 marker file"; check "full: the card shows the task's title from the work entry" $?
has "$t" "May I add paddock-proto3.txt"; check "full: the card shows the question" $?
has "$t" "Background sentence that keeps going"; check "full: the card shows the background" $?
has "$t" "The worker adds the file and opens the PR."; check "full: the card shows what Yes does" $?
has "$t" "The worker drops the file and reports done."; check "full: the card shows what No does" $?
has "$t" "The runbook can use docs/ instead."; check "full: the card shows why the secretary recommends it" $?
has "$(line "$out" no)" "Recommended"; check "full: the recommended answer (No) is marked on its button" $?
! has "$(line "$out" yes)" "Recommended"; check "full: the other answer (Yes) is not marked" $?
! has "$t" "Not written"; check "full: nothing is reported missing" $?
[ "$(line "$out" cut)" = 0 ]; check "full: the long question and background are never cut without a scroll" $?
[ "$fail" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/     | /'

minimal='{"work":[],"approvals":[{"id":"task-a-20261112T010203Z","task_id":"task-a","question":"Merge PR 12?","asked_at":"2026-11-12T01:02:03Z"}]}'
out=$(card "$minimal")
t=$(line "$out" text)
has "$t" "Merge PR 12?"; check "minimal: the card shows the question" $?
has "$t" "task-a"; check "minimal: with no work entry the card names the task by its id" $?
has "$t" "Not written"; check "minimal: the card says the context was not written" $?
for w in background "what Yes does" "what No does" recommendation; do
  has "$t" "$w"; check "minimal: it names the missing $w" $?
done
! has "$(line "$out" yes)$(line "$out" no)" "Recommended"; check "minimal: no answer is marked recommended" $?
[ "$fail" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/     | /'

partial='{"work":[{"task_id":"task-a","title":"Merge the docs fix"}],"approvals":[{"id":"task-a-1","task_id":"task-a","question":"Merge PR 12?","asked_at":"2026-11-12T01:02:03Z","background":"CI is green.","recommend":"yes","why":"Nothing blocks it."}]}'
out=$(card "$partial")
t=$(line "$out" text)
has "$t" "Not written"; check "partial: the card says some context was not written" $?
has "$t" "what Yes does" && has "$t" "what No does"; check "partial: it names the missing outcomes" $?
has "$(line "$out" yes)" "Recommended"; check "partial: the recommended answer (Yes) is marked" $?
[ "$fail" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/     | /'

# ---- the secretary is told to fill them ---------------------------------------

for f in templates/secretary.md skills/org-escalation/SKILL.md; do
  for o in --background --if-yes --if-no --recommend --why; do
    grep -q -- "$o" "$here/$f"; check "$f names $o" $?
  done
done

[ "$fail" -eq 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
