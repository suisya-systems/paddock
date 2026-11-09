// paddock's organization screen (docs/design/architecture.md section 7), one mod in three
// roles placed by layouts/paddock.json through props.role:
//   "workers"  left: one tile per worker terminal (labelled task_id): status colour, its last
//              lines, "Needs you" when blocked. Click opens the terminal to answer there.
//   "approval" bottom right: the oldest org-state approval as one card.
//   "consult"  floating: what the secretary asks the person, while its terminal is blocked.
// The secretary itself is a terminal block in the layout, not drawn here.
// org-state reading is prototype 1's (mods/org-agents/main.js); mods cannot import across folders.

import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { exec, hc, panes, props, run, settings, terminals, theme, window } from "herdr";

const DOC = "org-state";
const REQ = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "doc.get", params: { name: DOC } });
const SECRETARY = "secretary"; // org-start's default name; props.secretary overrides it
// The space and tab the secretary's pane is adopted into (ids local to its machine).
const SPACE = "paddock";
const TAB = "secretary";

// Is terminal x the one named `want`? `want` is a name, or `<machine>/<name>` for a terminal on
// another machine (its address is then `<machine>/tN`), as the layout's terminal block takes it.
function named(x, want) {
  const slash = x.address?.indexOf("/") ?? -1;
  return x.name === want || x.address === want || (slash > 0 && `${x.address.slice(0, slash)}/${x.name}` === want);
}

// hc's CLI has no doc verb, and exec has no stdin, so a shell pipes one JSON-RPC line into `hc connect`.
// `hc connect` (0.1.18) ends at end of input without waiting for its answer, so stdin is held open 1 s.
// Windows has no sh, and hc is often not on PATH there: pwsh, with hc's default install folder.
// ponytail: one process and 1 s per read; subscribe to doc events once a long-lived reader exists.
function rpcCommand() {
  if (window()?.platform === "windows") {
    const hcExe = '$hc = (Get-Command hc -ErrorAction SilentlyContinue).Source; if (-not $hc) { $hc = "$env:LOCALAPPDATA\\Programs\\herdr-core\\hc.exe" }';
    return ["pwsh", ["-NoProfile", "-NonInteractive", "-Command", `${hcExe}; & { '${REQ.replace(/'/g, "''")}'; Start-Sleep -Seconds 1 } | & $hc connect`]];
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
const since = (iso, now) => (iso ? duration(now - Date.parse(iso)) : "");

// The last meaningful lines of a screen. Claude Code draws an input box and footer hints at the
// bottom; they say nothing about the work, so lines of box drawing, the `>` prompt row and the
// hints are dropped.
// ponytail: a text heuristic for Claude Code's screen; other agents' chrome may slip through.
const CHROME = /^[\s─━│┃╭╮╰╯┌┐└┘├┤┬┴┼═║╔╗╚╝▔▁]*$/;
function lastLines(text, n = 2) {
  return (text ?? "").split("\n")
    .map((l) => l.replace(/\s+$/, ""))
    .filter((l) => l.trim() && !CHROME.test(l) && !/^\s*[│┃]?\s*>\s?/.test(l) && !/\? for shortcuts|esc to interrupt|shift\+tab to cycle/i.test(l))
    .map((l) => l.replace(/^[│┃]\s?|\s?[│┃]$/g, "").trim())
    .filter(Boolean)
    .slice(-n);
}

// Most urgent first: what needs the person, then what broke, then what moves.
const RANK = { blocked: 0, error: 1, working: 2, done: 3, idle: 4 };
const WORD = { blocked: "Needs you", error: "Error", working: "Working", done: "Done", idle: "Idle" };

export default class Cockpit extends View {
  init(_props, cx) {
    this.role = props()?.role;
    this.doc = null; // { value, version } once read
    this.error = null;
    this.lines = new Map(); // address -> last lines
    if (this.role === "consult") {
      // The centre is the layout's active-tab block. The secretary joins it as a pane: herdr-app
      // adopts any terminal labelled herdr.space / herdr.tab, so a renewed secretary is adopted
      // again. (A layout terminal block is not used: in herdr-app 0.1.13, when its terminal ends
      // the block is removed and the next save rewrites the person's layout file without it.)
      // The consult copy, in the layout once, labels the secretary when it lacks the labels and
      // shows its pane once per new address.
      cx.timer.every(2000, (cx) => this.adoptSecretary(cx));
      return; // otherwise live data only: terminals() redraws it
    }
    this.refresh(cx);
    cx.timer.every(5000, (cx) => this.refresh(cx));
    if (this.role === "workers") {
      this.readLines(cx);
      cx.timer.every(3000, (cx) => this.readLines(cx));
    }
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

  // ponytail: one `hc read` per worker every 3 s; fine for a handful, batch them if there are many.
  // A tick is skipped while the last one runs (exec may take up to 30 s when hc stalls), and the
  // window redraws only when a line changed: every notify redraws the whole window.
  readLines(cx) {
    if (this.reading) return;
    this.reading = true;
    cx.spawn(async (cx) => {
      try {
        const ws = this.workers();
        const read = await Promise.all(ws.map((w) => hc(["read", w.address]).then((r) => (r.code === 0 ? lastLines(r.stdout) : null), () => null)));
        const lines = new Map(ws.map((w, i) => [w.address, read[i]]));
        if (JSON.stringify([...lines]) !== JSON.stringify([...this.lines])) {
          this.lines = lines;
          cx.notify();
        }
      } finally {
        this.reading = false;
      }
    });
  }

  secretaryName() {
    return props()?.secretary ?? SECRETARY;
  }

  adoptSecretary(cx) {
    const sec = this.secretary();
    if (!sec) return;
    if (!sec.labels?.["herdr.space"] && !this.labelling) {
      this.labelling = true;
      cx.spawn(async () => {
        try {
          await hc(["label", sec.address, `herdr.space=${SPACE}`, `herdr.tab=${TAB}`]);
        } finally {
          this.labelling = false;
        }
      });
    }
    if (this.shownFor !== sec.address && panes().some((p) => p.terminal === sec.address)) {
      this.shownFor = sec.address;
      run("pane.focus", { terminal: sec.address });
    }
  }

  secretary() {
    return terminals().find((x) => x.state === "live" && named(x, this.secretaryName()));
  }

  workers() {
    const sec = this.secretaryName();
    return terminals().filter((x) => x.state === "live" && x.labels?.task_id && !named(x, sec));
  }

  value() {
    const v = this.doc?.value;
    return this.doc && this.doc.version !== 0 && v != null ? v : null;
  }

  // ---- shared pieces --------------------------------------------------------

  color(t, s) {
    if (s === "error") return t.ansi9 ?? t.blocked;
    return t[s] ?? t.unknown ?? t.dim;
  }

  glyph(t, s) {
    if (s === "working") return svg("mods/workspace-chrome/spinner.svg").size(12).flex_none().text_color(t.working).spin(900);
    if (s === "blocked" || s === "error") {
      const c = this.color(t, s);
      return div().flex_none().px(7).h(20).rounded(6).bg(c + "2e").text_size(11).font_semibold().text_color(c).flex().items_center().child(WORD[s]);
    }
    if (s === "done") return div().size(8).mx(2).flex_none().rounded(4).bg(t.done);
    return div().size(8).mx(2).flex_none().rounded(4).border(1.5).border_color(s === "idle" ? t.idle ?? t.dim : t.unknown ?? t.dim);
  }

  label(t, text, color) {
    return div().text_size(11).font_semibold().text_color(color ?? t.dim).child(text);
  }

  quiet(t, text) {
    return div().text_size(13).text_color(t.dim).child(text);
  }

  problem(t) {
    return v_flex().gap(4)
      .child(div().text_size(13).text_color(t.foreground).child("Can't reach hc."))
      .child(div().text_size(11).text_color(t.dim).truncate().child(this.error.split("\n")[0]));
  }

  // ---- workers --------------------------------------------------------------

  tile(t, w, work, now) {
    const s = w.status ?? "none";
    const c = this.color(t, s);
    const loud = s === "blocked" || s === "error";
    const msg = loud ? w.report?.msg : null;
    const lines = msg ? [msg] : this.lines.get(w.address) ?? [];
    const mono = settings()?.font_family ?? "JetBrains Mono";
    const id = w.labels.task_id;
    return h_flex().id(`w-${w.address}`).flex_none().items_stretch().rounded(8).overflow_hidden()
      .bg(loud ? c + "1f" : t.raised).cursor_pointer().hover((st) => st.bg(loud ? c + "2e" : t.hover))
      .on_click(() => run("terminal.peek", { terminal: w.address }))
      .child(div().w(3).flex_none().bg(c))
      .child(v_flex().flex_1().min_w(0).px(12).py(10).gap(6)
        .child(h_flex().gap(8).items_center()
          .child(div().flex_1().min_w(0).truncate().text_size(13).font_semibold().text_color(t.foreground).child(work?.title || id))
          .child(this.glyph(t, s)))
        .child(div().truncate().text_size(11).text_color(t.dim).child([id, since(work?.since, now)].filter(Boolean).join(" · ")))
        .child(v_flex().rounded(8).bg(t.background).px(10).py(8).gap(2).font_family(mono).text_size(12).line_height(1.35)
          .when(lines.length === 0, (el) => el.child(div().text_color(t.dim).child(s === "none" ? "No status reported" : "…")))
          .when(Boolean(msg), (el) => el.child(div().text_color(t.foreground).whitespace_normal().max_h(33).overflow_hidden().child(msg)))
          .when(!msg, (el) => el.children(lines.map((l, i) => div().truncate().text_color(i === lines.length - 1 ? t.foreground : t.muted).child(l))))));
  }

  renderWorkers(t) {
    const now = Date.now();
    const titles = new Map((this.value()?.work ?? []).map((w) => [w.task_id, w]));
    const ws = this.workers().sort((a, b) =>
      (RANK[a.status] ?? 5) - (RANK[b.status] ?? 5) || String(a.labels.task_id).localeCompare(String(b.labels.task_id)));
    return v_flex().size_full().min_h(0).gap(12)
      .child(h_flex().px(2).pt(4).items_center().justify_between()
        .child(this.label(t, "WORKERS"))
        .when(Boolean(this.error), (el) => el.child(div().text_size(11).text_color(t.blocked).child("hc unreachable"))))
      .child(v_flex().id("tiles").flex_1().min_h(0).gap(8).overflow_y_scrollbar()
        .when(ws.length === 0, (el) => el.child(div().px(2).child(this.quiet(t, "No workers running."))))
        .children(ws.map((w) => this.tile(t, w, titles.get(w.labels.task_id), now))));
  }

  // ---- approval -------------------------------------------------------------

  card(t, a, more, now) {
    const term = terminals().find((x) => x.state === "live" && x.labels?.task_id === a.task_id);
    const c = t.blocked;
    const button = div().id("open").h(36).px(14).rounded(8).flex().items_center().justify_center()
      .text_size(13).font_semibold()
      .when(Boolean(term), (el) => el.bg(c).text_color(t.background).cursor_pointer().hover((s) => s.bg(c + "d9"))
        .on_click(() => run("terminal.peek", { terminal: term.address })))
      .when(!term, (el) => el.bg(t.raised).text_color(t.dim).truncate())
      .child(term ? `Open ${a.task_id}` : `No terminal for ${a.task_id}`);
    // The secretary removes an answered approval; until it does, the card says it may be answered.
    const meta = `waiting ${since(a.asked_at, now)}` + (term && term.status !== "blocked" ? " · answered?" : "");
    return v_flex().gap(8)
      .child(h_flex().id(`ap-${a.id}`).items_stretch().rounded(12).overflow_hidden().bg(c + "26")
        .child(div().w(4).flex_none().bg(c))
        .child(v_flex().flex_1().min_w(0).px(16).py(16).gap(12)
          .child(h_flex().gap(8).items_center()
            .child(div().size(8).flex_none().rounded(4).bg(c).loop("opacity", { from: 0.35, to: 1, period: 1400 }))
            .child(this.label(t, "NEEDS YOUR ANSWER", c)))
          .child(div().text_size(16).font_semibold().line_height(1.3).text_color(t.foreground).whitespace_normal().max_h(63).overflow_hidden().child(a.question ?? ""))
          .child(div().text_size(11).text_color(t.muted).child(meta))
          .child(button)))
      .when(more > 0, (el) => el.child(div().px(4).text_size(12).text_color(t.muted).child(`and ${more} more waiting`)));
  }

  renderApproval(t) {
    let body;
    if (this.error) body = this.problem(t);
    else if (!this.doc) body = div();
    else if (!this.value()) body = this.quiet(t, "The secretary has not written anything yet.");
    else {
      // Oldest first: the one that has waited longest is answered first.
      const approvals = [...(this.value().approvals ?? [])].sort((x, y) => Date.parse(x.asked_at) - Date.parse(y.asked_at));
      body = approvals.length ? this.card(t, approvals[0], approvals.length - 1, Date.now()) : this.quiet(t, "Nothing waiting for you.");
    }
    return v_flex().size_full().min_h(0).justify_end().pb(4).child(body);
  }

  // ---- consult --------------------------------------------------------------

  renderConsult(t) {
    const sec = this.secretary();
    if (sec?.status !== "blocked") return div();
    return v_flex().id("consult").w(300).px(16).py(14).gap(8).cursor_pointer()
      .on_click(() => run("pane.focus", { terminal: sec.address }))
      .child(this.label(t, "THE SECRETARY IS ASKING YOU", t.blocked))
      .child(div().text_size(14).font_medium().line_height(1.35).text_color(t.foreground).whitespace_normal().max_h(58).overflow_hidden()
        .child(sec.report?.msg || "It is waiting for your answer."))
      .child(div().text_size(11).text_color(t.dim).child("Answer in the secretary's terminal"));
  }

  render(_cx) {
    const t = theme();
    if (this.role === "consult") return this.renderConsult(t);
    if (this.role === "approval") return this.renderApproval(t);
    if (this.role === "workers") return this.renderWorkers(t);
    return div().p(12).text_size(12).text_color(t.dim).child(`org-cockpit: unknown role "${this.role}"`);
  }
}
