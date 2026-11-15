#!/usr/bin/env bash
# Issue #411: the workers rail always shows the watcher strip, read only from the watcher's own
# files: alive (last pass) or a warning (no pass for long, or no watcher terminal at all), each
# open CI watch, and the last wakes and mailbox lines, in the cockpit's language. gpui-kit and
# herdr are stubs; the strip's shell read runs for real against a made-up state folder.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
cipid=
trap '[ -z "$cipid" ] || kill "$cipid" 2>/dev/null; rm -rf "$tmp"' EXIT
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
  const e = { kind, kids: [], _id: null };
  const p = new Proxy(e, {
    get(t, k) {
      if (k in t) return t[k];
      if (k === "then" || typeof k === "symbol") return undefined;
      return (...a) => {
        if (k === "child") t.kids.push(a[0]);
        else if (k === "children") t.kids.push(...a[0]);
        else if (k === "when") { if (a[0]) a[1](p); }
        else if (k === "id") t._id = a[0];
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
export const InputState = { new: () => ({ value: () => "", set_value() {}, on: () => true }) };
export const Input = { new: () => el("input") };
EOF
# exec: the org-state read answers the test's value; any other command runs for real.
cat > "$m/node_modules/herdr/index.js" <<'EOF'
import { spawnSync } from "node:child_process";
const H = globalThis.__h;
export async function exec(cmd, args) {
  if (args.join(" ").includes("hc connect")) return { code: 0, stdout: JSON.stringify({ jsonrpc: "2.0", id: 1, result: { version: 1, value: H.value } }) + "\n", stderr: "" };
  const r = spawnSync(cmd, args, { encoding: "utf8" });
  return { code: r.status, stdout: r.stdout, stderr: r.stderr };
}
export async function hc(a) { return a[0] === "read" && a[1] === "t7" ? { code: 0, stdout: "org-watch: cannot reach the core (hc ls failed)\n", stderr: "" } : { code: 1, stdout: "", stderr: "" }; }
export const run = () => {};
export const props = () => ({ role: "workers" });
export const settings = () => ({});
export const window = () => ({ platform: "linux" });
export const panes = () => [];
export const terminals = () => H.terms;
export const theme = () => new Proxy({}, { get: () => "#aa5500" });
EOF
# drive <watcher live: 1|0> <org-state value>: prints the strip's text.
cat > "$m/drive.mjs" <<'EOF'
const [live, value] = [process.argv[2] === "1", JSON.parse(process.argv[3])];
const terms = [{ address: "t9", name: "secretary", state: "live", status: "idle", labels: {} }];
if (live) terms.push({ address: "t7", name: "watcher", state: "live", labels: { paddock_role: "watcher" } });
globalThis.__h = { terms, value };
const { default: Cockpit } = await import("./main.mjs");
const pending = [];
const cx = { timer: { every() {} }, spawn(fn) { const p = Promise.resolve().then(() => fn(cx)); pending.push(p); return p; }, notify() {} };
const v = new Cockpit();
v.init({}, cx);
for (let i = 0; i < 20 && pending.length; i++) await Promise.allSettled(pending.splice(0));
const text = (n) => (n == null || n === false ? "" : typeof n === "string" ? n : (n.kids || []).map(text).join("\n"));
const find = (n) => (n && n.kids ? (n._id === "watcher" ? n : n.kids.map(find).find(Boolean)) : null);
console.log(text(find(v.render(cx))));
EOF
export PADDOCK_STATE_DIR=$tmp/state
w=$PADDOCK_STATE_DIR/watcher
mkdir -p "$w/ci" "$PADDOCK_STATE_DIR/events/2026-11"
drive() { (cd "$m" && node drive.mjs "$@" 2>&1); }
has() { printf '%s\n' "$1" | grep -qF -- "$2"; }

now=$(date +%s)
: > "$w/told"
printf '%s\twake\tsecretary\tperson#79\tdone\tno\t0\n%s\tskip\tsecretary\tperson#80\tworking\t-\t-\n%s\twake\tw-b\tsecretary#2,person#81\tdone\tno\t0\n%s\twake\tw-a\tsecretary#3\tidle\tno\t1\n' \
  $((now - 300)) $((now - 200)) $((now - 150)) $((now - 100)) > "$w/woke"
ci_line='CI success on PR 423, head 1e49346, run 43726165515. Runs read: 43726165515 pull_request success, 43726159144 push success.'
{
  printf '{"seq":1,"ts":"%s","from":"watcher","kind":"message","to":"secretary","task_id":"","text":"w-a is blocked"}\n' "$(date -u -d "@$((now - 400))" +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"seq":2,"ts":"%s","kind":"ci_completed","from":"watcher","pr":423}\n' "$(date -u -d "@$((now - 60))" +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"seq":3,"ts":"%s","from":"watcher","kind":"message","to":"secretary","task_id":"","text":"%s"}\n' "$(date -u -d "@$((now - 50))" +%Y-%m-%dT%H:%M:%SZ)" "$ci_line"
} > "$PADDOCK_STATE_DIR/events/2026-11/watcher.jsonl"
# a live CI watch (its cmdline names ci-watch.sh) and a dead one
printf 'sleep 60\n' > "$tmp/ci-watch.sh"
bash "$tmp/ci-watch.sh" & cipid=$!
printf '%s 1e4934618ee2f80eeb65706d9a42526325341653 suisya-systems/paddock 423\n' "$cipid" > "$w/ci/suisya-systems_paddock-423.pid"
printf '999999 abcdef0123 suisya-systems/paddock 400\n' > "$w/ci/suisya-systems_paddock-400.pid"

out=$(drive 1 '{}')
has "$out" "alive · last pass"; check "a fresh pass reads alive ($out)" $?
has "$out" "PR 423 (paddock) · head 1e49346"; check "the live CI watch is shown with its PR and head" $?
! has "$out" "PR 400"; check "a pid file whose pid does not run ci-watch.sh is not shown" $?
has "$out" "→ secretary: $ci_line"; check "the CI line is shown whole, as the watcher wrote it" $?
has "$out" "woke w-b (mail from secretary, person)"; check "a wake shows its target and whose mail" $?
has "$out" "wake of w-a failed (exit 1)"; check "a failed wake says so" $?
! has "$out" "person#80" && ! has "$out" "w-a is blocked" && ! has "$out" "woke secretary"; check "skips are not actions; only the last 3 actions are shown" $?
[ "$(printf '%s\n' "$out" | grep -n 'CI success' | cut -d: -f1)" -lt "$(printf '%s\n' "$out" | grep -n 'woke w-b' | cut -d: -f1)" ]
check "newest action first" $?

out=$(drive 1 '{"conversation_lang":"ja"}')
has "$out" "稼働中 · 最終巡回" && has "$out" "最近の動き" && has "$out" "w-b を起こしました（secretary, person からのメール）"
check "lang ja: the strip speaks Japanese ($out)" $?

touch -d "@$((now - 300))" "$w/told"
out=$(drive 1 '{}')
has "$out" "no pass for 5m" && has "$out" "org-watch: cannot reach the core (hc ls failed)"
check "no pass for over 90 s: stale, with the watcher's last screen line as the why ($out)" $?

kill "$cipid" 2>/dev/null; wait "$cipid" 2>/dev/null; cipid=
out=$(drive 1 '{}')
has "$out" "No CI watch open."; check "no live watch: says none is open" $?

out=$(drive 0 '{}')
has "$out" "The watcher is not running. Nothing wakes the secretary or the workers"; check "no watcher terminal: a plain warning ($out)" $?
out=$(drive 0 '{"conversation_lang":"ja"}')
has "$out" "ウォッチャーが止まっています"; check "no watcher terminal, ja" $?

if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$w/woke"
  out=$(drive 1 '{}')
  has "$out" "Can't read the watcher's files." && has "$out" "cannot read $w/woke"; check "an unreadable watcher file: says it cannot read, not an empty state ($out)" $?
  chmod 644 "$w/woke"
fi

rm -rf "$w"
out=$(drive 1 '{}')
has "$out" "Can't read the watcher's files." && has "$out" "no folder $w"; check "no watcher folder: says it cannot read, and where it looked" $?

rm -rf "$PADDOCK_STATE_DIR/events"; mkdir -p "$w"
out=$(drive 1 '{}')
has "$out" "running · no pass time recorded yet" && has "$out" "Nothing yet." && ! has "$out" "cannot reach the core"
check "no told yet (a quiet watcher): says no pass time yet, not stale ($out)" $?

[ "$fail" -eq 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
