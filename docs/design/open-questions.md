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
- **Inventory probes**: probes P1 to P7 in the [predecessor inventory](predecessor-inventory.md#2-probes-run-for-this-inventory), hc 0.1.18 with Claude Code 2.1.319 on WSL2, 2026-11-08 (used from Q10 on).
- **Claude Code docs**: `claude --help` and the CHANGELOG of Claude Code 2.1.319 (used from Q10 on).
- **Env probe**: [`scripts/probes/env-remove-var.sh`](../../scripts/probes/env-remove-var.sh), hc 0.1.18 on a running core, 2026-11-09 (used in Q17 only).
- **Continue probe**: [`scripts/probes/continue-multi-conv.sh`](../../scripts/probes/continue-multi-conv.sh), hc 0.1.18 with Claude Code 2.1.319 on WSL2, core started from a login shell, 2026-11-10 (used in Q4 only).
- **Claude Code sandbox docs**: the sandboxing page of the Claude Code documentation (code.claude.com/docs/en/sandboxing), read 2026-11-11 (used in Q7 only).
- **Predecessor**: files of claude-org-ja, as listed in the [predecessor inventory](predecessor-inventory.md) (used from Q10 on).

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

**Decided (2026-11-10, owner): A.** Workers report completion only through the `org` mailbox. The secretary learns of it at its next check of the mailbox, and may block on `hc wait --children`, which returns the child's exit and code ([REC-4](predecessor-inventory.md), measured 2026-11-09). herdr-core's notes are turned off (`notes = false`).

- **B rejected:** the screen shows state through the organization's state, not through notifications.
- **C rejected:** notes are turned off, consistent with [decision 0002](../decisions/0002-org-mailbox-not-hc-send.md); nothing but a person types into the parent's terminal.

## Q3. Incident threshold when the secretary does not move

**Question.** When a worker stays `blocked` and the secretary does not act, after how long, and on what condition, is a person notified as an incident?

**What we know.**

- `blocked` carries `kind` (for example `permission`) and `msg`, visible in `hc get` and `hc events`. (Core measurement)
- `hc send` refuses a blocked terminal without `--force`, so nothing typed by accident answers its dialog. (Core docs; Core measurement)
- A Claude Code that stops at its startup folder-trust prompt reports no status at all, so it is never `blocked` and herdr-app does not list it. (Mod measurement)

**Options.** A fixed time; a time per `kind`; "the secretary's own status has not changed for N minutes while a worker is blocked". A separate rule is needed for terminals that never reported status after launch (decided below).

**Decides.** The owner.

**Decided (2026-11-10, owner): the third option, with N = 10 minutes.** A person is notified as an incident when a worker is `blocked` and the secretary's own status has not changed for N minutes. N starts at 10 and is tuned from use.

- **Why:** people are interrupted by escalation, not by `blocked`; an incident is the secretary itself not moving ([architecture §2 principle 6 and §6.2](architecture.md#6-flows)). So the condition watches the secretary, and a blocked worker only makes the wait matter. The check follows the stall rule in [MON-7](predecessor-inventory.md): an unchanged `status_ms` alone cannot tell a long `working` turn from a frozen one, so it is paired with a change in the screen or in the `turn` count.
- **Fixed time rejected:** it ignores that some blocked states are legitimate waits, for example a worker waiting on a person the secretary has already escalated to.
- **Time per `kind` rejected:** it needs a table of times per `kind` that nobody has measured, and `blocked` is measured for two prompts only, `permission` and `question` ([MON-5](predecessor-inventory.md)); other prompts are Unverified.
- **How it is evaluated:** the check reads `hc get` for the secretary and for each blocked worker. It fires when a worker is `blocked` and the secretary's `status_ms` is at least N minutes old, and then confirms the secretary is frozen, not in a long turn, by an unchanged `turn` count and an unchanged screen (`hc read --lines 0`) across the same N minutes ([MON-7](predecessor-inventory.md)). A fresh secretary status, screen or `turn` change resets it.
- **Still open:** who runs this check. The secretary cannot, because it is the one not moving; it needs a watcher outside it (a script or a mod), and a mod runs only while herdr-app is open ([NTF-1](predecessor-inventory.md)). The rule for terminals that never reported status after launch is decided below.
- **Not measured:** no run of the rule end to end, and no measurement of how long a healthy secretary keeps one status. N = 10 is a starting value, not a measured one.

### Terminals that never reported status after launch (Issue #8)

A terminal that never reported status is never `blocked`, so the rule above does not catch it. The facts: it reports no status at all and herdr-app does not list it ([MON-5](predecessor-inventory.md)); `hc run` returned after about 58 s with `first_message: {sent: false, reason: "it never reported its status, so it may be showing a dialog ..."}` ([Q13](#q13-how-does-a-new-worktree-get-past-claude-codes-folder-trust-dialog), probes P4 to P6); a launch's `first_message: {sent: false, reason}` survives a core restart in `hc get` ([Q4](#q4-worker-recovery-after-a-core-restart)).

**Decided (2026-11-10, owner): both signals, one number.** A terminal is treated as never-reported when either holds:

1. **Immediate:** `hc run` returns `first_message.sent = false`.
2. **Timeout:** the terminal has no status N minutes after launch. N is the same 10 minutes as in the rule above, so there is one number to tune.

- **Who is told:** a person, on the screen, in the same place as approvals and escalations (G3), with the terminal's name and the reason text from `first_message.reason`. This is an incident, not a message to the secretary: the secretary cannot see a worker that has no status.
- **Why both:** the immediate signal needs no waiting and already carries the reason; the timeout covers a terminal whose launch was never checked, or whose `first_message` was `sent: true` but which then stopped reporting. Using Q3's N keeps one threshold.
- **Consequence, delegation skill:** it already checks `first_message.sent` in the `hc run` result ([Q13](#q13-how-does-a-new-worktree-get-past-claude-codes-folder-trust-dialog)); on `false` it raises the incident above instead of pressing keys on the worker.
- **Consequence, who runs the timeout:** the same open question as the check above: a watcher outside the secretary. The incident is shown with the approvals and escalations, so it needs the same screen path.
- **Follow-ups (not done here):** the delegation skill's incident on `sent = false`; the watcher or mod that applies the timeout and shows the incident card.
- **Not measured:** whether the Q13 decision (worktrees under a trusted parent) makes case 1 rare in practice; that the timeout and the immediate signal agree on a real never-reported launch; how long a healthy launch takes to first report, so N = 10 may be far too long for this case; the "Load development channel?" startup prompt the predecessor met ([MON-5](predecessor-inventory.md)) under this rule.

## Q4. Worker recovery after a core restart

**Question.** After a full core stop and start, are workers rebuilt per run, or resumed with `claude --continue`?

**What we know.**

- `hc server restart` keeps programs running; `hc server stop` then `start` ends them, and `--keep` terminals come back as shells in their last folder. Core never reruns the original command. (Core docs; Core measurement)
- `hc run ... claude --continue` in the same folder resumed the same session and answered a codeword set before the stop. (Core measurement)
- That measurement had only one conversation in the folder. (Core measurement)
- Measured on 2026-11-10 (hc 0.1.18, Claude Code 2.1.319; [`scripts/probes/continue-multi-conv.sh`](../../scripts/probes/continue-multi-conv.sh), Issue #57; core from a login shell, template `command` with the `env -u` prefix, transcripts on): **`claude --continue` resumed the conversation whose transcript was written most recently, not the first or the last created.** Two separate conversations were run in one folder, each told its own codeword (A, then B started after A was stopped with `hc kill`). `claude --continue` from a template answered B's codeword (A first, B last: also the most recently created). Then A was resumed by id (`claude --resume <id>`) and stopped, so A was the last active and B the later created; `claude --continue` now answered A's codeword. A's transcript file time moved on resume and B's did not, and the two cases match the file times. Whether the pick is by file time or by an internal last-activity record was not told apart; the files agree in this run.
- The same probe's first launch in a fresh folder stopped at the folder-trust dialog (`first_message.sent: false`, [Q13](#q13-how-does-a-new-worktree-get-past-claude-codes-folder-trust-dialog)); `hc read` showed it and `hc keys <t> down enter` passed it. A later launch in the same folder did not show it.
- Consequence for option B: in a worktree that holds one worker's conversation, `--continue` resumes that one; if the folder also holds another conversation that was active later (for example a person opened Claude Code there), `--continue` resumes that one instead. Measured with two conversations only; each launch answered a codeword, so the resumed conversation was identified by content, not by id.
- A launch's `first_message: {sent: false, reason}` survives a core restart in `hc get`. (Core docs)

**Options.**

- **A. Rebuild per run** from `state.db`: a fresh worker with the original task and the worktree as it is.
- **B. Try `--continue`** in the worktree, and fall back to A when it fails.

**Decided (2026-11-10, owner): B.** After a full core stop and start, the secretary launches each worker again from the worker template with `claude --continue` in the worker's worktree. When that fails, it falls back to A: a fresh worker with the original task and the worktree as it is.

- **Basis (measured):** after a core stop, `claude --continue` in the same folder resumed the same session and answered a codeword set before the stop (Core measurement). With several conversations in one folder it resumes the conversation whose transcript was written most recently, not the first or last created (measured 2026-11-10, Issue #57, bullet above).
- **Why B over A:** a worker's worktree holds one conversation per task, so `--continue` brings back the working context: what the worker has read, tried and decided. A starts from the task and the files on disk and loses that context.
- **When the fallback applies:** (1) transcripts are off because the core inherited `CLAUDE_CODE_CHILD_SESSION` ([Q17](#q17-what-environment-do-the-core-and-its-terminals-start-with)); (2) the folder holds no transcript; (3) `--continue` answers with the wrong codeword or reports no status. Case (1) is the one Q17's start rule and template command are there to prevent; it is listed because the fallback must still work when they fail.
- **What the records must hold for the fallback:** the original task and the worktree path, kept in `org-state` ([decision 0004](../decisions/0004-records-documents-and-jsonl.md)) for as long as the task is in `work`. A launch's `first_message: {sent: false, reason}` survives a core restart in `hc get`, so a task that never reached its worker can be found and resent.
- **Caveat, several conversations in one folder:** a conversation active later in the same folder wins ("most recently written transcript", bullet above). So nothing else may run Claude Code in a worker's worktree, or `--continue` can resume that one instead of the worker's. This is a rule for the person and for the secretary, not something the core enforces.
- **Not measured:** the fallback end to end (a failed `--continue` followed by a fresh worker with the original task); and how the secretary detects a wrong resume. The probe identified the resumed conversation by a codeword it had set, and a real worker has none, so the check the secretary uses (a status, a question about the task, a git state comparison) is still to be chosen and belongs to the change that implements `org-resume` (#69).

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

**Decided (2026-11-10, owner): B.** The secretary or a worker may change the window's mods only through pull requests to paddock's own mods under `mods/org-*/`, reviewed by a person and installed after review (copied into herdr-app's `mods/` folder, [decision 0003](../decisions/0003-screen-as-app-mods.md)). No agent writes `~/.config/herdr-app` directly; the architecture already denies it ([L-N1](predecessor-inventory.md)).

- **A rejected:** the agents are the ones who see what the screen lacks, and the pull-request review keeps the trust boundary.
- **C rejected:** a scratch copy that is never reviewed either drifts or gets installed unreviewed.

**Decides.** The owner.

## Q6. How the predecessor's runtime pieces are wound down

**Question.** How are renga (the predecessor's terminal client) and claude-org-runtime (its runtime, including an adapter for the older Herdr TUI) ended?

**Decided (2026-11-11, owner, Issue #11): maintenance mode now for both, archive once paddock replaces them in daily use.**

- **renga: maintenance mode now, archive later.** Only fixes the predecessor needs to keep running; no new features. Archive it when the replacement criterion below is met. Why: paddock does not use it, and the one way it came back (Q1 option B) is closed.
- **claude-org-runtime: maintenance mode now, with its Herdr adapter stated as for the older TUI only; archive later on the same criterion.** Why: the predecessor still runs on it, and the statement stops anyone from reading the adapter as a route to herdr-core.
- **Rejected:** archiving now, because it closes both repositories to the fixes the predecessor still needs while paddock has not replaced it; keeping either piece open for new features, because paddock uses neither.
- **Replacement criterion (not measured yet):** (1) the merge rule's CI job exists and has passed and blocked one real pull request each; (2) one working week on paddock alone, with neither piece started, covering delegation, review, CI and merge, and every fallback to the predecessor logged; zero fallbacks. Both must hold before archiving.

**What we know.**

- No paddock file uses either piece: neither name appears in `scripts/`, `skills/`, `templates/`, `mods/`, `layouts/` or `tests/`. Both are on the retired list ([architecture §4](architecture.md#4-where-each-part-goes), "Retired"; [inventory](predecessor-inventory.md) RET-1, GT-9).
- Q1 is decided as option A; our own TUI is not pursued now ([decision 0003](../decisions/0003-screen-as-app-mods.md), Consequences). So renga's client side is not reused.
- The older Herdr TUI (`herdrdev/herdr`) does not share agents with herdr-core or herdr-app, so its adapter does not carry over. (App docs and the three repositories' descriptions; README, "What paddock is not")
- claude-org-ja keeps running as it is (README, "What paddock is not"), and fixes to shared ideas may be made twice until it is wound down ([decision 0001](../decisions/0001-separate-repository.md), Consequences).
- paddock has run one full loop on a host: request, worker in its own worktree, an approval answered on the screen, completion, a pull request ([prototype 2](prototype-2.md#result), 2026-11-10). That run had no CI and did not merge, and the CI job behind the merge rule is not built ([inventory](predecessor-inventory.md) L-K9, HK-15).

**Options.**

- **Maintenance mode for both.** Cost: a notice in each repository, and fixes keep being made, sometimes twice. Needs nothing new. Feasible: a text change.
- **State that the Herdr adapter is for the older TUI only.** Applies to claude-org-runtime only. Cost: one line in its documentation. Needs nothing new. Feasible: a text change.
- **Archive after paddock replaces them in daily use.** Cost: one repository setting each; an archived GitHub repository is read-only and can be unarchived (GitHub Docs, "Archiving repositories"). Needs what does not exist yet: a written replacement criterion and the acceptance CI job. Archiving now is possible but closes the repositories to the fixes the predecessor still needs.

**Not measured:** whether paddock carries the owner's daily work. The replacement criterion above is the measurement; neither of its parts has been run.

**Revisit when.** Q1 is reopened toward our own TUI (renga's client comes back into play); a user of the older Herdr TUI or of claude-org-runtime outside the predecessor turns up (none is recorded in `docs/design/`); paddock stalls (maintenance stays, no archive).

## Q7. Windows

**Question.** Is WSL2 the supported way to run paddock on Windows?

**What we know.**

- herdr-core builds exist for Windows x86_64, and on Windows templates need `sh` on PATH (for example from Git for Windows). (Core docs)
- herdr-app installs on x64 Windows. (App docs)
- Claude Code's sandbox uses bubblewrap, which is Linux-only, so a native Windows worker would run without it.
- The mod measurement ran herdr-app and hc natively on Windows. A Windows Claude Code launched there reported no status because it stopped at the folder-trust prompt. (Mod measurement)
- The core measurement ran entirely inside WSL2 and worked. (Core measurement)
- What native Windows needs (`pwsh` 7, how `hc` is found, `sh` for templates) and that paddock installs none of it: [architecture 4.1](architecture.md#41-windows).

**Options.**

- **A. WSL2 only** for core and agents; the window may be native.
- **B. Native Windows** as well, without the sandbox.

**Decided (2026-11-11, owner): A.** On Windows, core and agents run only inside WSL2; the window (herdr-app) may stay native and reach the core in WSL. Core or agents on native Windows are not supported.

- **Why:** the worker fence is Claude Code's sandbox, and the vendor says it does not run on native Windows: "The sandbox runs on macOS, Linux, and WSL2. On native Windows, Claude Code runs commands unsandboxed." (Claude Code sandbox docs). Every agent workflow of paddock that worked on a host ran with core and agents inside WSL2.
- **What the repository has today.**
  - The fence is the sandbox: [templates/worker-settings.json](../../templates/worker-settings.json) line 23 turns it on with write and read limits, and [org-delegate.sh](../../skills/org-delegate/scripts/org-delegate.sh) line 83 adds the core's socket folder to its read deny (L-N2). Measured sandbox refusals, both in WSL2: a write outside the worktree (L-K4) and a non-allowlisted host (PRM-6, Issue #44), in the [predecessor inventory](predecessor-inventory.md).
  - Host runs: core and agents in WSL2 for the Core measurement, the Inventory probes, the Continue probe, Q16 and Q18, and [prototype 2](prototype-2.md) (window on Windows, core in WSL). The only native attempt, the Mod measurement, ran hc and the window natively and its Claude Code stopped at folder trust. Two probes read `/proc` and need Linux or WSL ([idle-secretary-wake.sh](../../scripts/probes/idle-secretary-wake.sh) line 8, [org-start-secretary.sh](../../scripts/probes/org-start-secretary.sh) line 10).
  - The window: with a local core on Windows the mods reach `hc` through `pwsh` ([org-agents](../../mods/org-agents/main.js) line 17, [org-cockpit](../../mods/org-cockpit/main.js) line 36, [architecture 4.1](architecture.md#41-windows)); with the core in WSL the cockpit runs `sh` on that machine, after `hc machine add` and a `"secretary": "<machine>/secretary"` prop in the layout ([README](../../README.md) line 23).
  - Scripts: org-start is Bash only, run from Git Bash on Windows ([SKILL.md](../../skills/org-start/SKILL.md) line 14). `hc connect` drops its answer at stdin EOF on Windows only ([upstream note](upstream/hc-connect-stdin-eof.md) lines 11-12); `scripts/org` and the mods hold stdin open 1 s as a work-around. The mailbox lock ([scripts/org](../../scripts/org) lines 104-113, Issue #145) was checked with Linux coreutils only; and a shell `>>` is not guaranteed atomic natively on Windows (Q8 point 1).
- **Cost of A:** Windows users install WSL2, a distribution, and bubblewrap and socat in it (vendor docs). Measured in WSL2: the write and network refusals; the sandbox read deny and the socket deny are not measured on their own (L-K1, L-N2, L-N9).
- **B rejected:** a native worker would run every command unsandboxed (vendor docs, not tried), losing the write limit (L-K4), the sandbox read deny (L-K1, L-N9 layer 2), the socket deny (L-N2) and the network proxy (PRM-6). Left would be permission rules, which match a tool's path or a command's text, not what a program does (L-N1, L-N2). B would also need org-start and org-delegate checked under Git Bash, the folder-trust step on Windows (Q13), the mailbox lock measured on NTFS, and a fix for the `hc connect` EOF drop beyond the 1 s hold; none of it was measured.
- **Remaining work under A** (Issue #164): by default Claude Code runs commands unsandboxed when the sandbox cannot start (vendor docs), so the worker settings need `sandbox.failIfUnavailable` true (stop instead) and `allowUnsandboxedCommands` false (no retry outside the sandbox). `failIfUnavailable` is set since #164 (row L-K7 in the [predecessor inventory](predecessor-inventory.md) has the per-layer state and the probe); `allowUnsandboxedCommands` is left out pending an owner decision, because a `false` in the `--settings` file makes Claude Code ignore the worktree settings' `allowWrite` that `--allow-write` writes. Also open: a Windows setup note (WSL2, `hc machine add`, the layout prop).
- **Revisit when:** the vendor supports the sandbox on native Windows; the owner accepts unfenced workers on Windows; or target machines cannot run WSL2.

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

- **`org` server** (decided: (b); it was called the `org` MCP server): (a) a shell program speaking MCP over stdio; (b) shell commands the skills call instead of MCP tools; (c) a separate runtime, accepted as the one exception.
- **Events bridge**: (a) a shell pipeline on `hc events --json` in a kept terminal; (b) a mod, accepting gaps while no window is open; (c) part of the same program as the `org` server.
- **`state.db`** (sizes above): (a) SQLite, which needs a SQLite tool that herdr does not ship and is out of reach of a mod's own code; (b) append-only files (for example JSON lines) written from the shell or a mod; (c) core documents, reached through a JSON-RPC client, limited by the layouts in the table above; (d) a mix, for example core documents for in-progress state and JSON-lines files for the log and history.

**Decided for `state.db`** (2026-11-09): option (d), core documents for in-progress state and per-writer monthly JSON lines for history, no SQLite ([decision 0004](../decisions/0004-records-documents-and-jsonl.md)). The `org` server is decided below (shell commands, option (b)); the events bridge is still open.

**Decided for the `org` server** (2026-11-10, owner): (b), shell commands the skills call instead of MCP tools.

- **Decision:** there is no `org` MCP server. The mailbox operations `send_message`, `check_messages`, `set_summary`, `report` and `list_runs` become shell commands under one entry point, `scripts/org` (for example `scripts/org send_message <to> <text>`). Skills and agents call them through the shell.
- **Why:** the mailbox and the records are core documents and JSON lines ([decision 0004](../decisions/0004-records-documents-and-jsonl.md)), all readable and writable with `hc connect` and the shell. An MCP server would add a resident process and a JSON-RPC implementation, against [principle 1](architecture.md#2-design-principles) ("nothing to install beyond herdr"). The skills already are shell scripts (see [skills/](../../skills/)), so commands fit how the organization is already built.
- **Rejected:** (a) a shell MCP server is the same code behind a protocol nobody else calls; (c) a separate runtime breaks principle 1.
- **Consequences:** [templates/secretary.md](../../templates/secretary.md) and the [architecture](architecture.md) call these operations "`org` tools" or "the `org` MCP server"; they become commands under `scripts/org`. The architecture's section 4 row for the `org` server now says shell commands. The template text still says "tools" and "if the `org` tools are not available"; the task that implements `scripts/org` must update it (the template is not changed here, because the commands do not exist yet and the template checker runs on it). Whether `scripts/org` is one script with subcommands or several files is that task's choice.
- **Not measured:** nothing. This is a language choice, not a measured one.
- **Built** (Issue #60): one script, [`scripts/org`](../../scripts/org), with the subcommands `send_message`, `check_messages`, `set_summary`, `report`, `list_runs` and `doc get|set|update`. It needs bash, coreutils, sed and awk, and `hc` only for `doc`. Messages, run records and summaries are lines in `events/<YYYY-MM>/<id>.jsonl` under `$PADDOCK_STATE_DIR` (default `~/.local/state/paddock`); an id appends only to its own file; a reader's position is an `ack` line in its own file; readers look at this month and the last. `report start|done|blocked` writes `run_started`, `run_completed` or `run_blocked` and addresses it to the secretary in the same line. `doc` is the retry helper for the two documents of decision 0004. Tested against a stubbed `hc` (`tests/org-commands.test.sh`); the host probe is `scripts/probes/org-mailbox-restart.sh`.

## Q9. Where does the conversation language setting live?

**Question.** The rules are written in English and the language the secretary speaks with people is a setting ([architecture §2](architecture.md#2-design-principles), principle 7). Where is that setting kept, and how does it reach the agent?

**What we know.**

- A template's body is the agent's opening instructions, and core appends the task after a blank line. Templates are read fresh on each use. (Core docs)
- Unknown template header fields are ignored, so the header cannot carry the setting on its own. (Core docs)

**Options.** A line in the secretary's template body; a value in paddock's own configuration that a skill reads at start; an environment variable passed at launch; detection from the environment only, with no stored value.

**Decides.** The owner.

## Q10. Who distributes permissions, hooks and skills, and when?

**Question.** Each role needs its Claude Code settings (allow and deny rules, sandbox, hooks) and its skills. Who puts them in place, through which channel, and at what moment: once at setup, per role, or per delegation?

**What we know.**

- The predecessor generated each worker's `.claude/settings.local.json` from one schema at delegation (`claude-org-runtime settings generate`), added a `--settings` overlay at spawn for what project files cannot carry (`strictAllowlist`, credential-file denies), and kept the org roles' files with `/org-setup` and a prune tool. Its Docker image put the sandbox in managed settings instead. ([inventory](predecessor-inventory.md) PRM-1, PRM-2, RET-4)
- `hc file write` writes `AGENTS.md`, `.claude/settings.local.json` and a hook script into a new worktree, creating the missing folder; a new file gets mode 644. (Inventory probes, P1)
- A template-launched Claude Code applies a worktree's `settings.local.json` (deny rule, `PreToolUse` hook, `SessionStart` hook) and reads its `AGENTS.md`. Settings given on the template's command line (`claude --settings <file outside the worktree>`) apply the same way. Both only after the folder-trust dialog is accepted ([Q13](#q13-how-does-a-new-worktree-get-past-claude-codes-folder-trust-dialog)). (Inventory probes, P2, P5)
- `defaultMode` `auto` or `bypassPermissions` in a project settings file is ignored; the mode must come from user or managed settings or `--permission-mode`. (Claude Code docs, CHANGELOG)
- Core is "not a sandbox or a permission broker"; templates are "shell commands and opening instructions, not isolation rules"; config and templates are shared by every session in a config home. (Core docs, `docs/security.md`)
- Templates are read fresh on each use, so a change to a template's command line applies to the next launch. (Core docs, `docs/templates.md`)
- A worker needs write access outside its worktree for some records: its history file under `events/` ([decision 0004](../decisions/0004-records-documents-and-jsonl.md)) and its `knowledge/raw/` note. ([inventory](predecessor-inventory.md) L-K4)

**Options.**

- **Channel.** (a) A settings file written into each worktree at delegation; (b) one settings file per role outside the worktrees, named in the role's template command (`--settings`); (c) user settings, written once at setup; (d) managed settings; or a mix (for example (b) for the sandbox and denies, (a) for per-task paths).
- **When.** At setup by a person; at each delegation by the secretary's skill; when templates are installed.
- **Source.** Hand-written files per role, reviewed as code; or one schema rendered per role, which brings back a renderer ([Q11](#q11-what-happens-to-the-predecessors-python-gates-and-generators)).
- **Skills.** In the user's skill folder for every agent; or per role, next to the role's settings.

**Decided (2026-11-10, owner, for the channel and the moment; Source and Skills are decided below, 2026-11-11): a mix.**

- **Role settings, (b):** one settings file per role, kept outside the worktrees and named in the role's template `command` with `--settings <path>`. (Placed first next to the templates; moved to the paddock bin folder, `~/.local/share/paddock/bin` by default, which the worker may read and not write, because herdr-core lists every `*.md` in its templates folder as a template, Issue #129.) It carries the sandbox, the deny list and the hooks. It is put in place when the templates are installed (`org-start` places them).
- **Task-specific paths, (a):** a small `.claude/settings.local.json` written into the worktree at each delegation by the delegation skill, only for paths that change per task.
- **Why:** a role's rules live in one file that does not touch the target repository, so they cannot be committed by accident and are the same for every task; only paths change per task, and only those are written per worktree. `--settings` is a documented Claude Code flag (`claude --help`, Claude Code docs). It is consistent with [Q12](#q12-where-do-a-workers-role-rules-and-task-brief-live), where a role's rules also travel outside the worktree. A file outside the worktree is also what hold line L-K5 (no self-edit) relies on, since a file inside the worktree is inside the sandbox's write surface ([inventory](predecessor-inventory.md) L-K5).
- **(a) alone rejected:** it writes the whole policy into every worktree, where it can be committed, and repeats it per task.
- **(c) rejected:** user settings apply to the person's own Claude Code sessions as well as to the roles' agents.
- **(d) rejected:** managed settings need administrator placement and are per machine, not per role.
- **Consequence, `org-start`:** it copies the role settings files to the paddock bin folder (not the templates folder, Issue #129) when it installs the templates.
- **Consequence, worker template:** its `command` carries `--settings <path>` (an absolute path until a launch shows how `hc run` treats `~` and relative paths, as in Q12), together with the Q12 `--append-system-prompt-file` and the Q17 `env -u` prefix, and the permission mode ([Q12](#q12-where-do-a-workers-role-rules-and-task-brief-live), [Q17](#q17-what-environment-do-the-core-and-its-terminals-start-with)). The template does not exist yet (#62).
- **Consequence, delegation skill:** it writes the per-task settings file into the worktree after creating it and before launching the worker ([Q13](#q13-how-does-a-new-worktree-get-past-claude-codes-folder-trust-dialog)).
- **Consequence, inventory:** the rows about permissions distribution (PRM-1, PRM-2, PRM-6, SK-9, RET-1, RET-4, L-K4, L-K7) point here.
- **Not measured:** (1) that `--settings` in a template launch is honoured together with a per-worktree `settings.local.json`: P2 and P5 each used one channel, and no probe used both in one launch. **This is the probe to run**: launch a worker from a template whose `command` names a `--settings` file with a deny rule, with a worktree `settings.local.json` carrying a different deny rule, and check that both refuse their commands. (2) That a `--settings` file's sandbox applies: P5 showed its deny rule and hooks apply, and does not show its sandbox ([inventory](predecessor-inventory.md) L-K7). The same launch should run the negative checks of L-K1, L-K4, L-K5 and L-K7, so the sandbox's applying from `--settings` is settled there. (3) Which settings take precedence when the two files disagree; the Claude Code docs were not read for this here.

**Decided (2026-11-11, owner, for Source and Skills): hand-written settings per role, reviewed as code; skills per role, next to the role's settings.**

**Picks.** Both are the drafted recommendations, adopted as written. The rejected options are the schema renderer and the user skill folder.

1. **Source: hand-written files per role, reviewed as code.** Why: the repository has one role file set that matters (the worker's) and it is 42 lines; a renderer for one file costs more than the file, and it would reopen the generator question of [Q11](#q11-what-happens-to-the-predecessors-python-gates-and-generators) and the "nothing to install beyond herdr" rule (goal G4).
2. **Skills: per role, next to the role's settings, not in the user's skill folder.** Reason: the user's skill folder also serves the person's own Claude Code sessions, the same reason Q10 rejected user settings (c); and a skill with a script and a path is only reachable if its place is fixed per role.

**Revisit when.** Source: if the roles that need settings grow past three, or the allow rules must differ per task, a schema starts to pay; then decide the renderer's language in Q11 first. Skills: if the owner wants the secretary's skills to be offered in the person's own sessions too (for example a skill that tells the person how to start the organization from their login shell; `org-start` itself refuses to run inside an agent, [`skills/org-start/scripts/org-start.sh`](../../skills/org-start/scripts/org-start.sh) line 38), the user folder is the place for those.

**What is in the repository today** (each line is a file; none of it is measured beyond what Q10 already cites).

- **Worker settings** are one hand-written JSON file, [`templates/worker-settings.json`](../../templates/worker-settings.json): a deny list, a sandbox with write and read limits, no hooks yet. `org-start` copies it to the paddock bin folder ([`skills/org-start/scripts/org-start.sh`](../../skills/org-start/scripts/org-start.sh) lines 72 to 77), and the worker template's `command` names it with `--settings` ([`templates/worker.md`](../../templates/worker.md) line 3).
- **Worker rules** are one hand-written Markdown file, [`templates/worker-rules.md`](../../templates/worker-rules.md), appended with `--append-system-prompt-file` (same `command`). It is copied beside the settings file; the template checker skips `*-rules.md` ([`scripts/check-templates.sh`](../../scripts/check-templates.sh) lines 4 and 10).
- **Per-task settings** are written by the delegation skill into the worktree (`{}` or an `allowWrite` list): [`skills/org-delegate/SKILL.md`](../../skills/org-delegate/SKILL.md) step 3. This is generated by the script, but it is one JSON object, not a schema.
- **Secretary**: one template, [`templates/secretary.md`](../../templates/secretary.md), with no settings file of its own; it runs with the person's Claude Code defaults.
- **Skills** are folders `skills/<name>/SKILL.md` plus `scripts/`, in the paddock repository. No agent has them installed as Claude Code skills. The secretary is started with `--cwd <paddock folder>` and runs them as `bash skills/<name>/scripts/<name>.sh` ([`templates/secretary.md`](../../templates/secretary.md) lines 13 and 18). The worker uses none.

**Question 1, Source.**

| Option | What it costs | What it needs that does not exist |
| --- | --- | --- |
| Hand-written per role | Each role's file is edited by hand; a rule common to roles is copied. Whether the installed copy equals the repository copy is compared only in tests and a host probe ([`tests/org-start.test.sh`](../../tests/org-start.test.sh) line 80, [`scripts/probes/worker-rules-place.sh`](../../scripts/probes/worker-rules-place.sh) line 74); there is no standalone drift checker and nothing checks at launch. | Nothing for one role. A second role (curator, auditor) repeats the common deny list. |
| One schema, rendered per role | One place for common rules; the predecessor did this and needed a checker for it (inventory PRM-1, PRM-3). | A renderer and a drift checker. Their language is Q11's question; the predecessor's are Python (PRM-3), which breaks principle 1 unless Q11 accepts an exception. |

**Question 2, Skills.**

| Option | What it costs | What it needs that does not exist |
| --- | --- | --- |
| User skill folder, every agent | One install step; the skills are visible to every agent and to the person's own sessions, so a worker sees `org-delegate` and `org-pull-request`, which it must never run. | A way to hide a skill from one role (not measured). |
| Per role, next to the role's settings | A skill reaches only its role; the secretary's skills stay with the secretary. | A way to make Claude Code discover skills in a folder chosen per launch, and a fixed repository-root contract: the skill scripts find `scripts/org` and the paddock folder by walking up from their own place ([`org-delegate.sh`](../../skills/org-delegate/scripts/org-delegate.sh) lines 76 and 127, [`secretary-handover.sh`](../../skills/secretary-handover/scripts/secretary-handover.sh) line 44), so copying a skill folder alone breaks them. **Not measured**: no probe launched an agent with a skills folder named by a flag or setting, and the Claude Code docs were not read for it here. Until it is measured, the secretary keeps calling skill scripts by path as today, which needs neither option. |

**Not measured here:** whether Claude Code lists a skill from the user folder to a template-launched agent; whether it can load skills from a per-role folder; which of two settings files wins when they disagree (already open as point (3) of "Not measured" in the decided block above). The probe for the first two is a template launch with one test skill in each place, asking the agent to name its skills.

**Skills measurement comes first.** Which place Claude Code recognises for a template-launched agent is not measured, so the per-role placement cannot be built until it is. The probe: launch an agent from a template with one test skill in the per-role folder (and one in the user folder), and ask it to name its skills; also run a script-backed skill from there, since skill scripts find `scripts/org` by their own place.

## Q11. What happens to the predecessor's Python gates and generators?

**Question.** Several of the predecessor's checks are Python programs, often with SQLite: the acceptance gate and merge hook, the Codex round cap, the premise reminder, the delegation packet and brief generators, the settings renderer and drift checker, the quote-aware command splitter used by the git hooks, and the defense report. paddock is written in what herdr already brings ([architecture §2](architecture.md#2-design-principles), principle 1). What becomes of each?

**What we know.**

- Claude Code hooks run any command; a bash hook that exits 2 blocked a tool call in a template-launched worker. (Inventory probes, P2)
- Mods run only while herdr-app is open, so a mod cannot be the one party that enforces a gate. (App docs; [Q8](#q8-what-is-each-component-written-in))
- The acceptance gate's evidence is CI results; the predecessor recorded them as `ci_completed` rows written by its PR watcher. ([inventory](predecessor-inventory.md) GT-1, MON-12)
- The Codex round counter must sit where the worker cannot write, or the worker could reset it. ([inventory](predecessor-inventory.md) GT-2)
- paddock records are JSON lines and core documents, with no SQLite ([decision 0004](../decisions/0004-records-documents-and-jsonl.md)).

**Options, per tool.** (a) Rewrite in shell, reading JSON lines and core documents; (b) keep it in Python as a declared exception to principle 1; (c) drop the mechanical check and keep the rule as an instruction only; (d) leave it to the repository's CI (for example a required status check) instead of a local hook.

**Decided (2026-11-10, owner, for the acceptance gate and the head-pinning merge hook only): (d).** The check is left to the repository's CI as a required status check, not a local hook. The other tools named in the question (Codex round cap, premise reminder, generators, settings renderer and drift checker, command splitter, defense report) are not decided here and stay open; the **Decides** line below applies to them.

- **Why:** the gate's evidence is CI results already ([inventory](predecessor-inventory.md) GT-1, MON-12). CI can verify "the first commit declares the test paths, the tests are unchanged to head, CI failed on that commit and passed on head" without Python, SQLite or the GitHub CLI on the person's machine, which keeps principle 1, nothing to install beyond herdr ([architecture §2](architecture.md#2-design-principles)). The single `--match-head-commit` merge form ([inventory](predecessor-inventory.md) HK-15) is replaced by branch protection that requires the status check on the exact head.
- **Rejected:** (a) a shell rewrite keeps a local hook that can be bypassed and duplicates what CI already does; (b) keeps Python, an exception to principle 1; (c) drops the mechanical check that hold line L-K9 ("a merge needs CI on the exact head and the acceptance gate") relies on ([inventory](predecessor-inventory.md) L-K9).
- **Consequences:** the inventory rows GT-1, GT-14 and HK-15 point at CI. The CI job's design is a follow-up issue, not this record. A small local hook may be added later if a local block is wanted, as an addition and not a replacement.
- **Not measured:** no such CI job exists yet. Whether GitHub's required checks can express "failed at the first commit" is not established and needs the follow-up.

**Decides (the other tools).** The owner.

## Q12. Where do a worker's role rules and task brief live?

**Question.** A worker's rules (role instructions, prohibitions, report format) and its task brief must reach it in a target repository that is not paddock's. Where are they put?

**What we know.**

- A template body is sent as the first message, with the task appended after a blank line. (Core docs, `docs/templates.md`)
- Claude Code reads `AGENTS.md` only when the project has no CLAUDE.md. (Claude Code docs, CHANGELOG)
- A target repository may carry its own CLAUDE.md or `AGENTS.md`. The predecessor wrote its brief as `CLAUDE.local.md` when the target already had a CLAUDE.md, and kept its files out of the target's git. ([inventory](predecessor-inventory.md) INS-12)
- Claude Code has `--append-system-prompt` and `--append-system-prompt-file`, which a template's command can pass. (Claude Code docs, `claude --help` and CHANGELOG)
- A template-launched Claude read a codeword written only in the worktree's `AGENTS.md`. (Inventory probes, P2)
- Whether a rule given only in the first message is still followed after the conversation is compacted was not measured. Probe: give a rule only in a template body, run a long task, `/compact`, then ask the agent to state the rule.
- Measured on 2026-11-10 (hc 0.1.18, Claude Code 2.1.319; `scripts/probes/q12-rule-after-compact.sh`, Issue #45): **the screen checks reported a rule given only in the template body as still followed, and still stated, after `/compact`; the replies themselves were not captured, so this is weak evidence.** The template body gave a codeword (`KESTREL-7`) and a format rule (the last line of every reply is the codeword in double square brackets); no file carried it. The long task was 6 generated files of 600 lines (3600 lines, 285668 bytes) read one at a time with a summary after each, then `hc send <t> /compact`, then an unrelated arithmetic question that did not mention the rule, then "state the rule". Screen checks: the last-line format was present after the first message, after the long task and after the compaction (the screen showed a compaction), the unrelated answer after compaction had it, and the agent named the codeword and the bracket format when asked. Option (a) "template body only" held for this one rule at this task size.
- Limits of that measurement: one run, one rule pair, a context far below the window (about 3600 short lines; the run did not show how much of the window was used). The checks are `grep`s over the whole `hc read` screen, and the printed tails showed only the footer lines, so a bracket line from an earlier reply left on screen could satisfy the post-compaction check; the replies themselves were not captured. The template carried neither the Q17 `env -u` prefix nor a fresh core environment: the core had inherited `CLAUDE_CODE_CHILD_SESSION`, and Claude Code printed "Transcript saving is off" on every screen. Compaction itself ran. The script's idle wait never matched, since the status between turns is `done`, not `idle` (so each step ran to its timeout, about 55 minutes in all); the status vocabulary seen is working, done and blocked. The script and template are fixed for a rerun (wait accepts `done`, template carries the prefix); the rerun is not done.
- The predecessor's directory patterns (own clone, worktree of a shared clone, new folder) are one input: [architecture §3](architecture.md#3-roles) names only the worktree.

**Options.** (a) The template body only; (b) `AGENTS.md` written into the worktree, falling back to something else when the target has a CLAUDE.md; (c) `CLAUDE.local.md`, as the predecessor did; (d) a file outside the worktree passed with `--append-system-prompt-file` in the template command; or a split, for example role rules in (d) and the task in the template body.

**Decided (2026-11-10, owner): the split.** A worker's role rules are a file outside the target repository, passed with `--append-system-prompt-file <rules path>` in the worker template's `command` (option d). The task brief is the template body plus the task appended in the launch (option a).

- **Measured basis:** a rule given only in the template body was still followed, and still stated, after `/compact` (measured 2026-11-10, hc 0.1.18, Claude Code 2.1.319; `scripts/probes/q12-rule-after-compact.sh`, Issue #45; one run, screen-check evidence only, see "What we know" above). A template-launched Claude read a codeword written only in the worktree's `AGENTS.md` (Inventory probes, P2), so files in the worktree do reach the agent; the split does not need that.
- **Why the split:** the task travels in the launch, so nothing is typed into the worker later ([architecture §4](architecture.md#4-where-each-part-goes)). The rules file never touches the target repository's git, so it cannot collide with the target's own CLAUDE.md or `AGENTS.md` and cannot be committed by accident. There is one rules file per role, kept outside the repository (in the paddock bin folder, Issue #129), so a role's rules change in one place.
- **(a) alone rejected:** the role rules would rest on one measurement with no transcript of the replies, at a context far below the window. A rules file does not depend on that.
- **(b) rejected:** writing `AGENTS.md` into the worktree collides with a target that has its own CLAUDE.md or `AGENTS.md`, and the fallback (Claude Code reads `AGENTS.md` only when there is no CLAUDE.md) is a second path to build and keep right. The file also sits in the target's checkout, where `git add` can pick it up.
- **(c) rejected:** the predecessor's `CLAUDE.local.md` is a file written into the target checkout and kept out of the target's git by exclusion ([inventory](predecessor-inventory.md) INS-12); that exclusion is what the outside file avoids.
- **Consequence, worker template:** its `command` gains `--append-system-prompt-file <rules path>` (and keeps the Q17 `env -u` prefix, [Q17](#q17-what-environment-do-the-core-and-its-terminals-start-with)). The template does not exist yet; it is part of the delegation work (#62).
- **Consequence, delegation skill:** it writes nothing into the worktree for rules. It creates the worktree, then launches the worker with the task in the launch ([Q13](#q13-how-does-a-new-worktree-get-past-claude-codes-folder-trust-dialog)).
- **Consequence, rules file location:** outside the worktrees, one file per role (placed by `org-start` in the paddock bin folder, not the templates folder, where herdr-core would list it as a broken template, Issue #129). Its exact name and folder are left open here; they belong to the worker template (#62). Whether `hc run` leaves the path as written or expands it (for example `~`, a relative path against `--cwd`) was not measured, so the template should use an absolute path until a launch shows otherwise.
- **Not measured:** `--append-system-prompt-file` in a template launch (the flag is documented in `claude --help` and the CHANGELOG, but no probe has launched a worker with it); whether the rules survive several compactions (the probe ran one compaction); whether a target's own CLAUDE.md and the appended rules conflict in practice.

## Q13. How does a new worktree get past Claude Code's folder-trust dialog?

**Question.** Every new worktree stops a template-launched Claude Code at the folder-trust dialog, so the launch's task is not delivered. How is the folder trusted?

**What we know.**

- In each of the three probe folders, Claude Code showed "Quick safety check: Is this a project you created or one you trust?" and did not report status. `hc run` returned after about 58 s with `first_message: {sent: false, reason: "it never reported its status, so it may be showing a dialog ..."}`. With a `settings.local.json` holding an allow rule, the dialog also listed it ("This folder pre-approves 1 tool permission"). (Inventory probes, P4 to P6)
- The earlier core measurement did not see the dialog in its folders under `/tmp`; why is not known. ([architecture §8](architecture.md#8-facts-this-design-relies-on))
- `hc --skill` documents the recovery: "resolve readiness first (a trust dialog may need `hc keys <t> down enter`), then send the task". The probes did that and it worked. (Core docs; Inventory probes)
- The dialog's default choice is "No, exit": a blind Enter ends the worker. The predecessor answered it only after reading the screen, behind a hook that refused keys without a fresh screen-judgment record. ([inventory](predecessor-inventory.md) HK-8)
- A Claude Code stopped at this dialog reports no status, so herdr-app does not list it. (Mod measurement)
- Measured on 2026-11-10 (hc 0.1.18, Claude Code 2.1.319; `scripts/probes/folder-trust-worktrees.sh`, Issue #46): **trusting a parent folder covers a new subfolder created later.** In a fresh folder under `$HOME`, `hc run --bg` returned `first_message.sent: false` and `hc read` showed the dialog; `hc keys <t> down enter` reached the normal prompt (the first message was not delivered afterwards, since `hc run` tries it only at start). A new subfolder of that folder, launched from the same template after the first terminal was killed, returned `first_message: {sent: true, started: true, turn: 0}`, showed no dialog, and the agent answered the task.
- Where trust is recorded: after the dialog was accepted, `~/.claude.json` held `projects["<parent path>"].hasTrustDialogAccepted = true`. The child got its own entry with `hasTrustDialogAccepted = false`, so the dialog was skipped by looking up a trusted ancestor, not by copying the flag. This key is not a documented interface.
- Recording trust before launch: **works as of this version, but not through a supported interface.** On 2026-11-10 (Claude Code 2.1.319, hc 0.1.18) the owner wrote `projects["<folder path>"] = {"allowedTools": [], "hasTrustDialogAccepted": true}` into `~/.claude.json` for a fresh folder under `$HOME` before launch. The template launch there returned `first_message: {sent: true, started: true, turn: 0}`, `hc read` showed no dialog, and the agent answered. The key is undocumented and may change. `claude --help` mentions trust only for non-interactive mode (`-p` or stdout not a TTY), which does not fit a template launch.

**Options.** (a) The delegation skill answers the dialog with `hc keys` after `hc read` shows it, as `hc --skill` describes; (b) worktrees are created under one folder that is trusted once (measured: trust carries down, so this is available; the first folder still needs (a) or (d) once); (c) trust is recorded for the worktree before launch, if Claude Code offers a supported way (measured to work by writing the undocumented `~/.claude.json` key before launch; not a documented interface); (d) a person accepts it in the window.

**Decided (2026-11-10, owner): (b).** Worktrees are created under one parent folder per machine, which is trusted once. Every later worktree below it starts without the dialog.

- **Why:** trust carries down to subfolders created later: a new subfolder of an accepted folder returned `first_message: {sent: true, started: true, turn: 0}` and showed no dialog (measured 2026-11-10, hc 0.1.18, Claude Code 2.1.319; `scripts/probes/folder-trust-worktrees.sh`, Issue #46; see "What we know" above). It needs no key outside Claude Code's own dialog, and no screen reading per task.
- **One-time step, the parent folder:** the first launch in the parent folder stops at the dialog. Either a person accepts it in the window, option (d), or the delegation skill answers it from the screen with `hc keys <t> down enter` after `hc read` shows it, option (a). Both only for that first folder, never for a worktree. Never a blind Enter: the default choice is "No, exit" ([inventory](predecessor-inventory.md) HK-8).
- **(c) rejected:** it depends on the `projects[...].hasTrustDialogAccepted` key in `~/.claude.json`, which is not a documented interface and may change; `claude --help` offers no supported way for an interactive launch.
- **(a) and (d) for every worktree rejected:** each task would need a screen read and key presses, or a person, before the task is delivered. That is manual work per task and leaves a worker invisible in herdr-app until answered.
- **Consequence, worktree layout:** one workers folder per machine, and every task's worktree is created inside it. Its name and location are left open here; they belong to the delegation skill (#62) and the project registry ([Q14](#q14-where-do-organization-settings-and-registries-live)).- **Consequence, delegation skill:** before launching, the skill checks that the worktree's path lies under the trusted workers folder, and still checks `first_message.sent` in the `hc run` result. If it is `false` with the "never reported its status" reason, the skill reports it instead of pressing keys on a worker; the dialog is then a sign that the folder is not under the trusted parent.
- **Not measured:** that trust carries down more than one level (the probe used one subfolder level); a worktree created by `git worktree add` rather than a plain folder (the probe made plain subfolders); whether the trust lookup follows symlinks; whether Claude Code later changes the lookup. A new machine needs its own one-time step.

## Q14. Where do organization settings and registries live?

**Question.** The predecessor kept its projects registry (`registry/projects.md`) and organization settings (`registry/org-config.md`: worker folder, worker cap, base branch rules, merge approval mode) as Markdown in its repository. Where does paddock keep them?

**What we know.**

- The secretary reads Markdown without a parser; the predecessor's parser existed for its dashboard and tools. ([inventory](predecessor-inventory.md) REG-1)
- Core documents are versioned JSON up to 1 MiB, kept across restarts, reachable through `hc connect`; [decision 0004](../decisions/0004-records-documents-and-jsonl.md) lists the only allowed names. (Core docs)
- The permission mode no longer fits there: it goes in each template's command. ([inventory](predecessor-inventory.md) PRM-9)
- The conversation language setting has the same question ([Q9](#q9-where-does-the-conversation-language-setting-live)).

**Options.** (a) Markdown files in a fixed folder on the primary host, read by skills; (b) a core document (needs a new name in decision 0004); (c) lines in the secretary's template body; (d) paddock's repository, for settings that are not personal.

**Decided (2026-11-11, owner): (a), with defaults in the scripts (d).** The drafted recommendation, adopted as written. The worker folder, the worker cap, the merge approval mode and the projects registry (with each project's base branch) live in two plain files per machine, `org-config.md` and `projects.md`, in the paddock config folder: the folder `org-start` already resolves for the worker token file (`%APPDATA%` when set, else `$XDG_CONFIG_HOME`, else `~/.config`, plus `paddock`; [`org-start.sh`](../../skills/org-start/scripts/org-start.sh) lines 50, 51 and 82). The values used when a line is missing stay in the scripts, which is (d) for what is not personal. No new core document.

**Why.**

- The settings are read by shell scripts: the worker folder and the cap by `org-delegate` and `org-resume`, the approval mode by `org-pull-request`. A `key: value` line is read with one `sed`; it needs no core round trip and no parser (goal G4).
- The projects table is read by the secretary only, as Markdown, without a parser ([inventory](predecessor-inventory.md) REG-1). The secretary passes the project's path and base branch as `--project` and `--base` to both `org-delegate` and `org-pull-request`, as it passes `--project` today, so no script parses the table.
- The person never writes the format. They tell the secretary ("add this project", "merge on green CI"), and the secretary edits the file; `org-start` creates both files with the defaults when they are missing. The person can open either file to read it. A core document has no `hc` verb ([`org-pull-request.sh`](../../skills/org-pull-request/scripts/org-pull-request.sh) line 113), so under (b) only the secretary or a mod that does not exist could change it.
- These are settings, not work in progress, and [decision 0004](../decisions/0004-records-documents-and-jsonl.md) gives core documents to in-progress state.

**Rejected.**

- **(b) a core document:** no `hc` verb lets a person change it, so only the secretary or a mod that does not exist could; every script would need a core round trip; and decision 0004 keeps documents for in-progress state. Decision 0004 is not changed.
- **(c) lines in the secretary template body:** `org-start` overwrites the installed template on every run, so a lasting edit is a repository edit; and only the secretary would see the value, not the scripts.
- **(d) alone:** personal values (paths, the person's projects) would be committed. (d) keeps only the defaults, in the scripts.

**What is in the repository today.**

- Worker folder: `PADDOCK_WORKERS_DIR`, default `~/paddock-workers` ([`org-delegate.sh`](../../skills/org-delegate/scripts/org-delegate.sh) line 80). The script reads its own environment, so the variable works on one call; for it to hold for every call, it must be in the core's environment, set in the login shell that starts the core ([`org-start` SKILL.md](../../skills/org-start/SKILL.md) line 50).
- Worker cap and projects registry: none. The secretary passes `--project <path>` on every delegation ([`org-delegate` SKILL.md](../../skills/org-delegate/SKILL.md) line 34).
- Base branch: `--base`, default `main`, in both [`org-delegate.sh`](../../skills/org-delegate/scripts/org-delegate.sh) line 43 and [`org-pull-request.sh`](../../skills/org-pull-request/scripts/org-pull-request.sh) lines 41 and 78 (the PR's base). Nothing per project.
- Merge approval mode: `--mode`, else a top-level `merge_approval_mode` in `org-state`, else `human` ([`org-pull-request.sh`](../../skills/org-pull-request/scripts/org-pull-request.sh) lines 113 to 115). Its SKILL.md calls this "the smallest reading" and notes that the prototype-1 shape has no such field ([`org-pull-request` SKILL.md](../../skills/org-pull-request/SKILL.md) line 49). So one setting already sits in a state document, as a stopgap.
- Conversation language ([Q9](#q9-where-does-the-conversation-language-setting-live), open): the line `Conversation language: auto` in the secretary template body ([`templates/secretary.md`](../../templates/secretary.md) line 7), which is option (c) in use.
- Allowed document names: `org-state` and `secretary-handover` only ([`scripts/org`](../../scripts/org) lines 275 to 277).

**The options.**

| Option | How a person changes a setting | What it costs | What it needs that does not exist | Feasible? |
| --- | --- | --- | --- | --- |
| (a) Files in the paddock config folder | Tells the secretary, which edits the file; or edits it in any editor. | One read line per value in each script that uses it. The files are per machine. | The two files and their creation by `org-start`; the reader in `org-delegate`, `org-resume` and `org-pull-request`; the cap check in `org-delegate` and `org-resume` (both launch workers), counting live terminals with the `task_id` label (REG-2); the secretary's instructions for both files. | Yes on the shell side: plain files, nothing from herdr. A worker must not write them. Its sandbox allows writes only to the state folder ([`worker-settings.json`](../../templates/worker-settings.json) lines 26 to 28), but whether a `--settings` sandbox applies at all is not measured (Q10, "Not measured" point 2). **Measurement:** in that same Q10 launch, the worker tries to write `org-config.md` in the default config folder, which must be refused. |
| (b) A core document `org-config` | Tells the secretary, which runs `scripts/org doc update`. There is no `hc` verb and no mod form. | A decision 0004 row and a cap case in `scripts/org`; a core round trip in every script that reads a value; settings mixed into the in-progress store. | The row below, the `scripts/org` case, a mod form if the person is to change it on screen. | Yes: `doc.get` and `doc.set` through `hc connect` were observed (Store observation, Q8), and `scripts/org` uses them today. A mod can read it (decision 0004, Consequences). |
| (c) Lines in the secretary template body | Edits the template. But `org-start` overwrites the installed template on every run ([`org-start.sh`](../../skills/org-start/scripts/org-start.sh) line 70), so a lasting edit goes into the repository copy, which is (d). | Only the secretary sees it, from its next start; the scripts would have to parse a template. | A template reader in each script. | Partly: templates are read fresh on each use, and the body is the first message (Core docs). That a body rule survives compaction has one weak measurement (Q12). |
| (d) paddock's repository | Edits the file and opens a pull request. | The same value for everyone; personal values (paths, the person's projects) would be committed. | Nothing for the defaults: they are in the scripts today. | Yes, for values that are not personal only. |

**Note on the rejected (b).** Decision 0004 is not changed. Had (b) been picked, its table would have gained this row (not sized against a real projects list; the predecessor's `registry/projects.md` was not measured):

| Name | Writer | Holds | Cap | Pruning |
| --- | --- | --- | --- | --- |
| `org-config` | the secretary | the worker folder, the worker cap, the merge approval mode, and the projects with their base branches | 16 KiB | replaced whole on every write; a project leaves when the person drops it |

**Consequences** (for the implementing task).

- Order: argument, then `PADDOCK_*` variable, then file, then the script's default. A missing cap line means no cap, as today.
- The cap counts live terminals with the `task_id` label, whatever their status. Two launches at the same moment can both pass the count; the secretary runs launches one at a time, and that is a known limit, not a lock.
- `org-pull-request` reads the approval mode from the file instead of `org-state`.
- The worker settings gain a write deny for the config folder, as they have for the bin folder (`worker-settings.json` lines 18 and 38), and `org-delegate` refuses an `--allow-write` path inside it. Like every path in that file, the deny names the default folder only; with `APPDATA` or `XDG_CONFIG_HOME` set elsewhere it does not follow ([`org-start` SKILL.md](../../skills/org-start/SKILL.md) line 46, the same open limit).
- The conversation language may go into `org-config.md` too, so a change survives `org-start`; that is Q9's to decide.
- The permission mode is not one of these settings: it belongs in each template's command (PRM-9). The shipped templates pass none today ([`templates/worker.md`](../../templates/worker.md) line 3, [`templates/secretary.md`](../../templates/secretary.md) line 3).

**Revisit when.**

- If the screen must show or change these settings: a mod reads documents through `hc connect`; whether a mod can read a plain file was not checked here (the App docs were not read for it). Then (b), for the values the screen needs.
- If several people must share the same settings: (d) for those values.
- If the measurement above shows that a worker can write the config folder and no deny closes it, the approval mode cannot stay in a file a worker writes. (b) is the fallback only once a worker's lack of core access is measured: that row is still unverified ([inventory](predecessor-inventory.md) L-N2).

## Q15. Which of the predecessor's optional organization features carry over?

**Question.** Beyond delegation, the predecessor ran features that act on their own or report on the organization: the conveyor (an approved scope worked through without asking), work discovery with goal ledgers and an LLM judge, next-work proposals after a merge, and the metrics and defense reports. Which does paddock carry?

**What we know.**

- Work discovery runs a `claude -p` judge per scan and keeps a judge cache and a spend log; it reads goal ledgers per repository. ([inventory](predecessor-inventory.md) SK-13, ST-8, REG-3)
- The defense report counts `hook_denied` events, which were 18% of the last 30 days' rows; whether paddock keeps that event kind is open in [decision 0004](../decisions/0004-records-documents-and-jsonl.md). ([Q8](#q8-what-is-each-component-written-in), point 7)
- None of them depends on herdr. ([inventory](predecessor-inventory.md) SK-13, REC-10)

**Options.** Per feature: carry it as a skill; leave it out for now; or carry it later once its records exist.

**Decides.** The owner.

## Q16. How is the secretary's context renewed?

**Question.** A long-running secretary fills its context. The predecessor wrote a handover document, then typed `/clear` and a resume command into the secretary, by a person or by a watcher that read the transcript's token count. How does paddock renew the secretary?

**What we know.**

- `hc send` is for the first task and interrupts only ([decision 0002](../decisions/0002-org-mailbox-not-hc-send.md)); typing `/clear` into the secretary is neither.
- A template launch can carry a task, so a new secretary can be started with "resume from the handover document" as its first message; core waits for the agent's status before sending it. (Core docs, `docs/templates.md`)
- Claude Code's hook events `SessionStart` and `Stop` fire in template launches; `done` and `turn` events show when a turn has ended. (Inventory probes, P2, P3)
- After a full core stop, `claude --continue` in the same folder resumed the same session, but not when transcript saving is off ([Q17](#q17-what-environment-do-the-core-and-its-terminals-start-with)). ([architecture §8](architecture.md#8-facts-this-design-relies-on); Inventory probes, P7)

**Options.** (a) A person types `/clear` and the resume command; (b) a named exception to decision 0002 for this one control command; (c) end the secretary's terminal and launch a fresh secretary from its template with the handover as the task; (d) rely on Claude Code's own compaction and write no handover.

**Decided (2026-11-10, owner): (c).** The secretary writes a handover document, then its terminal is ended and a fresh secretary is launched from the secretary template with "resume from the handover" as the task. Nothing is typed into a running agent.

- **Why:** [decision 0002](../decisions/0002-org-mailbox-not-hc-send.md) stays intact, because the first task travels in the launch and no control command is typed. Workers survive the renewal because every worker launch carries `--outlive-parent` ([Q19](#q19-do-workers-outlive-the-secretary-that-started-them), decided (b); measured 2026-11-09). No person is needed.
- **(a) rejected:** it needs a person to type `/clear` and the resume command each time.
- **(b) rejected:** it would make `/clear` typed by software an exception to decision 0002, which exists so that nothing is typed into an agent's prompt.
- **(d) rejected:** Claude Code's compaction keeps no handover, so what the next context needs (running tasks, open approvals, decisions not yet recorded) is lost.
- **Consequence, handover document:** the secretary writes it before its terminal is ended, and only the secretary writes it. Its place is a fixed-name document in herdr-core's document store ([decision 0004](../decisions/0004-records-documents-and-jsonl.md)), proposed name `secretary-handover`. That name is not in decision 0004's table yet, and a new name is added there with its writer, cap and pruning rule, so the name, cap and pruning are still open and belong to the change that implements this (#70). Its content is not specified here; `org-state` already holds the work and approvals, so the handover needs only what `org-state` lacks.
- **Consequence, relaunch:** `hc run --bg --keep --name secretary secretary "<resume from handover>"`. The task is in the launch ([templates](../../templates/secretary.md) `command` already clears the session-bound variables, [Q17](#q17-what-environment-do-the-core-and-its-terminals-start-with)). Check `first_message.sent` in the result, as for workers.
- **Consequence, order:** the old terminal must be killed (`hc kill`) and removed (`hc rm`) first, because the name `secretary` is reused. Whether `hc run` rejects a name still held by a finished terminal was not measured here. The new secretary then finds the running workers by their `task_id` label ([Q19](#q19-do-workers-outlive-the-secretary-that-started-them)).
- **Measured 2026-11-10 (`scripts/probes/secretary-renewal.sh`, Issue #116):** a real secretary (Claude Code 2.1.321, hc 0.1.18, WSL2) started the worker `p116-w` (`sleep`, `--outlive-parent`, label `task_id=p116-w`) and wrote `secretary-handover` about 16 s after its launch; it was `done` (between turns) when `secretary-handover.sh` ran, and the script exited 0 (`doc.get` read as the script assumes; `hc kill`, `hc rm`, `hc run` accepted); the name `secretary` then held a different terminal (`created_ms` changed, `first_message.sent` true); the new secretary set the document to `null` about 24 s later, so it read it and followed the task; `p116-w` stayed the same terminal, still running, with its label, and the new secretary reached `done`. Not measured: the layout (no herdr-app was attached to the probe's core, so the re-adoption of the new secretary by its labels was not seen, and the new secretary's labels were empty as expected without an app); what the new secretary said (the forwarded screen tail was an empty prompt, so the probe's "worker named on screen" line passed but was not read by eye); whether `hc run` rejects a name still held by a finished terminal (the script removes it first, and that succeeded); permission prompts (none were reported to the probe, which does not record them); and idle detection beyond `hc get` status ([Q18](#q18-how-does-anything-reach-an-idle-agent)).
- **The predecessor's flow is not paddock's:** the automatic watcher that typed `/clear` at a token threshold is not carried over ([inventory](predecessor-inventory.md) HND-2, HK-13, ST-4, PRM-8). When to renew is left to the secretary skill (#70).

## Q17. What environment do the core and its terminals start with?

**Question.** Programs in hc terminals get the environment of whatever started the core. Who starts the core, and with what environment?

**What we know.**

- A core started by a script under a Claude Code session passed all 15 of that session's `CLAUDE*` variables to a program in an hc terminal, including `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_MESSAGING_SOCKET` and `CLAUDE_CODE_MESSAGING_TOKEN`. Every Claude Code launched there showed "Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker", and no session log was written. (Inventory probes, P7)
- "The CLI starts a background core when it needs one", so the first `hc` command run decides the environment. (Core docs, `docs/security.md`)
- `terminal.run` takes an `env` parameter; the `hc run` CLI has no `--env` option. A template's `command` runs through `sh`, so it can set or remove variables before starting the agent. (Core docs, `hc.openrpc.json`, `docs/commands.md`, `docs/templates.md`)
- Without transcripts, `claude --continue` cannot resume a session ([Q4](#q4-worker-recovery-after-a-core-restart), [Q16](#q16-how-is-the-secretarys-context-renewed)).
- `terminal.run`'s `env` cannot remove an inherited variable. It adds and overrides: `{"HOME":"x"}` gave `HOME=x`, and a new name appeared. An empty string leaves the variable set to empty (`HOME=` and `CLAUDE_CODE_CHILD_SESSION=` in `env` output, not absent). `null` is rejected with `invalid_params` ("invalid type: null, expected a string"), because the schema types `env` values as strings. The core's own environment held `CLAUDE_CODE_CHILD_SESSION=1`, and a launch without `env` inherited it. (Env probe, 2026-11-09)
- Not measured: whether Claude Code treats an empty `CLAUDE_CODE_CHILD_SESSION` as unset, so that transcripts stay on. If it does, option (c) works with `"CLAUDE_CODE_CHILD_SESSION": ""`. One launch of `claude` with that `env` and a check for the "Transcript saving is off" notice would settle it.

**Options.** (a) The core is started only from a login shell or a service, never from inside an agent; (b) each template's command clears the variables it must not inherit (for example `env -u CLAUDE_CODE_CHILD_SESSION ... claude`); (c) every launch passes an explicit environment (it can add and override but not remove a variable, so it clears `CLAUDE_CODE_CHILD_SESSION` only if an empty value counts as unset); (d) a mix.

**Decided (2026-11-10, owner): (d) = (a) + (b).**

- **Start rule (a):** the core is started only from the person's login shell or a service, never from inside an agent, so no agent's `CLAUDE*` variables become the core's environment.
- **Template command (b):** as a second line, each template's `command` clears the session-bound variables it must not inherit before launching `claude`, for example `env -u CLAUDE_CODE_CHILD_SESSION ... claude`. The names known from [P7](predecessor-inventory.md) are `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_MESSAGING_SOCKET` and `CLAUDE_CODE_MESSAGING_TOKEN`; P7 counted 15 `CLAUDE*` variables but named only these four, so each template's list must be extended to the rest of the session-bound ones. [templates/secretary.md](../../templates/secretary.md) carries the prefix now; every other template must carry it too.
- **(c) alone rejected:** `terminal.run`'s `env` cannot remove an inherited variable (empty string sets it to empty, `null` is rejected; measured 2026-11-10, see above).
- **Consequence for `org-start`:** the rewritten skill starts no core itself. It should refuse to run if the core it finds was started from an agent. Whether that is detectable is not established: no probe has read the core's own environment or recorded who started it. Until one does, the rule is enforced by the start rule and (b) only.

## Q18. How does anything reach an idle agent?

**Question.** An agent reads its mailbox on its own turn ([decision 0002](../decisions/0002-org-mailbox-not-hc-send.md)). When the secretary is idle, or a worker has just been interrupted, what starts its next turn: a worker's report, a CI result, a Codex-cap denial, the secretary's redirecting instruction?

**What we know.**

- `events.subscribe` sends a snapshot, then changes in order; changes made while no subscriber was connected are not replayed. (Core docs, `hc.openrpc.json`)
- hc types notes into a parent when a child is blocked, errs or exits, and `hc wait` ends when a message arrives for the caller; `notes = false` turns the notes off. Those notes are typed into the parent's prompt, which [decision 0002](../decisions/0002-org-mailbox-not-hc-send.md) otherwise avoids. (Core docs, `hc --skill`, `docs/commands.md`)
- A Codex-cap denial comes from a hook inside a worker; no terminal exits, so no hc note is made. ([inventory](predecessor-inventory.md) REC-4)
- After `hc interrupt` the worker is idle; a mailbox message alone does not start its next turn. ([inventory](predecessor-inventory.md) SK-4)
- The predecessor relayed such events through its dispatcher's loop with an exactly-once delivery ledger, because a direct push could fail silently and leave the secretary idle. ([inventory](predecessor-inventory.md) REC-4)
- The architecture's events bridge follows `hc events --json` in a kept terminal; whether it also wakes agents is not defined. ([architecture §4](architecture.md#4-where-each-part-goes))

**Options.** (a) hc's own notes wake the parent ([Q2](#q2-how-much-of-a-childs-reporting-goes-through-the-mailbox) option C); (b) the `org` server or the events bridge sends a short wake-up with `hc send --if idle` to an idle agent, as a named exception to decision 0002; (c) the secretary never goes idle while work is in progress, waiting with `hc wait --children` and checking the mailbox each time it returns; (d) a person is notified and starts the turn.

**Decided (2026-11-10, owner): (c).** The secretary never goes idle while work is in progress. It waits with `hc wait` (`--children`, or the named child terminals it started) and checks the mailbox each time the wait returns. Nothing is typed into an agent.

- **Measured basis:** MON-12, measured 2026-11-10 (hc 0.1.18, [probe](../../scripts/probes/ci-watch-child.sh), Issue #55): `hc wait <name>` blocks until the child ends and prints one JSON line with the exit code, from a plain shell and from a parent launched from a template, and with `--no-notify` nothing was typed into the parent. ([inventory](predecessor-inventory.md) MON-12) `hc wait --children` needs to run inside a terminal or name the parent: from a plain shell it exited 7 at once with `needs_target` ("run it inside a terminal, or name the parent"). Neither form was measured from inside a Claude terminal. ([inventory](predecessor-inventory.md) MON-12, REC-4)
- **Why:** [decision 0002](../decisions/0002-org-mailbox-not-hc-send.md) stays intact, because the wake-up is the secretary's own wait returning, not text typed into its prompt. It does not depend on hc's notes being typed into the parent (they are off, [Q2](#q2-how-much-of-a-childs-reporting-goes-through-the-mailbox)). An event that is not a child, such as a CI result, becomes a child by being watched through a child terminal, the method of the pull-request skill ([MON-12](predecessor-inventory.md)). A worker's report arrives in the mailbox and is read on the next return.
- **(a) rejected:** it relies on hc typing notes into the parent's prompt, which decision 0002 avoids.
- **(b) rejected:** it is a named exception to decision 0002, which exists so that nothing is typed into an agent's prompt.
- **(d) rejected:** it makes a person the wake mechanism, for events the secretary can wait for itself.
- **Consequence, secretary template:** [templates/secretary.md](../../templates/secretary.md) gets a waiting rule: while any task is in progress, wait on children and read the mailbox on each return.
- **Consequence, worker after interrupt:** a worker that is interrupted and idle is woken by the secretary launching its next instruction as a new child, or by the resume path of [Q4](#q4-worker-recovery-after-a-core-restart). A mailbox message alone does not start it ([SK-4](predecessor-inventory.md)).
- **Consequence, events bridge:** the events bridge ([architecture §4](architecture.md#4-where-each-part-goes)) records events and does not wake agents.
- **Consequence, Codex-cap denial:** it makes no hc note ([REC-4](predecessor-inventory.md)), so no wait returns for it; it reaches the secretary only as a mailbox message, read on the next return.
- **Measured 2026-11-10 (`scripts/probes/hc-wait-in-claude.sh`, Issue #117; hc 0.1.18, Claude Code 2.1.322, WSL2):** a template-launched secretary in auto mode (no prompts) held `hc wait` inside one Bash tool call, with a child that runs 240 s and exits 5. (A) `hc wait --children any` with no `--timeout` checked in by itself after 180 s: `reason: "timeout"`, the child still `running`, wait exit status 0; the call came back normally. (A2) `hc wait --children any --timeout 300`, started on the same child after A's check-in (so the call itself held about 55 s), returned 235 s after the child started, when it ended: `reason: "children"`, the child's `exit_code` 5, `ended: true`, wait exit status 0. (B) `hc wait <name> --timeout 300` held 234 s and returned `reason: "exit"`, `exit_code` 5, wait exit status 0. So `--children any` works from inside a template-launched Claude terminal, and the harness did not interrupt a call held for 234 s (B, a fresh child; the longest single call measured). In all three the text the agent said the Bash tool showed equals the wait's JSON line. The wait's exit status is 0 in every case, including when the child exited 5: the child's code is only in the JSON (`exit_code`), so the secretary must read the JSON, not `$?`. The JSON names a child by terminal address (`t2`), not by name, so the secretary maps it to the worker itself. Not measured: holds longer than 234 s (the harness limit is not found, only that 234 s is allowed), and the waiting loop over a long session.
- **Refined 2026-11-10 (Issue #140): the wait also returns on mail.** Seen on a host (hc 0.1.18, Claude Code 2.1.322): the card put `ANSWER <approval id> yes` in the secretary's mailbox while the secretary sat idle at its prompt, and it was handled only when a person typed into the secretary. `hc wait` returns on a child ending or its own check-in, never on a mailbox message, so even a waiting secretary would see a card answer up to 180 s late. Decision (c) stands; its waiting command is now `org wait --children` ([`scripts/org`](../../scripts/org)): it returns `{"reason":"mail","unread":N}` as soon as the caller has unread mail (it polls every 2 s and marks nothing read), `{"reason":"timeout"}` after `--timeout` (default 60 s, chosen by the owner on 2026-11-10, well under the measured 234 s hold; `PADDOCK_WAIT_TIMEOUT` changes it), and with `--children` passes through `hc wait --children any`'s line when a child ends (any other ending of that hc wait, such as no children for a renewed secretary, is ignored, so the wait does not spin). "Work in progress" is now checkable: `org-state` has a `work` or `approvals` entry. The [secretary template](../../templates/secretary.md) ends every such turn in that one Bash call, except right after it has written its handover (the handover script refuses a working secretary). Options rejected again for this case: a watcher that types a wake-up line with `hc send --if idle` when the unread count rises ((b) above: an exception to [decision 0002](../decisions/0002-org-mailbox-not-hc-send.md), it joins a person's half-typed input, and it needs a resident process paddock does not have); a rule that the person nudges the secretary ((d) above: it is the failure that was seen). Costs: while waiting, one short turn per check-in (about 60 an hour at 60 s); a card answer is seen within the poll interval plus the secretary's own turn; a line a person types into a waiting secretary is read when the wait returns, at most the timeout, unless they press Esc. Not covered: an answer that arrives while the secretary is inside another blocking call, such as `org-pull-request`'s own `hc wait` on CI, waits for that call. Host check: [`scripts/probes/idle-secretary-wake.sh`](../../scripts/probes/idle-secretary-wake.sh), run 2026-11-10 (hc 0.1.18, Claude Code 2.1.322, wait timeout 60 s): the secretary entered `org wait` from the template alone 50 s after its start and waited again after a check-in; the stand-in worker had the answer 16 s after the card-style `ANSWER` message, with nothing typed; the approval was removed; a line typed with `hc send` while it waited was acted on after 65 s. A secretary started from a folder whose Claude Code settings sandbox its Bash could not reach the core, so its `org` calls failed: start it from the paddock folder as `org-start` does.

## Q19. Do workers outlive the secretary that started them?

**Question.** Workers launched by the secretary are its children. Should they end with it, or be started with `--outlive-parent`?

**What we know.**

- "Terminals you start are your children. They end when you end, unless started with `--outlive-parent`." The parent is set at launch; no method changes it later. (Core docs, `hc --skill`, `hc.openrpc.json` `terminal.run`)
- A parent gets notes when a child needs attention or ends, and `hc wait --children` waits for its own children only. (Core docs)
- Renewing the secretary by ending its program ([Q16](#q16-how-is-the-secretarys-context-renewed) option c), or a crash, would end every worker it started.
- Measured 2026-11-09 (hc 0.1.18, `scripts/probes/outlive-parent.sh`): a secretary started from a template (its program a stand-in shell script, not Claude Code) started two workers inside its terminal, one with `--outlive-parent` and one without. `hc get --json` showed `parent` set to the secretary for both, and `die_with_parent: false` for the first and `true` for the second. After `hc kill` of the secretary (exit 0), `hc ls` 3 s later listed only the first worker, still `live` and `working`. The second had `state: finished`, `reason: "killed"`, with a `finished_ms` in the same second as the secretary's kill. So workers started with `--outlive-parent` survive the secretary's kill and workers started without it do not, as the Core docs say.
- Not measured: whether child notes for the surviving worker reach a new secretary (it is not that worker's parent), and whether a new secretary can follow it by its `task_id` label and events alone.
- Not measured: whether workers started with `--outlive-parent` appear in herdr-app's Agents sidebar (prototype 1 saw `--no-parent` demo terminals missing from it, [prototype 1](prototype-1.md)). The probe was run twice more on 2026-11-09 with the 30 s pause for looking at the sidebar, with the same `hc` results (with `--outlive-parent`: survived; without: gone). But herdr-app was connected to a different core (the Windows-side herdr-core 0.1.19) from the one the probe ran on (the WSL core, 0.1.18), so the sidebar showed none of the probe's terminals and says nothing about the question. It could not be fixed in the task: the Windows core's `hc machine add --via` runs the given command through `sh`, which Windows lacks, so every `--via wsl.exe ...` form is rejected as "bad command"; registering by ssh needs an sshd in WSL, which is not installed. To settle it: install an sshd in WSL so the Windows core can add it as a machine (then also check whether the Agents sidebar lists a remote machine's agents), or run a probe variant on the Windows core.

**Options.** (a) Workers end with the secretary (simple; renewal must keep the same program); (b) workers outlive it, and a new secretary finds them by their `task_id` label and follows them through events instead of child notes; (c) a long-lived parent other than the secretary (for example the events bridge's terminal) starts workers on the secretary's behalf.

**Decided (2026-11-10, owner): (b).** Workers are started with `--outlive-parent`. A new secretary finds them by their `task_id` label (`hc ls`, `hc get`) and follows them through the `org` mailbox and events, not through herdr-core's child notes (notes are off, [Q2](#q2-how-much-of-a-childs-reporting-goes-through-the-mailbox)). `hc wait --children` still returns a child's exit and code while the same secretary is alive ([REC-4](predecessor-inventory.md), measured 2026-11-09).

- **(a) rejected:** a secretary renewal ([Q16](#q16-how-is-the-secretarys-context-renewed)) or a crash would kill work in progress.
- **(c) rejected:** a long-lived proxy parent adds a component for a benefit (b) already gives.
- **Consequence:** the secretary template's worker launch must pass `--outlive-parent` and set the `task_id` label. `templates/secretary.md` now says so in one line.

## Q20. How is a worker's GitHub access held to read-only?

**Question.** Hold line L-K2 says only the secretary pushes and writes to GitHub. A worker's environment carries no GitHub variable, yet its `gh` authenticates through the config file under the person's home. How is that path closed without also cutting the worker's `git fetch` and `git pull`? (Issue #99; Refs #34, #41)

**What we know.**

- Measured 2026-11-10 (hc 0.1.18, Claude Code 2.1.319, `scripts/probes/worker-env-audit.sh`): none of `GH_TOKEN`, `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN`, `GITHUB_ENTERPRISE_TOKEN` and `GH_CONFIG_DIR` was in the control, parent or shell-child terminal, yet `gh auth status` succeeded in all of them, because `gh` read its login from the config file under the person's home. (Inventory, [L-K2](predecessor-inventory.md))
- `gh` resolves its config directory from `GH_CONFIG_DIR`, else `XDG_CONFIG_HOME/gh`, else `~/.config/gh`. (gh docs, `gh help environment`)
- Each template's `command` runs through `sh` and already carries an `env -u ...` prefix, so a template can also set a variable before launching `claude`. ([Q17](#q17-what-environment-do-the-core-and-its-terminals-start-with) decision (b))
- The predecessor denied the file with a Claude Code sandbox credential rule (`~/.config/gh/hosts.yml`, mode deny) in the worker settings. That stops the agent's own tools but not a program the agent starts outside the sandbox. (claude-org-ja worker settings; inventory HK-3)
- Measured in practice, 2026-11-10 (the conveyor run, no probe script): with a worker's GitHub access cut by its environment alone, every worker's `git fetch` of a private repository failed. (Owner's report; the run's output was not kept in the repository.)

**Options.** (a) The worker template's command sets `GH_CONFIG_DIR` to an empty directory, so `gh` finds no credentials. (b) Keep the deny rules only (HK-3) and record that the config-file path stays open. (c) Both: (a) in the template and the deny rule in settings. (d) (a) plus a read-only token, so fetch still works.

**Decided (2026-11-10, owner): (d).** Each worker launch gets `GH_CONFIG_DIR` pointed at an empty directory (so `gh` never reads the person's `hosts.yml`) and `GH_TOKEN` set to a fine-grained GitHub token with `contents:read` only, for just the repositories that worker may fetch. Git keeps using `gh` as its credential helper, so fetch and pull work, while push, PR creation and every other write are refused by GitHub itself. The line is held by the platform, not by a rule the agent could bypass.

- **Why:** an empty `GH_CONFIG_DIR` alone would also cut `git fetch` and `git pull` of a private repository (measured in practice, above). The deny rules stop the agent's own tool calls but not programs it starts. With a read-only token, a refused write is GitHub's decision, whatever program makes it.
- **(a) alone rejected:** it cuts fetch and pull of private repositories, which the conveyor showed is unworkable.
- **(b) and (c) rejected as the holder:** deny rules alone can be bypassed by a started program. The deny rule may stay in settings as a second line; it is no longer what holds L-K2.
- **Secretary fetching on behalf of workers, rejected:** manual toil for every fetch and pull.
- **Consequence, worker template:** its `command` carries `GH_CONFIG_DIR=<empty dir> GH_TOKEN=<read-only token>` (after the Q17 `env -u` prefix, before `claude`). No worker template exists yet; it will be written under #62, with the role-rules path from [Q12](#q12-where-do-a-workers-role-rules-and-task-brief-live). [templates/secretary.md](../../templates/secretary.md) says in one line that the worker template carries the two variables.
- **Consequence, the token value:** it is the owner's secret and is never in this repository. The template reads it from an environment variable the person sets in the login shell that starts the core ([Q17](#q17-what-environment-do-the-core-and-its-terminals-start-with) start rule), or from a file path outside the repository; the template names which. The variable must not be named `GH_TOKEN` in the core's environment: the secretary also inherits the core's environment, and it must keep write access, so the worker template maps a differently named variable onto `GH_TOKEN` for the worker only. The name and the empty directory (a fixed one, or a per-launch temporary folder) are left to the worker template.
- **Consequence, inventory:** the L-K2 row's "Open (gh config file)" becomes "Decided; not measured" until the probe below runs. The L-N4 row points here for its GitHub half.
- **Not measured:** the probe. In a worker terminal started from the template, `gh auth status` reports the token login (and not the person's), `git fetch` of an allowed private repository succeeds, and a `git push` fails with the token (refused by GitHub). Also not measured: that git's credential helper, configured as `gh`, picks up `GH_TOKEN` and the empty `GH_CONFIG_DIR` in the worker's terminal, and the same check in the Claude child (see L-N4).
- **Known limit:** the token holds the line only while the person's own login is out of reach. A program a worker starts can unset `GH_TOKEN` and `GH_CONFIG_DIR`; `gh` then reads the person's config file under the home again and GitHub authorizes writes with that login. The deny rule on that file (HK-3) stays as the second line against the agent's own tools, but nothing here makes the file unreadable to a started program. Closing that needs a boundary outside the environment (a separate home or account for workers); it is not decided here. The probe should also run with both variables unset and record what `gh auth status` and a push then do. (Codex review, P2.)
- **Open question (scope list):** does `gh run watch` work with `contents:read`, or does it need `actions:read`? The worker would use it to watch its own CI. The needed scope list (`contents:read`, plus perhaps `actions:read` and `metadata:read`) is not established; a probe of `gh run watch` with a token holding only `contents:read` would settle it. Until then the decision grants `contents:read` only.
