# Architecture

Status: draft. This document fixes where each part of the organization lives. Undecided points are listed in [open questions](open-questions.md) and are not settled here.

## 1. The idea in one paragraph

paddock keeps the predecessor's three ideas: you talk to a secretary, the organization grows through skills, and it keeps its own records. It changes everything below them. herdr-core runs the terminals and holds each agent's self-reported status. An organization layer (role templates, skills, a mailbox, a record store) sits on top and does not care which window shows it. The window is herdr-app with paddock's mods, or a client of our own; both read the same organization layer.

## 2. Design principles

1. **Write it in what herdr already runs.** Implementation leans on the environments herdr provides: herdr-app mods (JavaScript), `hc` templates and the `hc` CLI, and the shell. paddock avoids languages and runtimes that need a separate install. The components stay as designed; what each one is written in is listed in [section 5](#5-components-and-what-they-are-written-in) and left open in [Q8](open-questions.md#q8-what-is-each-component-written-in).
2. **Three channels, never mixed.**
   - **Status**: each agent reports `working` / `blocked` / `done` / `error` through OSC 7501; herdr-core stores it. Nothing infers status from screen text.
   - **Messages**: agents talk to each other through the organization's mailbox (the `org` MCP tools), stored in `state.db`. Messages are queued and read asynchronously.
   - **Signals**: the window's notifications tell a person or the secretary that something is waiting. The secretary checks its mailbox at the end of each turn.

   The full transcript of each conversation stays where Claude Code writes it (its JSONL session logs). paddock does not copy it.
3. **`hc send` is for the first task and for interrupts only.** No agent types into another agent's prompt to talk to it ([decision 0002](../decisions/0002-org-mailbox-not-hc-send.md)). In practice the first task goes in `hc run` itself, as herdr-core recommends.
4. **Status is what the program says.** A terminal that has not reported has no status. herdr-core and herdr-app both follow this rule; paddock does too.
5. **The organization does not depend on the window.** Templates, skills, the `org` tools and `state.db` are the same whether the window is a herdr-app mod or our own client.
6. **People are interrupted by escalation, not by `blocked`.** A blocked worker goes to the secretary first. A person is notified when the secretary escalates, or when the secretary itself is not moving (an incident).
7. **Rules are English; the conversation language is a setting.** Role instructions (template bodies), `AGENTS.md` (Claude Code reads it when there is no CLAUDE.md), skills and contract documents are written in English. The language the secretary uses with people is a setting value, defaulting to the environment's, and the instructions tell the agent to follow it. Where the setting lives is [Q9](open-questions.md#q9-where-does-the-conversation-language-setting-live).
8. **`AGENTS.md` is the shared instruction file, not CLAUDE.md.** Instructions meant for every agent go in `AGENTS.md`. Claude Code reads `AGENTS.md` in a project that has no CLAUDE.md, and other agents read the same file, so one file serves them all. paddock does not ship a CLAUDE.md beside it, because by default Claude Code would then read the CLAUDE.md instead.

## 3. Roles

| Role | What it does | How it runs |
| --- | --- | --- |
| Secretary | The one agent you talk to. Delegates tasks, answers workers, escalates what it cannot decide. Also takes over the predecessor's dispatcher duties (see below). | A herdr-core template, started once and kept. |
| Worker | Does one task in its own git worktree and reports back. | A template, started per task with `hc run --bg`. |
| Curator | Turns raw notes into curated knowledge. | A template the secretary starts when a threshold is reached. |

**No dispatcher.** In the predecessor, the dispatcher's job was to open panes, launch workers, type their instructions and watch their screens. `hc run --bg` does the first three in one line that returns at once, and OSC 7501 status replaces screen watching. The secretary does what remains.

## 4. Where each part goes

The full list of what the predecessor distributes, enforces and records, with a verdict for each, is the [predecessor inventory](predecessor-inventory.md).

| Part of the predecessor | In paddock |
| --- | --- |
| Role contracts (each role's CLAUDE.md) | herdr-core templates (`~/.config/herdr-core/templates/<name>.md`: header with `command`, body with the role's instructions) plus the worktree's `AGENTS.md` ([principle 8](#2-design-principles)). `hc run <template> "<task>"` starts a role by name. |
| Delegation (create a worktree, open a pane, send the instruction) | A delegation skill creates the worktree, then runs `hc run --bg --name w-<task> --cwd <worktree> --label task_id=<task> worker "<task>"`. The task travels in the launch, not in a later send. In a new worktree it is not delivered until Claude Code's folder-trust dialog is answered ([Q13](open-questions.md#q13-how-does-a-new-worktree-get-past-claude-codes-folder-trust-dialog)). |
| Peer messaging (`send_message`, `check_messages`, `set_summary`) | The `org` MCP server: `send_message`, `check_messages`, `set_summary`, `report`, `list_runs`. The mailbox is the messages record in `state.db`. |
| Monitoring (screen hashes, spinner detection, the dispatcher's polling loop) | OSC 7501 status held by herdr-core. A small non-LLM bridge follows `hc events --json` and writes runs and events into `state.db`; it runs as a kept herdr-core terminal (`hc run --bg --keep`). |
| Attention watcher, cockpit, dashboard | herdr-app mods, started by duplicating the shipped `agents` mod ([decision 0003](../decisions/0003-screen-as-app-mods.md)). |
| `state.db` (runs, events) | The records are kept and a record of messages is added. In-progress state goes in fixed-name core documents and history in per-writer monthly JSON lines, with no SQLite ([decision 0004](../decisions/0004-records-documents-and-jsonl.md)). |
| Permissions, hooks, sandbox | Kept as Claude Code settings. Writes to `~/.config/herdr-core` and `~/.config/herdr-app` are added to the worker deny list, because templates and mods there are trusted code. Which lines are kept is in the [inventory](predecessor-inventory.md#6-lines-the-predecessor-held-and-lines-paddock-must-hold); who distributes the settings, and when, is [Q10](open-questions.md#q10-who-distributes-permissions-hooks-and-skills-and-when). |
| Suspend and resume | herdr-core keeps terminals alive while no window is open. After a full core stop, kept terminals return as plain shells, so bringing the secretary back (`claude --continue`) is a skill's job. That needs Claude Code's transcripts, which are off when the core inherits `CLAUDE_CODE_CHILD_SESSION` from the process that started it ([Q17](open-questions.md#q17-what-environment-do-the-core-and-its-terminals-start-with)). Worker recovery: [Q4](open-questions.md#q4-worker-recovery-after-a-core-restart). |
| Other machines | `hc machine add`, then `hc run --on <machine>`. Remote terminals join the same list and event stream. |
| Retired | Both transport stacks and their terminal adapters (tmux, WezTerm, the older Herdr TUI), the dispatcher runner, the separate dashboard, container setup, pane layout files, and the runtime version pin. |

<a id="components"></a>

## 5. Components and what they are written in

Most of the organization is herdr itself: role launch (templates), task identity (labels), status (OSC 7501 through `hc get` / `hc events`), waiting (`hc wait --children`), interrupts (`hc interrupt`), remote machines (`hc machine`, `--on`), and the window (mods with `exec`, file reads and writes, `notify`, shared state). Skills are Markdown that Claude Code reads.

paddock adds the components below. Each must be written in an environment herdr already brings (a mod's JavaScript, `hc` templates and CLI, the shell) unless that proves impossible. Which one each uses is [Q8](open-questions.md#q8-what-is-each-component-written-in).

| Component | What it must do | Written in |
| --- | --- | --- |
| `org` MCP server | Give every agent the mailbox tools (`send_message`, `check_messages`, `set_summary`, `report`, `list_runs`) and run whether or not a window is open. | Open (Q8) |
| Events bridge | Follow `hc events --json` and append runs and events to `state.db`, as a kept herdr-core terminal. | Open (Q8) |
| `state.db` | Hold runs, events and messages durably. The name is kept for the record store whatever its format. | Core documents and JSON-lines files ([decision 0004](../decisions/0004-records-documents-and-jsonl.md)), reached through `hc connect` and the shell |
| Window | Draw the screen in [section 7](#7-the-screen). | herdr-app mods (JavaScript) ([decision 0003](../decisions/0003-screen-as-app-mods.md)) |

## 6. Flows

### 6.1 Delegate a task

1. You tell the secretary what you want.
2. The secretary's delegation skill creates a worktree and launches a worker from the `worker` template with `hc run --bg`, putting the task in the launch and `task_id` in a label.
3. herdr-core waits for the worker's first status report before sending the opening message, and reports whether it was sent. In a new worktree the report does not come until Claude Code's folder-trust dialog is answered, so the message is not sent ([Q13](open-questions.md#q13-how-does-a-new-worktree-get-past-claude-codes-folder-trust-dialog)).
4. The worker works. Its status flows through OSC 7501 into herdr-core, and from there to the window and the events bridge.
5. The worker reports with the `org` tool `report` (or `send_message`). The secretary reads it at the end of its turn with `check_messages`.

### 6.2 A worker is stuck

Same order as the predecessor:

1. The worker goes `blocked` (for example `kind: permission`). The secretary sees it first and answers what it can.
2. What the secretary cannot decide goes to a person through an escalation skill. The escalation, not the `blocked` status, makes the notification.
3. If the secretary itself does not move, that is an incident and a person is notified after a threshold ([Q3](open-questions.md#q3-incident-threshold-when-the-secretary-does-not-move)).

### 6.3 After a core restart

- `hc server restart` (for example after an update) keeps programs running.
- `hc server stop` then `start` ends the programs. Terminals started with `--keep` come back as shells in their last folder. The conversation is still in Claude Code's logs, so a skill restarts the secretary with `claude --continue`. How workers come back is [Q4](open-questions.md#q4-worker-recovery-after-a-core-restart).

## 7. The screen

The screen is not an admin console. It is drawn by herdr-app mods ([decision 0003](../decisions/0003-screen-as-app-mods.md)) and follows these rules:

- Dark theme. No borders.
- **Left**: one tile per worker, a live view of its terminal showing its last one or two lines and a status color.
- **Center**: the secretary, large.
- Only the secretary's questions to you float above the window.
- A pending approval shows as a single card in the bottom right.
- No tables. No charts.

### 7.1 Approvals

When a worker blocks on a permission prompt or dialog, nobody types the answer for the person ([L-N3](predecessor-inventory.md)):

1. The worker's terminal reports `blocked`; the secretary sees it and adds an `org-state.approvals` entry (`task_id`, `question`, `asked_at`).
2. The mod shows the entry as a card, and the tile as "Needs you".
3. The person answers in the worker's own terminal (`hc attach`, or the terminal in herdr-app).
4. The secretary removes the entry once the terminal is no longer blocked.

`hc send` refuses a blocked terminal unless `--force`; `hc keys` has no such refusal, so for it the rule is the secretary's template only.

## 8. Facts this design relies on

From the upstream documentation (herdr-core README, `docs/commands.md`, `docs/templates.md`, `docs/security.md`, `schema/README.md`, `schema/hc.openrpc.json`; herdr-app README and its mod guide `defaults/AGENTS.md`; the `hc --skill` manual of hc 0.1.18):

- `hc run [--bg] [--name] [--cwd] [--on <machine>] [--label k=v] [--keep] [--outlive-parent] <cmd|template> [task]`. Agents started inside an hc terminal become its children and end with it unless started with `--outlive-parent`. The parent gets notes when a child needs attention or ends.
- Templates are Markdown files; the header is a small line format (`command` required; `description`, `ready`, `submit`, `stop`, `paste_gap_ms` optional), the body is the opening instructions, and core appends the task after a blank line.
- Status comes only from OSC 7501 (`idle`, `working`, `done`, `blocked`, `error`, with optional `kind` and `msg`). Core does not guess from the screen.
- `hc send` pastes text and presses Enter, waiting for a person to pause. It refuses a `blocked` terminal unless `--force`, and `--if idle|working` types only on that exact status.
- The API is OpenRPC with 32 methods (including `terminal.attach`, `events.subscribe`, `doc.get` / `doc.set`, `templates.list`, `machine.*`, `file.*`). The documented policy is that the API only grows. `hc connect` carries it over stdin/stdout, including through SSH.
- Core "is not a sandbox or a permission broker for agents."
- herdr-app mods are JavaScript describing native GPUI elements; there is no HTML, CSS, DOM, Node API or `setTimeout`. Mods can read live `spaces()`, `agents()`, `terminals()`, `focused()`, run `exec` (also on other machines), `fetch`, read and write files, open overlays (dialog, popup, window, which can hold a terminal), post notifications and share state. Mods are trusted code and not sandboxed. Shipped mods are rewritten on every start, so changes go into copies. herdr-app on Linux needs a working Vulkan driver.
- herdr-app lists as agents only terminals whose program reports OSC 7501 status.
- Since Claude Code 2.1.277, a project with no CLAUDE.md has its `AGENTS.md` read instead; the choice can be changed under "Project instructions" in `/config` (Claude Code CHANGELOG). herdr-app also gives agents its own guidance as an `AGENTS.md` (its mod guide `defaults/AGENTS.md`).

Measured on 2026-11-08 (hc 0.1.18, Claude Code 2.1.319 on WSL2; herdr-app 0.1.13):

- Claude Code launched with `hc run --bg` reported `working`, `blocked` (with `kind: "permission"` and `msg: "approve Bash: touch hello-m1.txt"`) and `done`, and all of them reached both `hc get` and `hc events --json`. A separate `turn` event marks each turn's end.
- `hc send` to an idle parent arrived as its next prompt. Sent while the parent had half-typed input, it was joined to that input with no separator and submitted as one prompt. Sends were refused while the target was still starting (exit 5), `blocked` (exit 9), or not matching `--if idle` (exit 10). Delivery to a parent in the middle of a turn was not observed.
- After `hc server restart`, Claude Code kept running (same pid). After `hc server stop` and `start`, it ended and the `--keep` terminal came back as a shell; `hc run ... claude --continue` in the same folder resumed the same session.
- The mod loop worked: duplicating the shipped `agents` mod, adding one line to show a `task_id` label, `herdr-app check`, and `herdr-app shot` took about 1.7 seconds from saving the file to the PNG. `check` does not lay out the mod, so a collapsed-height bug was visible only in the shot.
- A Claude Code that stops at its startup folder-trust prompt does not report status, so herdr-app does not list it at all, rather than showing it as `blocked`.
