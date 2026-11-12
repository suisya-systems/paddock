// paddock's organization screen (docs/design/architecture.md section 7), one mod in three
// roles placed by layouts/paddock.json through props.role:
//   "workers"  left: one tile per worker terminal (labelled task_id): status colour, its last
//              lines, "Needs you" when blocked. Click opens the terminal to answer there.
//   "approval" bottom right: the oldest org-state approval as one card, its controls following
//              who answers it (answer_in: the worker's own terminal, or the secretary).
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

// Is terminal x the one named `want`? `want` is a name on this machine, or `<machine>/<name>` for
// a terminal on another machine (its address is then `<machine>/tN`). A bare name never matches
// another machine's terminal: org-state is read from the machine `want` names.
function named(x, want) {
  const slash = x.address?.indexOf("/") ?? -1;
  if (slash < 0) return x.name === want || x.address === want;
  return x.address === want || `${x.address.slice(0, slash)}/${x.name}` === want;
}

// hc's CLI has no doc verb, and exec has no stdin, so a shell pipes one JSON-RPC line into `hc connect`.
// `hc connect` (0.1.18) ends at end of input without waiting for its answer, so stdin is held open 1 s.
// Windows has no sh, and hc is often not on PATH there: pwsh, with hc's default install folder.
// ponytail: one process and 1 s per read; subscribe to doc events once a long-lived reader exists.
function rpcCommand(on) {
  if (!on && window()?.platform === "windows") {
    const hcExe = '$hc = (Get-Command hc -ErrorAction SilentlyContinue).Source; if (-not $hc) { $hc = "$env:LOCALAPPDATA\\Programs\\herdr-core\\hc.exe" }';
    return ["pwsh", ["-NoProfile", "-NonInteractive", "-Command", `${hcExe}; & { '${REQ.replace(/'/g, "''")}'; Start-Sleep -Seconds 1 } | & $hc connect`]];
  }
  return ["sh", ["-c", '{ printf "%s\\n" "$1"; sleep 1; } | hc connect', "sh", REQ]];
}

// `on`: the machine whose core holds org-state (the secretary's), null for this one. Another
// machine is reached through herdr-core and runs sh there.
// ponytail: assumes a remote machine has sh (Linux, macOS, WSL); a remote native Windows does not.
async function readDoc(on) {
  const [cmd, args] = rpcCommand(on);
  const r = await exec(cmd, args, { on });
  const line = r.stdout.split("\n").find((l) => l.trim().startsWith("{"));
  if (!line) throw new Error(r.stderr.trim() || `hc connect exited with ${r.code} and no answer`);
  const msg = JSON.parse(line);
  if (msg.error) throw new Error(msg.error.message);
  return msg.result; // { value, version }; version 0: never written
}

// The org commands, where org-start places them (Issue #128: PADDOCK_BIN_DIR, default
// ${XDG_DATA_HOME:-~/.local/share}/paddock/bin). A machine whose org-start predates #128 has them
// beside the herdr-core templates instead (APPDATA on Windows Git Bash).
// The card answers through them, on the secretary's machine; it never writes org-state (L-N8).
const ORG = 'o=${PADDOCK_BIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/paddock/bin}/org; ' +
  '[ -f "$o" ] || o=${PADDOCK_CORE_TEMPLATES_DIR:-${APPDATA:-${XDG_CONFIG_HOME:-$HOME/.config}}/herdr-core/templates}/org';
// ponytail: needs sh on that machine; a native Windows one without it shows "Not sent".
async function sendAnswer(on, id, word) {
  const r = await exec("sh", ["-c", `${ORG}; exec bash "$o" --as person send_message secretary "$1"`, "sh", `ANSWER ${id} ${word}`], { on });
  if (r.code !== 0) throw new Error(r.stderr.trim() || `org exited with ${r.code}`);
}

function duration(ms) {
  const m = Math.floor(ms / 60000);
  if (!(m >= 1)) return "<1m";
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  return h < 48 ? `${h}h` : `${Math.floor(h / 24)}d`;
}
// Text on a filled state colour: black or white, whichever contrasts more with it (WCAG relative
// luminance), so a label on the amber or red fill stays readable in light and dark themes alike.
function ink(hex) {
  const m = /^#?([0-9a-f]{6})/i.exec(hex ?? "");
  if (!m) return "#ffffff";
  const [r, g, b] = [0, 2, 4].map((i) => {
    const v = parseInt(m[1].slice(i, i + 2), 16) / 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  });
  const l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  return (l + 0.05) / 0.05 >= 1.05 / (l + 0.05) ? "#000000" : "#ffffff";
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
    this.sent = new Map(); // approval id -> { word, state: "sending" | "sent" | "failed", at }
    this.cx = cx; // init's cx is an AsyncContext: valid after init, used by the card's clicks
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

  // One read at a time, so a slow older answer never replaces a newer one.
  refresh(cx) {
    if (this.loading) return;
    this.loading = true;
    cx.spawn(async (cx) => {
      try {
        this.doc = await readDoc(this.secretaryMachine());
        this.error = null;
        // An answered approval leaves org-state when the secretary has passed it on.
        const ids = new Set((this.value()?.approvals ?? []).map((a) => a.id));
        for (const id of this.sent.keys()) if (!ids.has(id)) this.sent.delete(id);
      } catch (e) {
        this.error = String(e?.message ?? e);
      } finally {
        this.loading = false;
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

  // "wsl/secretary" -> "wsl"; a bare name -> null (this machine).
  secretaryMachine() {
    const n = this.secretaryName();
    return n.includes("/") ? n.slice(0, n.indexOf("/")) : null;
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

  // One answer per approval: a second click, or the other button, does nothing unless the send failed.
  answer(a, word) {
    const s = this.sent.get(a.id);
    if (s && s.state !== "failed") return;
    this.sent.set(a.id, { word, state: "sending" });
    this.cx.spawn(async (cx) => {
      cx.notify();
      try {
        await sendAnswer(this.secretaryMachine(), a.id, word);
        this.sent.set(a.id, { word, state: "sent", at: Date.now() });
      } catch {
        this.sent.set(a.id, { word, state: "failed" });
      }
      cx.notify();
    });
  }

  // The amber fill follows the secretary's recommendation; with none, both answers are outlined.
  choice(t, a, word, label, primary) {
    const s = this.sent.get(a.id);
    const busy = s?.state === "sending";
    const mine = busy && s.word === word;
    const c = t.blocked;
    return h_flex().id(`${word}-${a.id}`).flex_1().min_w(0).h(36).rounded(8).gap(6).items_center().justify_center()
      .text_size(13).font_semibold()
      .when(primary, (el) => el.bg(c).text_color(ink(c)))
      .when(!primary, (el) => el.border(1).border_color(t.foreground + "29").text_color(t.foreground))
      .when(busy, (el) => el.opacity(mine ? 0.6 : 0.35))
      .when(!busy, (el) => el.cursor_pointer().hover((st) => st.bg(primary ? c + "d9" : t.hover)))
      .on_click(() => this.answer(a, word))
      .child(mine ? "Sending…" : label)
      .when(primary && !mine, (el) => el.child(div().text_size(12).font_medium().child("Recommended")));
  }


  // Answering in words goes to the secretary, never to a worker's terminal.
  secretaryLink(t) {
    const sec = this.secretary();
    return div().id("open-secretary").truncate().text_size(12)
      .when(Boolean(sec), (el) => el.text_color(t.muted).cursor_pointer().hover((s) => s.text_color(t.foreground))
        .on_click(() => run("pane.focus", { terminal: sec.address })))
      .when(!sec, (el) => el.text_color(t.muted))
      .child(sec ? "Open the secretary to answer in words" : "The secretary is not running");
  }

  // Who answers (architecture 7.1): answer_in "worker" is a worker's own permission prompt or
  // dialog, answered only in its terminal, so the card opens it and offers no Yes / No. Anything
  // else is answered through the secretary: Yes / No to its mailbox, or in words in its pane.
  // Three bands: the state strip and the controls are pinned, the text between them scrolls, so
  // nothing the secretary wrote is cut (Issue #258).
  card(t, a, more, now, title) {
    const c = t.blocked;
    const inWorker = a.answer_in === "worker";
    const term = inWorker && terminals().find((x) => x.state === "live" && x.labels?.task_id === a.task_id);
    const stillBlocked = term && term.status === "blocked";
    const failed = this.sent.get(a.id)?.state === "failed";
    // An approval without an id cannot be answered here (the secretary matches answers by id).
    const answerable = !inWorker && typeof a.id === "string" && a.id !== "";
    const task = a.task_id || "an unnamed task";
    // A malformed entry still says which approval it is, so the person can ask about it.
    const question = a.question || `Approval ${a.id || "without an id"} for ${task}`;
    const note = !a.question ? "No question was written. Ask the secretary what it needs."
      : inWorker ? "Answered in its own terminal, not from here." : null;
    const waited = since(a.asked_at, now);
    // The secretary removes an answered approval; until it does, the card says it may be answered.
    const meta = [title && title !== task && task, waited && `waiting ${waited}`, term && !stillBlocked && "no longer blocked, answered?"]
      .filter(Boolean).join(" · ");
    const loud = !inWorker || !term || stillBlocked;
    const label = inWorker ? `${String(a.task_id || "a worker").toUpperCase()} NEEDS YOU` : "THE SECRETARY IS ASKING YOU";
    const rec = a.recommend === "yes" || a.recommend === "no" ? a.recommend : null;
    const missing = [!a.background && "background", !a.if_yes && "what Yes does", !a.if_no && "what No does", !rec && "recommendation"].filter(Boolean);
    // A field the secretary left out is named where it would be; with nothing written, one line.
    const none = missing.length === 4;
    const gone = (names) => names.length > 0 && !none;
    const unwritten = (names) => div().text_size(12).line_height(1.4).text_color(t.foreground).whitespace_normal()
      .child(`Not written: ${names.join(", ")}.` + (none && a.question ? " Ask the secretary before answering." : ""));
    const outs = missing.filter((m) => m.startsWith("what"));
    const text = (s, color) => div().text_size(13).line_height(1.45).text_color(color).whitespace_normal().child(s);
    const outcome = (word, s) => h_flex().gap(8).items_start()
      .child(div().w(28).flex_none().text_size(13).font_semibold().line_height(1.45).text_color(t.foreground).child(word))
      .child(text(s, t.foreground).flex_1().min_w(0));
    const open = term && div().id("open").h(36).rounded(8).flex().items_center().justify_center().cursor_pointer()
      .text_size(13).font_semibold()
      .when(stillBlocked, (el) => el.bg(c).text_color(ink(c)))
      .when(!stillBlocked, (el) => el.border(1).border_color(t.foreground + "29").text_color(t.foreground))
      .hover((st) => st.bg(stillBlocked ? c + "d9" : t.hover))
      .on_click(() => run("terminal.peek", { terminal: term.address }))
      .child(stillBlocked ? `Open ${a.task_id} to answer` : `Open ${a.task_id}`);
    // Two parts of one card: the text (head), which renderApproval puts in the rail's scroll area,
    // and the controls (foot), pinned below it. A scroll area nested in auto-height columns is
    // measured at zero height by the layout (Issue #258's first render showed no text at all), so
    // the scroll area is the rail itself, sized by the layout block.
    const edge = c + "59";
    const head = v_flex().id(`ap-${a.id}`).flex_none().rounded_t(12).bg(t.raised).border_t(1).border_x(1).border_color(edge)
        .child(h_flex().flex_none().h(36).px(16).gap(8).items_center().rounded_t(11).bg(c + "1f")
          .child(div().size(8).flex_none().rounded(4).bg(c).when(loud, (el) => el.loop("opacity", { from: 0.35, to: 1, period: 1400 })))
          .child(this.label(t, label, c)))
        .child(v_flex().px(16).pt(14).pb(16).gap(16)
          .child(v_flex().gap(4)
            .child(div().text_size(13).font_semibold().line_height(1.35).text_color(t.foreground).whitespace_normal().child(title || task))
            .when(Boolean(meta), (el) => el.child(div().text_size(11).text_color(t.muted).whitespace_normal().child(meta))))
          .child(v_flex().gap(6)
            .child(div().text_size(15).font_semibold().line_height(1.35).text_color(a.question ? t.foreground : t.muted).whitespace_normal().child(question))
            .when(Boolean(note), (el) => el.child(div().text_size(12).line_height(1.4).text_color(t.foreground).whitespace_normal().child(note))))
          .when(Boolean(a.background), (el) => el.child(v_flex().gap(4)
            .child(this.label(t, "BACKGROUND", t.muted))
            .child(text(a.background, t.foreground))))
          .when(gone(a.background ? [] : ["background"]), (el) => el.child(unwritten(["background"])))
          .when(Boolean(a.if_yes || a.if_no), (el) => el.child(v_flex().gap(6)
            .child(this.label(t, "IF YOU ANSWER", t.muted))
            .when(Boolean(a.if_yes), (e) => e.child(outcome("Yes", a.if_yes)))
            .when(Boolean(a.if_no), (e) => e.child(outcome("No", a.if_no)))
            .when(gone(outs), (e) => e.child(unwritten(outs)))))
          .when(!a.if_yes && !a.if_no && gone(outs), (el) => el.child(unwritten(outs)))
          .when(Boolean(rec || a.why), (el) => el.child(v_flex().rounded(8).bg(t.background).px(12).py(10).gap(6)
            .child(h_flex().gap(8).items_center()
              .child(this.label(t, rec ? "SECRETARY RECOMMENDS" : "FROM THE SECRETARY", t.muted))
              .when(Boolean(rec), (e) => e.child(div().flex_none().px(6).h(18).rounded(5).bg(c).flex().items_center()
                .text_size(12).font_semibold().text_color(ink(c)).child(rec === "yes" ? "Yes" : "No"))))
            .when(Boolean(a.why), (e) => e.child(text(a.why, t.foreground)))))
          .when(gone(rec ? [] : ["recommendation"]), (el) => el.child(unwritten(["recommendation"])))
          .when(none, (el) => el.child(unwritten(missing))));
    const foot = v_flex().flex_none().gap(8)
      .child(v_flex().rounded_b(12).bg(t.raised).border_b(1).border_x(1).border_color(edge)
        .child(div().mx(16).h(1).bg(t.foreground + "14"))
        .child(v_flex().px(16).py(12).gap(10)
          .when(failed, (el) => el.child(div().text_size(12).text_color(c).child("Not sent. Try again.")))
          .when(answerable, (el) => el.child(h_flex().gap(8)
            .child(this.choice(t, a, "yes", "Yes", rec === "yes"))
            .child(this.choice(t, a, "no", "No", rec === "no"))))
          .when(Boolean(open), (el) => el.child(open))
          .when(inWorker && !term, (el) => el.child(div().text_size(12).line_height(1.4).text_color(c).whitespace_normal().child(`No terminal for ${task}. Tell the secretary.`)))
          .when(!inWorker || !term, (el) => el.child(this.secretaryLink(t)))))
      .when(more > 0, (el) => el.child(div().px(4).text_size(12).text_color(t.muted).child(`and ${more} more waiting`)));
    return { head, foot };
  }

  // A sent answer, quiet, until the secretary removes the approval; loud again after 2 minutes.
  sentRow(t, a, s, now) {
    const late = now - s.at > 120000;
    const text = `${s.word === "yes" ? "Yes" : "No"} · ${a.task_id} · ${late ? `not passed on yet, ${duration(now - s.at)}` : "passing on"}`;
    return div().px(4).truncate().text_size(11).text_color(late ? t.blocked : t.muted).child(text);
  }

  renderApproval(t) {
    let body;
    if (this.error) body = this.problem(t);
    else if (!this.doc) body = div();
    else if (!this.value()) body = this.quiet(t, "The secretary has not written anything yet.");
    else {
      // Oldest first: the one that has waited longest is answered first. The loud card is the
      // oldest not yet answered here, so a queue can be answered one click after another.
      const approvals = [...(this.value().approvals ?? [])].sort((x, y) => Date.parse(x.asked_at) - Date.parse(y.asked_at));
      const isSent = (a) => this.sent.get(a.id)?.state === "sent";
      const waiting = approvals.filter((a) => !isSent(a));
      const sent = approvals.filter(isSent);
      const now = Date.now();
      const titles = new Map((this.value().work ?? []).map((w) => [w.task_id, w.title]));
      const card = waiting.length ? this.card(t, waiting[0], waiting.length - 1, now, titles.get(waiting[0].task_id)) : null;
      // The rail scrolls; the spacer keeps a short card at the bottom, and flex_none keeps a long
      // one from being squeezed. The card's controls stay pinned under the scroll area.
      return v_flex().size_full().min_h(0).pb(4)
        .child(v_flex().id("approval-scroll").flex_1().min_h(0).gap(8).overflow_y_scrollbar()
          .child(div().flex_1())
          .children(sent.slice(0, 2).map((a) => this.sentRow(t, a, this.sent.get(a.id), now).flex_none()))
          .when(sent.length > 2, (el) => el.child(div().flex_none().px(4).text_size(11).text_color(t.muted).child(`+${sent.length - 2} answered`)))
          .child(card ? card.head : this.quiet(t, sent.length ? "Nothing else waiting for you." : "Nothing waiting for you.").flex_none()))
        .when(Boolean(card), (el) => el.child(card.foot));
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
