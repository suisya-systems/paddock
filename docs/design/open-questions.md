# Open questions

Each section is one decision the owner has not made. This document records the question, what we know (with sources), and the options. It does not choose.

Sources used below:

- **Core docs**: herdr-core `README.md`, `docs/commands.md`, `docs/templates.md`, `docs/security.md`, `schema/README.md`, and the `hc --skill` manual (hc 0.1.18).
- **App docs**: herdr-app `README.md` and its mod guide `defaults/AGENTS.md` (0.1.13).
- **Core measurement**: hc 0.1.18 with Claude Code 2.1.319 on WSL2, 2026-11-08, on a dedicated core (`HC_SESSION`), observed through `hc get --json`, `hc events --json`, `hc read`, and Claude Code's session logs.
- **Mod measurement**: herdr-app 0.1.13 with hc 0.1.18 on Windows, 2026-11-08, observed through `herdr-app check`, `herdr-app shot` and timestamped script logs.
- **Record measurement**: the predecessor's `state.db`, measured on 2026-11-08 (used in Q8 only).
- **Store observation**: the `doc.set` definition in `hc schema`, and `doc.set` / `doc.get` run through `hc connect`, hc 0.1.18, 2026-11-08 (used in Q8 only).
- **App type definitions**: herdr-app's `AGENTS.md`, `herdr.d.ts` and `gpui-kit.d.ts` (used in Q8 only).

## Q1. App mod or our own client?

**Question.** Is the window built as herdr-app mods, or as our own client that uses only herdr-core? If our own, is it a TUI or a web client?

**What we know.**

- Mods are JavaScript describing native GPUI elements, with live `spaces()` / `agents()` / `terminals()` / `focused()`, `exec`, `fetch`, file access, overlays that can hold a live terminal, `notify`, and shared state. No HTML, CSS, DOM or `setTimeout`. (App docs)
- The mod loop works: duplicate, change one line, `herdr-app check`, save to redraw, `herdr-app shot`. About 1.7 s from save to PNG; about 9 minutes end to end including mistakes. (Mod measurement)
- `check` does not lay out the mod; a zero-height list was only visible in the shot. (Mod measurement; App docs: "It does not lay out the mod")
- Mods are trusted code, not sandboxed. The `.d.ts` type files are rewritten on every start to match the version. herdr-app on Linux needs Vulkan. (App docs)
- herdr-core is meant to have other clients: `hc schema` (OpenRPC), `terminal.attach` streams the first paint then raw output, and `hc connect` carries the API over stdin/stdout or SSH. (Core docs)

**Options.**

- **A. herdr-app mods.** Least new code; tied to the app's release cadence, its type files, and a GPU.
- **B. Our own TUI.** Reconnect the predecessor's terminal client (renga) to `terminal.attach` and the OpenRPC API. Cheapest of the own-client paths and keeps that client alive.
- **C. Our own native app.** Stands where herdr-app already stands, so there is little reason for it.
- **D. Our own web client** (for example xterm.js fed by `terminal.attach`). The case for it is reaching the cockpit from a phone browser. Rendering `terminal.attach` into xterm.js has not been tried yet.

Either way the organization layer (templates, `org` tools, `state.db`, skills) stays the same ([architecture §2](architecture.md#2-design-principles)).

**Decided** (2026-11-09): option A, herdr-app mods ([decision 0003](../decisions/0003-screen-as-app-mods.md)).

## Q2. How much of a child's reporting goes through the mailbox?

**Question.** Do workers report only through the `org` mailbox, including "I'm done"? Or does completion also raise a window notification?

**What we know.**

- `done` already reaches herdr-core as OSC 7501 status, with a separate `turn` event at each turn's end. (Core measurement)
- `hc` itself sends notes to a parent when a child needs attention or ends, and `hc wait --children any|all` returns on a child's news or a message. (Core docs)
- `hc send` to an idle parent becomes its next prompt; with half-typed input it is joined to it with no separator. In-turn delivery was not observed. (Core measurement)
- `hc` can be configured with `notes = false` so it types nothing on its own. (Core docs)

**Options.**

- **A. Mailbox only.** The secretary learns of completion at its next `check_messages`.
- **B. Mailbox plus a window notification** on completion.
- **C. Mailbox plus herdr-core's own child notes**, accepting that those notes are typed into the parent's terminal.

**Decides.** The owner.

## Q3. Incident threshold when the secretary does not move

**Question.** When a worker stays `blocked` and the secretary does not act, after how long, and on what condition, is a person notified as an incident?

**What we know.**

- `blocked` carries `kind` (for example `permission`) and `msg`, visible in `hc get` and `hc events`. (Core measurement)
- `hc send` refuses a blocked terminal without `--force`, so nothing typed by accident answers its dialog. (Core docs; Core measurement)
- A Claude Code that stops at its startup folder-trust prompt reports no status at all, so it is never `blocked` and herdr-app does not list it. (Mod measurement)

**Options.** A fixed time; a time per `kind`; "the secretary's own status has not changed for N minutes while a worker is blocked". A separate rule is needed for terminals that never reported status after launch.

**Decides.** The owner.

## Q4. Worker recovery after a core restart

**Question.** After a full core stop and start, are workers rebuilt per run, or resumed with `claude --continue`?

**What we know.**

- `hc server restart` keeps programs running; `hc server stop` then `start` ends them, and `--keep` terminals come back as shells in their last folder. Core never reruns the original command. (Core docs; Core measurement)
- `hc run ... claude --continue` in the same folder resumed the same session and answered a codeword set before the stop. (Core measurement)
- That measurement had only one conversation in the folder. Behavior with several conversations in one folder was not measured. (Core measurement)
- A launch's `first_message: {sent: false, reason}` survives a core restart in `hc get`. (Core docs)

**Options.**

- **A. Rebuild per run** from `state.db`: a fresh worker with the original task and the worktree as it is.
- **B. Try `--continue`** in the worktree, and fall back to A when it fails.

**Decides.** The owner.

## Q5. Does the secretary write mods?

**Question.** Is the secretary (or a worker) allowed to change the window's mods? If so, how are changes reviewed?

**What we know.**

- Mods are trusted code with unrestricted commands and network access. (App docs)
- Saving a mod redraws the window at once; a broken edit keeps the last good version and reports the error. (App docs)
- An agent can check its own UI change with `check` and `shot` in seconds. (Mod measurement)
- The architecture already denies workers writes to `~/.config/herdr-app`. ([architecture §4](architecture.md#4-where-each-part-goes))

**Options.**

- **A. No.** People change mods.
- **B. Yes, through pull requests** to paddock's own mods (for example under `mods/org-*/`), installed after review.
- **C. Yes, directly**, for a scratch copy only.

**Decides.** The owner.

## Q6. How the predecessor's runtime pieces are wound down

**Question.** How are renga (the predecessor's terminal client) and claude-org-runtime (its runtime, including an adapter for the older Herdr TUI) ended?

**What we know.**

- The older Herdr TUI (`herdrdev/herdr`) does not share agents with herdr-core or herdr-app, so its adapter does not carry over. (App docs and the three repositories' descriptions)
- If Q1 picks option B, renga's client side is reused on top of herdr-core.

**Options.** Declare maintenance mode for both; state that the Herdr adapter is for the older TUI only; archive after paddock replaces them in daily use. The answer depends partly on Q1.

**Decides.** The owner.

## Q7. Windows

**Question.** Is WSL2 the supported way to run paddock on Windows?

**What we know.**

- herdr-core builds exist for Windows x86_64, and on Windows templates need `sh` on PATH (for example from Git for Windows). (Core docs)
- herdr-app installs on x64 Windows. (App docs)
- Claude Code's sandbox uses bubblewrap, which is Linux-only, so a native Windows worker would run without it.
- The mod measurement ran herdr-app and hc natively on Windows. A Windows Claude Code launched there reported no status because it stopped at the folder-trust prompt. (Mod measurement)
- The core measurement ran entirely inside WSL2 and worked. (Core measurement)

**Options.**

- **A. WSL2 only** for core and agents; the window may be native.
- **B. Native Windows** as well, without the sandbox.

**Decides.** The owner.

## Q8. What is each component written in?

**Question.** paddock should run on what herdr already brings: the JavaScript that runs herdr-app mods, `hc` templates and its CLI, and the shell, without assuming a separately installed language or runtime such as Python or Node. For each component in the [architecture](architecture.md#5-components-and-what-they-are-written-in) (the `org` MCP server, the events bridge, `state.db`), which of these is it written in, or does it truly need another runtime?

**What we know.**

- Mod JavaScript is not Node: there are no Node APIs and no `setTimeout`; there are `exec` (capped at 10 minutes per call), `fetch`, file reads and writes (`fs/promises` writes only under `~/.config/herdr-app`), `cx.timer`, `cx.spawn`, and shared state. (App docs)
- Mods run only while herdr-app is open. (App docs)
- Templates run their `command` through `sh`. `hc run` runs any command in a kept terminal (`--keep`), which survives the window closing. (Core docs)
- `hc events --json` streams one JSON line per change; `seq` restarts with each core process and missed changes are not replayed. (Core docs; Core measurement)
- Core has a small document store: `doc.get` / `doc.set`, versioned, opaque JSON up to 1 MiB per value, kept across restarts, with change events in the event stream. It is API-only, with no CLI verb. (Core docs)
- Claude Code reaches tools through MCP servers it launches, or through shell commands. herdr exposes no MCP tools.
- A herdr-app mod cannot touch SQLite directly: the mod runtime has no Node API, the type definitions have no database API, and what a mod can use is `readFile`, `writeFile`, `fetch` and `exec`. Reaching SQLite from a mod therefore means `exec` of a separate program. (App type definitions; App docs)

**What the record store has to hold.** The predecessor's `state.db` is the only measured example of paddock's records (runs, events; messages are not measured). On 2026-11-08 (Record measurement):

| Measure | Value |
| --- | --- |
| Whole database | 6.5 MB |
| `events` | 14,850 rows, about 3.5 MB of payload, since 2026-05-08 (about 6 months) |
| `events`, last 30 days | 5,805 rows, 1.7 MB (about 57 KB per day on average) |
| `events`, busiest day | 862 rows, 256 KB |
| `events`, largest single task | 11 KB |
| `runs` | 1,201 rows, about 0.2 MB |
| Completed tasks | 324 in the last 30 days; 1,029 in 6.8 months |

The most frequent event types in the last 30 days were `hook_denied` (1,057), `ci_completed` (404), `worker_spawned` (389), `delegate_sent` (380), `worker_spawn_verified` (379), `codex_round_started` (365), `pr_watch_pane_started` (355) and `work_discovery_scanned` (325). Several of these belong to the predecessor's machinery (hook denials, pane-watch and discovery scans), so paddock's mix will differ; the sizes below are the planning input, not a forecast.

Growth is assumed by the owner to be at least 2 times, and pessimistically 4 times, the last-30-day figures. That multiplier is a weak basis: of the 3.5 MB in six months, 1.7 MB is the last 30 days, and the earlier months averaged about 0.36 MB each, so the last month is already about 4.7 times the earlier average. "4x" is one period's trend, not a ceiling. A design limit should be taken again from an event count of 10 times today and from the p95 day (not the average, and not only the single busiest day).

**How the core document store behaves** (Store observation):

- One document holds at most 1 MiB. Writes carry a version number and use optimistic locking; each save is atomic and emits a doc event.
- Deleting by setting a document to `null` does not remove the entry: it stays, with its version number.
- All documents live in one file, `docs.json`, directly under the state directory, and the whole file is rewritten on every write.

**What those numbers allow, per document layout.** Sizes use the last-30-day figures; "2x" and "4x" are the owner's growth assumptions.

| Layout | Now | 2x | 4x | Holds? |
| --- | --- | --- | --- | --- |
| One document per month (events) | 1.7 MB | 3.4 MB | 6.8 MB | No. Already over 1 MiB today. |
| One document per day (events), busiest day | 256 KB | 512 KB | about 1.0 MiB | Only with no headroom at 4x: the busiest day reaches the 1 MiB limit before any wrapper or version field, so a slightly busier day fails. The figure is payload only; wrapping rows in an array adds overhead, so there is less room than shown. |
| One document per task | at most 11 KB each | at most 22 KB | at most 44 KB | Size is fine. Entry count is not: about 3,900 per year now, 7,800 at 2x, over 15,000 at 4x (324 tasks in 30 days, times 12), and entries are never removed. Together with the events they would make `docs.json` tens of MB (1.7 MB per month is about 20 MB per year now, about 80 MB at 4x), all rewritten on each write. |
| A few fixed-name documents (current state only) | small | small | small | Yes, as long as each holds only what is in progress and old items are dropped by the writer. |

**What an append-only file allows.** Events as one JSON-lines file per month would be 1.7, 3.4 and 6.8 MB per month now, at 2x and at 4x, and 12 files per year. A file has no per-value limit, and appending by itself does not rewrite earlier lines (whether herdr offers an append is the first open point under "What the sizes do not cover" below). Completed-task history (runs, task summaries) is far smaller than events and fits one JSON-lines file per month or per year; its per-task size was not measured. Reading across files is a text scan, and how several processes append to one file at once (the events bridge and the `org` server) was not measured.

**Which forms hold, by condition.** These are the forms the numbers allow, not a decision:

- In-progress state (live runs, pending messages, current summaries) fits a handful of fixed-name core documents, or small files.
- The append-only event log fits one JSON-lines file per month, at up to 6.8 MB per month at 4x.
- Completed-task history fits one JSON-lines file per month or per year.
- SQLite remains only if frequent searches across all records are part of how paddock is used. It needs one SQLite command-line program (a single static binary, not Python or Node) run through `exec` or a shell. herdr does not ship it, and a mod cannot open the database directly (see above). Whether shipping one such binary breaks the "nothing separately installed" constraint is the owner's call.
- One document per month, or per task, does not hold for events; one per day holds only at 2x or below.

**What the sizes do not cover.** The sizes above fit at 4x, but a layout can fit and still fail on the points below. A reading of the review of this section: a text that lacks conditions 1, 2, 5 and 7 below is a form where only the size is right. Each point states the condition under which the form holds and, where there is one, the evidence that would settle it. None is decided here.

1. **Concurrent appends.** The monthly JSON-lines file would have several writers: the window's mod, parallel workers, hooks, the events bridge. No herdr API known so far appends to a file: the `file.write` and `writeFile` descriptions mention neither append nor offset. A whole-file write turns into read, join, write, and two writers lose one update. A shell `>>` is not guaranteed atomic across WSL and Windows, or natively on Windows. The form holds if either (a) each file has one writer (`events/<YYYY-MM>/<writer-id>.jsonl`, readers merge by `seq` and `ts`), or (b) core is the only place that appends. Evidence from `hc schema` (hc 0.1.18): `file.write` is described as "Write a file ... Swapped in whole: a reader sees old or new, never half", and its parameters are only `cwd`, `data`, `on` and `path`, with no append or offset. It replaces the whole file, so it is not an append primitive, and the lost-update concern above stands. `file.edit` finds `old` exactly once and replaces it, all edits succeeding or none, with parameters `cwd`, `edits`, `on` and `path`. `file.read` is described as "lines from offset, at most limit and 8 MB", with parameters `cwd`, `limit`, `offset`, `on` and `path`: a range of lines can be read, but one read is capped at 8 MB. That cap also constrains points 2 and 6: a month file at the 4x estimate (6.8 MB) sits just under it, and at 10 times today's event count a month file can no longer be read in one call. Still open: whether core serializes `file.write` calls from different writers.
2. **Read path.** There is no query engine. Today's consumers (triage, the dispatcher's "was there a report since X", the watcher guard's time comparison) would parse a whole month file, several MB of `JSON.parse` inside a mod. The form holds if the log is for audit only and consumers answer from fixed-name documents (a read model), with one defined command that rebuilds those documents from the log. Open option: "was there a report since X" may be answered by each worker writing its own document and the asker subscribing to doc events.
3. **Who writes.** `hc events` is a live stream, not a ledger; missed changes are not replayed. If a mod receives events and writes them, whatever happens while the window is closed is lost. The form holds if the party that causes an event writes its own line.
4. **Bounds of `docs.json`.** Fixed names are not enough: (a) a task name used once as a document name leaves its entry for good; (b) the content of a fixed document can grow without end (resolved items kept in a pending-decisions document, completion summaries piling up); (c) each `set` rewrites the whole file and sends one doc event into `hc events`, so updating a summary on every event can loop or flood. The form holds if document names are only those listed in this design, each document has a size cap and a one-line pruning rule, and summaries are updated in batches at a fixed interval.
5. **Order and machines.** Timestamps from each writer's own clock do not give line order equal to time order. With `hc machine add` and `--on`, a worker on another machine may have its `file.write` land on that host. The form holds if the record has one owning host (the primary), order comes from a `seq` the primary assigns (or, per writer, a sequence inside the writer plus `ts`), and file names use UTC.
6. **Growth.** See the note after the measurement table: use 10 times the event count and the p95 day as design limits, not 4x.
7. **Which events to keep.** Whether events should be carried over at all is open. By kind: coordination signals (`delegate_sent`, `worker_reported`); copies of another system's facts (`worker_spawned`, `ci_completed`); the tool's own measurements (`hook_denied`, 1,057 of 5,805 rows or 18%, and `work_discovery_scanned`). If coordination went into documents with doc events, measurements into counters, and only audit into JSON lines, the row count would fall; how far (the order of half) was not computed over all kinds.
8. **Conflicts on fixed documents.** On a version mismatch the writer must get again, reapply its change to the latest value, and set. A mod has no `setTimeout`, but it has `cx.timer` and `cx.spawn`, so a back-off may be possible while the window is open; whether a retry loop fits those APIs was not tried, and a shell or other writer has no such help. The form holds if no two parties write the same document (a worker writes only its own, the secretary only the aggregate documents), or if writes go through one helper that reapplies a change function.
9. **Rotation.** Nothing is defined to compress or roll up files. A mod can schedule work with `cx.timer` only while herdr-app is open, so it cannot be the one party that guarantees a roll-up; whether `hc` templates can run on a schedule is not confirmed. The smallest form that holds: keep monthly files indefinitely, readers look at the last two months only, and no yearly file is made. At 4x this is about 80 MB per year on disk.
10. **What herdr alone cannot do.** No herdr primitive is at once unbounded, safe under concurrent writers, and queryable. Two honest alternatives: (a) per-writer JSON lines for audit plus fixed-name read-model documents, with no added dependency; (b) if cross-record queries stay in daily use, one static `sqlite3` binary distributed as a dependency of the `hc` templates.

**Options, per component.**

- **`org` MCP server**: (a) a shell program speaking MCP over stdio; (b) shell commands the skills call instead of MCP tools; (c) a separate runtime, accepted as the one exception.
- **Events bridge**: (a) a shell pipeline on `hc events --json` in a kept terminal; (b) a mod, accepting gaps while no window is open; (c) part of the same program as the `org` server.
- **`state.db`** (sizes above): (a) SQLite, which needs a SQLite tool that herdr does not ship and is out of reach of a mod's own code; (b) append-only files (for example JSON lines) written from the shell or a mod; (c) core documents, reached through a JSON-RPC client, limited by the layouts in the table above; (d) a mix, for example core documents for in-progress state and JSON-lines files for the log and history.

**Decided for `state.db`** (2026-11-09): option (d), core documents for in-progress state and per-writer monthly JSON lines for history, no SQLite ([decision 0004](../decisions/0004-records-documents-and-jsonl.md)). The `org` server and the events bridge are still open.

## Q9. Where does the conversation language setting live?

**Question.** The rules are written in English and the language the secretary speaks with people is a setting ([architecture §2](architecture.md#2-design-principles), principle 7). Where is that setting kept, and how does it reach the agent?

**What we know.**

- A template's body is the agent's opening instructions, and core appends the task after a blank line. Templates are read fresh on each use. (Core docs)
- Unknown template header fields are ignored, so the header cannot carry the setting on its own. (Core docs)

**Options.** A line in the secretary's template body; a value in paddock's own configuration that a skill reads at start; an environment variable passed at launch; detection from the environment only, with no stored value.

**Decides.** The owner.
