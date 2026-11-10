#!/usr/bin/env bash
# Acceptance test for Issue #127: an org-state.approvals entry says who answers it.
#   answer_in "worker":    a worker blocked on its own permission prompt or dialog. The card sends
#                          the person to that worker's terminal and offers no Yes / No.
#   answer_in "secretary": the secretary's own question. The card offers Yes / No, and never opens
#                          the worker's terminal; answering in words goes to the secretary's pane.
#   no answer_in:          read as "secretary".
#   no question:           the card still shows the approval id and the task.
# The mod runs under node with stub "gpui-kit", "gpui-base" and "herdr" modules (as in
# org-card-answer.test.sh); org-escalation's `ask` writes the field (hc is a documents-only stub).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <name> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

# ---- the card --------------------------------------------------------------

mkdir -p "$tmp/m/node_modules/gpui-kit" "$tmp/m/node_modules/gpui-base" "$tmp/m/node_modules/herdr"
cp "$here/mods/org-cockpit/main.js" "$tmp/m/main.mjs"
for p in gpui-kit gpui-base herdr; do
  printf '{"name":"%s","type":"module","main":"index.js"}\n' "$p" > "$tmp/m/node_modules/$p/package.json"
done
cat > "$tmp/m/node_modules/gpui-kit/index.js" <<'EOF'
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
const H = globalThis.__h;
export async function exec(cmd, args = []) {
  H.calls.push([cmd, ...args].join(" "));
  if (args.join(" ").includes("hc connect"))
    return { code: 0, stdout: JSON.stringify({ jsonrpc: "2.0", id: 1, result: H.doc }) + "\n", stderr: "" };
  return { code: 0, stdout: "", stderr: "" };
}
export async function hc() { return { code: 0, stdout: "", stderr: "" }; }
export const run = (...a) => { H.runs.push(a); };
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

# drive <entry json>: render the card for one approval, then click every control except Yes / No
# (those send through the mailbox, covered by org-card-answer.test.sh) and print what happened.
cat > "$tmp/m/drive.mjs" <<'EOF'
const entry = JSON.parse(process.argv[2]);
globalThis.__h = { calls: [], runs: [], doc: { version: 3, value: { work: [], approvals: [entry] } } };
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
const yesno = clicks.filter((n) => /^\s*(Yes|No)\b/.test(text(n)));
console.log(`yesno ${yesno.length}`);
for (const n of clicks) if (!yesno.includes(n)) n._click({}, {}, cx);
await settle();
for (const [action, arg] of globalThis.__h.runs) console.log(`run ${action} ${arg?.terminal ?? ""}`);
console.log(`text ${text(tree).replace(/\s+/g, " ")}`);
EOF

card() { (cd "$tmp/m" && node drive.mjs "$1" 2>&1); }
has() { printf '%s\n' "$1" | grep -q -- "$2"; }

command -v node >/dev/null 2>&1; check "node is available" $?

out=$(card '{"id":"task-a-1","task_id":"task-a","question":"Allow npm install?","asked_at":"2026-11-10T09:00:00Z","answer_in":"worker"}')
has "$out" '^yesno 0$'; check "worker: the card offers no Yes / No" $?
has "$out" '^run terminal.peek t1$'; check "worker: the card opens the worker's terminal" $?
has "$out" 'Allow npm install?'; check "worker: the card shows the question" $?
[ "$fail" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/     | /'

out=$(card '{"id":"task-a-2","task_id":"task-a","question":"Merge PR 12?","asked_at":"2026-11-10T09:00:00Z","answer_in":"secretary"}')
has "$out" '^yesno 2$'; check "secretary: the card offers Yes and No" $?
! has "$out" '^run terminal.peek t1$'; check "secretary: the card never opens the worker's terminal" $?
has "$out" '^run pane.focus t9$'; check "secretary: answering in words goes to the secretary's pane" $?
[ "$fail" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/     | /'

out=$(card '{"id":"task-a-3","task_id":"task-a","question":"Merge PR 13?","asked_at":"2026-11-10T09:00:00Z"}')
has "$out" '^yesno 2$'; check "no answer_in: read as secretary (Yes and No)" $?
! has "$out" '^run terminal.peek t1$'; check "no answer_in: the card never opens the worker's terminal" $?

out=$(card '{"id":"task-a-4","task_id":"task-a","title":"Wrong key","asked_at":"2026-11-10T09:00:00Z"}')
has "$out" 'task-a-4'; check "no question: the card shows the approval id" $?
has "$out" 'task-a'; check "no question: the card shows the task" $?
[ "$fail" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/     | /'

# ---- org-escalation ask writes the field -------------------------------------

script=$here/skills/org-escalation/scripts/org-escalation.sh
stubdir=$tmp/bin; mkdir -p "$stubdir"
cat > "$stubdir/hc" <<'EOF2'
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
EOF2
chmod +x "$stubdir/hc"
export STUB=$tmp/stub; mkdir -p "$STUB"
setdoc() { rm -f "$STUB"/docver-*; printf '%s\n' "$1" > "$STUB/docval-org-state"; }
doc() { cat "$STUB/docval-org-state"; }
esc() {
  env -u PADDOCK_ORG_ID -u PADDOCK_SECRETARY_NAME PADDOCK_HC_HOLD=0 PADDOCK_NOW=2026-11-10T01:02:03Z \
      PADDOCK_STATE_DIR="$tmp/state" PATH="$stubdir:$PATH" bash "$script" "$@" >/dev/null 2>&1
}

setdoc '{"approvals":[]}'
esc ask --task t1 --question "Allow the prompt?" --answer-in worker; check "ask --answer-in worker succeeds" $?
case $(doc) in *'"task_id":"t1"'*'"answer_in":"worker"'*) r=0 ;; *) r=1 ;; esac; check "ask writes answer_in worker" $r
setdoc '{"approvals":[]}'
esc ask --task t2 --question "Merge?" --answer-in secretary; check "ask --answer-in secretary succeeds" $?
case $(doc) in *'"answer_in":"secretary"'*) r=0 ;; *) r=1 ;; esac; check "ask writes answer_in secretary" $r
setdoc '{"approvals":[]}'
esc ask --task t3 --question "Merge?"
case $(doc) in *'"answer_in":"secretary"'*) r=0 ;; *) r=1 ;; esac; check "ask without --answer-in writes secretary" $r
setdoc '{"approvals":[]}'
esc ask --task t4 --question "Merge?" --answer-in person; [ $? -eq 2 ]; check "ask rejects another answer_in (exit 2)" $?
[ "$(doc)" = '{"approvals":[]}' ]; check "and writes nothing" $?

# ---- the two kinds are named where the schema and the flow live ---------------

for f in docs/decisions/0004-records-documents-and-jsonl.md docs/design/prototype-1.md docs/design/architecture.md templates/secretary.md skills/org-escalation/SKILL.md; do
  grep -q 'answer_in' "$here/$f"; check "$f names answer_in" $?
done

[ "$fail" -eq 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
