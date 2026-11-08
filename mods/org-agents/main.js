// paddock prototype 1: what the secretary is waiting on you for, and the work in progress,
// read from the core document `org-state` (shape: docs/design/prototype-1.md).
// Started as `mod.clone` of the shipped `agents` mod; the status glyphs are its.

import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { exec, terminals, theme, window } from "herdr";

const DOC = "org-state";
const REQ = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "doc.get", params: { name: DOC } });

// hc's CLI has no doc verb, and exec has no stdin, so a shell pipes one JSON-RPC line into `hc connect`.
// `hc connect` (0.1.18) ends at end of input without waiting for its answer, so stdin is held open 1 s.
// Windows has no sh, and hc is often not on PATH there: pwsh, with hc's default install folder.
// ponytail: one process and 1 s per read; subscribe to doc events once a long-lived reader exists.
function rpcCommand() {
  if (window()?.platform === "windows") {
    const hc = '$hc = (Get-Command hc -ErrorAction SilentlyContinue).Source; if (-not $hc) { $hc = "$env:LOCALAPPDATA\\Programs\\herdr-core\\hc.exe" }';
    return ["pwsh", ["-NoProfile", "-NonInteractive", "-Command", `${hc}; & { '${REQ.replace(/'/g, "''")}'; Start-Sleep -Seconds 1 } | & $hc connect`]];
  }
  return ["sh", ["-c", '{ printf "%s\\n" "$1"; sleep 1; } | hc connect', "sh", REQ]];
}

async function readDoc() {
  const [cmd, args] = rpcCommand();
  const r = await exec(cmd, args);
  const line = r.stdout.split("\n").find((l) => l.trim().startsWith("{"));
  if (!line) throw new Error(r.stderr.trim() || `hc connect exited with ${r.code} and no answer`);
  const msg = JSON.parse(line);
  if (msg.error) throw new Error(msg.error.message);
  return msg.result; // { value, version }; version 0: never written
}

function duration(ms) {
  const m = Math.floor(ms / 60000);
  if (!(m >= 1)) return "<1m";
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  return h < 48 ? `${h}h` : `${Math.floor(h / 24)}d`;
}
const since = (iso, now) => duration(now - Date.parse(iso));

const ORDER = { blocked: 0, working: 1 };
const MAX_CARDS = 3;

export default class OrgState extends View {
  init(_props, cx) {
    this.doc = null; // { value, version } once read
    this.error = null;
    this.refresh(cx);
    cx.timer.every(5000, (cx) => this.refresh(cx));
  }

  refresh(cx) {
    cx.spawn(async (cx) => {
      try {
        this.doc = await readDoc();
        this.error = null;
      } catch (e) {
        this.error = String(e?.message ?? e);
      }
      cx.notify();
    });
  }

  // The shipped agents mod's glyphs; "none" (no live terminal for the task) is a ring in `unknown`.
  status(t, s) {
    if (s === "working") return svg("mods/workspace-chrome/spinner.svg").size(12).mx(1).flex_none().text_color(t.working).spin(900);
    if (s === "blocked") return div().flex_none().px(6).h(18).rounded(5).bg(t.blocked + "26").text_size(10.5).font_semibold().text_color(t.blocked).flex().items_center().child("Needs you");
    if (s === "done") return div().size(7).mx(3).flex_none().rounded(4).bg(t.done);
    return div().size(7).mx(3).flex_none().rounded(4).border(1.5).border_color(s === "idle" ? t.idle ?? t.dim : t.unknown ?? t.dim);
  }

  header(t, text, color) {
    return div().px(4).text_size(11).font_medium().text_color(color).child(text);
  }

  more(t, n) {
    return div().px(12).text_size(11).text_color(t.dim).child(`and ${n} more`);
  }

  card(t, a, now) {
    return h_flex().id(`ap-${a.id}`).items_stretch().gap(10).rounded(10).bg(t.raised).px(12).py(10)
      .child(div().w(3).flex_none().rounded(2).bg(t.blocked))
      .child(v_flex().flex_1().min_w(0).gap(4)
        .child(div().text_size(13).font_medium().text_color(t.foreground).whitespace_normal().max_h(40).overflow_hidden().child(a.question ?? ""))
        .child(h_flex().gap(8).text_size(11).text_color(t.dim)
          .child(div().flex_1().min_w(0).truncate().child(a.task_id ?? ""))
          .child(div().flex_none().child(since(a.asked_at, now)))));
  }

  row(t, w, now) {
    return h_flex().id(`w-${w.task_id}`).h(30).flex_none().px(8).gap(8).rounded(8).items_center().hover((s) => s.bg(t.hover))
      .child(h_flex().min_w(16).flex_none().justify_center().child(this.status(t, w.status)))
      .child(div().flex_1().min_w(0).truncate().text_size(13).text_color(t.foreground).child(w.title || w.task_id))
      .child(div().flex_none().text_size(11).text_color(t.dim).child(since(w.since, now)));
  }

  body(t) {
    if (this.error) {
      return v_flex().gap(4)
        .child(div().text_size(13).text_color(t.foreground).child("Can't reach hc."))
        .child(div().text_size(11).text_color(t.dim).truncate().child(this.error.split("\n")[0]));
    }
    if (!this.doc) return div();
    const v = this.doc.value;
    if (this.doc.version === 0 || v == null) return div().text_size(13).text_color(t.muted).child("The secretary has not written anything yet.");

    const now = Date.now();
    // Oldest first: the one that has waited longest is answered first.
    const approvals = [...(v.approvals ?? [])].sort((x, y) => Date.parse(x.asked_at) - Date.parse(y.asked_at));
    const cards = approvals.slice(0, MAX_CARDS);

    // A task's live status comes from the terminal labelled with its task_id, as core reports it.
    const live = new Map(terminals().filter((x) => x.state === "live" && x.labels?.task_id).map((x) => [x.labels.task_id, x.status]));
    const work = (v.work ?? []).map((w) => {
      const s = live.get(w.task_id);
      return { ...w, status: s === "error" ? "blocked" : s ?? "none" };
    }).sort((x, y) => (ORDER[x.status] ?? 2) - (ORDER[y.status] ?? 2) || Date.parse(x.since) - Date.parse(y.since));
    // ponytail: fixed row budget for the 420 px dialog instead of scrolling: a card (question clamped
    // to two lines) costs three rows. Measure once it docks.
    const maxRows = 10 - 3 * Math.max(cards.length, 1);
    const rows = work.slice(0, maxRows);

    return v_flex().gap(20)
      .child(v_flex().gap(8).when(cards.length > 0, (el) => el.pb(3))
        .child(this.header(t, "Waiting for you", cards.length ? t.blocked : t.dim))
        .when(cards.length === 0, (el) => el.child(div().px(12).text_size(12).text_color(t.dim).child("Nothing waiting for you.")))
        .children(cards.map((a) => this.card(t, a, now)))
        .when(approvals.length > cards.length, (el) => el.child(this.more(t, approvals.length - cards.length))))
      .child(v_flex().gap(2)
        .child(div().pb(6).child(this.header(t, "In progress", t.dim)))
        .when(rows.length === 0, (el) => el.child(div().px(12).text_size(12).text_color(t.dim).child("Nothing in progress.")))
        .children(rows.map((w) => this.row(t, w, now)))
        .when(work.length > rows.length, (el) => el.child(this.more(t, work.length - rows.length))));
  }

  render(_cx) {
    const t = theme();
    return v_flex().size_full().min_h(0).bg(t.canvas).px(16).py(14).child(this.body(t));
  }
}
