# Open questions

Each section is one decision the owner has not made. This document records the question, what we know (with sources), and the options. It does not choose.

Sources used below:

- **Core docs**: herdr-core `README.md`, `docs/commands.md`, `docs/templates.md`, `docs/security.md`, `schema/README.md`, and the `hc --skill` manual (hc 0.1.18).
- **App docs**: herdr-app `README.md` and its mod guide `defaults/AGENTS.md` (0.1.13).
- **Core measurement**: hc 0.1.18 with Claude Code 2.1.319 on WSL2, 2026-11-08, on a dedicated core (`HC_SESSION`), observed through `hc get --json`, `hc events --json`, `hc read`, and Claude Code's session logs.
- **Mod measurement**: herdr-app 0.1.13 with hc 0.1.18 on Windows, 2026-11-08, observed through `herdr-app check`, `herdr-app shot` and timestamped script logs.

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

**Decides.** The owner.

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

**Question.** paddock should run on what herdr already brings: the JavaScript that runs herdr-app mods, `hc` templates and its CLI, and the shell, without assuming a separately installed language or runtime such as Python or Node. For each component in the [architecture](architecture.md#components) (the `org` MCP server, the events bridge, `state.db`), which of these is it written in, or does it truly need another runtime?

**What we know.**

- Mod JavaScript is not Node: there are no Node APIs and no `setTimeout`; there are `exec` (capped at 10 minutes per call), `fetch`, file reads and writes (`fs/promises` writes only under `~/.config/herdr-app`), `cx.timer`, `cx.spawn`, and shared state. (App docs)
- Mods run only while herdr-app is open. (App docs)
- Templates run their `command` through `sh`. `hc run` runs any command in a kept terminal (`--keep`), which survives the window closing. (Core docs)
- `hc events --json` streams one JSON line per change; `seq` restarts with each core process and missed changes are not replayed. (Core docs; Core measurement)
- Core has a small document store: `doc.get` / `doc.set`, versioned, opaque JSON up to 1 MiB per value, kept across restarts, with change events in the event stream. It is API-only, with no CLI verb. (Core docs)
- Claude Code reaches tools through MCP servers it launches, or through shell commands. herdr exposes no MCP tools.

**Options, per component.**

- **`org` MCP server**: (a) a shell program speaking MCP over stdio; (b) shell commands the skills call instead of MCP tools; (c) a separate runtime, accepted as the one exception.
- **Events bridge**: (a) a shell pipeline on `hc events --json` in a kept terminal; (b) a mod, accepting gaps while no window is open; (c) part of the same program as the `org` server.
- **`state.db`**: (a) SQLite, which needs a SQLite tool that herdr does not ship; (b) append-only files (for example JSON lines) written from the shell or a mod; (c) core documents, reached through a JSON-RPC client.

**Decides.** The owner.
