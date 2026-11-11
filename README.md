# paddock

An organization cockpit for coding agents, built on herdr-core (`hc`) and herdr-app.

You talk to one agent, the **secretary**. The secretary delegates work to **workers**, answers their questions, and brings to you only what it cannot decide. The organization grows by adding **skills**, and it keeps **its own records** of what ran and what was said.

paddock rebuilds these ideas from its predecessor, claude-org-ja, on a new base: herdr-core owns terminals and agent status, and herdr-app owns the screen through paddock's own mods ([decision 0003](docs/decisions/0003-screen-as-app-mods.md)).

## Status

A prototype that has run one full task on a host. [Prototype 1](docs/design/prototype-1.md) showed approvals and work in progress in a mod. [Prototype 2](docs/design/prototype-2.md) ran the whole loop on 2026-11-10: a request typed to the secretary, a worker in its own worktree, one question answered on the screen's card, a pull request at the end, with no terminal touched. What is built: the secretary template ([`templates/secretary.md`](templates/secretary.md)), the worker template ([`templates/worker.md`](templates/worker.md), with its rules and settings files; needs a read-only GitHub token file, see the [org-start skill](skills/org-start/SKILL.md)), the mailbox commands, the skills below and [the screen](#the-screen).

Run these from your own login shell, never from inside an agent (Bash only for now):

- To start the secretary and install the prototype-1 mod (`org-agents`), run `bash skills/org-start/scripts/org-start.sh` ([skill](skills/org-start/SKILL.md)).
- To renew the secretary's context, run `bash skills/secretary-handover/scripts/secretary-handover.sh` once the secretary has written its handover ([skill](skills/secretary-handover/SKILL.md)).
- To pause and come back: [`org-suspend`](skills/org-suspend/SKILL.md) records the state and leaves terminals alive, [`org-resume`](skills/org-resume/SKILL.md) prints a plan (and relaunches workers with `--apply`), and [`org-down`](skills/org-down/SKILL.md) ends only the terminals carrying a `task_id` label (the secretary too with `--secretary`) and stops your core only with `--stop-core`.

The secretary is always started with `--cwd` set to this folder (by `org-start` and by the handover script), and its template says so, so it finds `scripts/org` and the skill scripts from any starting folder.

Agents talk through the mailbox commands in [`scripts/org`](scripts/org) (`send_message`, `check_messages`, `set_summary`, `report`, `ci_completed` (written by `org-pull-request` for a watched CI run), `list_runs`, `wait` (held by the secretary between turns while work or approvals are in progress, so a card answer or a report reaches it with nobody typing), `doc` for the secretary's two core documents, and `codex_round`, the Codex review-round cap: the workers' gate hook counts each review as writer `codex-gate` in `~/.local/share/paddock/codex-rounds`, which workers may not write, and the secretary raises one task's allowance): shell only, no resident process, so they work with no window open. Messages and run records are JSON lines in `events/<YYYY-MM>/<id>.jsonl` under `~/.local/state/paddock` (`$XDG_STATE_HOME/paddock` when that is set; `PADDOCK_STATE_DIR` changes it); a sender appends only to its own file (`bash scripts/org --help`). Workers reach the copy that `org-start` places in `~/.local/share/paddock/bin` (outside the herdr-core folder their settings deny) as `$PADDOCK_ORG`; the worker rules and settings files go to the same folder, which workers may read and not write (not into the herdr-core templates folder, where `hc templates` would list the rules file). The sender id is the caller's own claim (`--as`); nothing checks it.

The secretary runs these skills itself:

- [`org-delegate`](skills/org-delegate/SKILL.md) hands a task to a new worker: it creates the worktree under the trusted workers folder (`PADDOCK_WORKERS_DIR`, default `~/paddock-workers`), writes the per-task settings file, starts the worker with `hc run --bg` and a `task_id` label, and records the start. The worker's settings ([`templates/worker-settings.json`](templates/worker-settings.json)) turn on Claude Code's sandbox and stop the worker when the sandbox cannot start. Host runs of the probes of Issues #40, #42 and #43 on a worker started this way, measured 2026-11-10, found it could not read a denied decoy file, write outside its worktree (its own history file stays writable) or rewrite its settings files ([inventory](docs/design/predecessor-inventory.md) rows L-K1, L-K4, L-K5; which layer refused is not always measured).
- [`org-escalation`](skills/org-escalation/SKILL.md) puts a worker's question the secretary cannot decide on the screen as an approval card, and forwards the person's answer to the worker.
- [`org-pull-request`](skills/org-pull-request/SKILL.md), when a worker is done: it pushes, opens the PR, watches CI as a child terminal, and stops for you or merges by the approval mode.
- [`org-update-branch`](skills/org-update-branch/SKILL.md), when main moved under a pushed branch: it merges `origin/main` in (no force needed), and in a worker stops before the merge when the range touches a sandbox-protected path.
- [`org-issue`](skills/org-issue/SKILL.md) opens a GitHub issue of one kind (decide, build or follow-up) with its dependencies on one `Depends on #N` line, the form of [the issue template](.github/ISSUE_TEMPLATE/issue.md).
- Review by a second model (Codex) before a pull request: a worker runs [`scripts/second-model-review.sh`](scripts/second-model-review.sh) (placed by `org-start`, named by `PADDOCK_CODEX_GATE`) for a review of its diff or, with `--design`, of a design it wrote. It refuses an empty pass (a review that ran no command or had nothing to look at), the round counter bounds the rounds (3 diff rounds and 1 design review per task), and [the worker rules](templates/worker-rules.md) say when to ask. The reviewing CLI starts its own sandbox, which cannot start inside the worker's, so the two argument-free gate calls are the only commands `org-delegate` lets out of the worker sandbox (exact strings in `sandbox.excludedCommands` and `permissions.allow` of the per-task settings file). Measured on the host (Claude Code 2.1.322): with the gate inside the sandbox the CLI's outbound requests were refused and no review was reached; called from the worker in the excluded form, the CLI runs to a review and the round counter's hook counts the call ([`scripts/probes/second-model-review-reach.sh`](scripts/probes/second-model-review-reach.sh); [inventory](docs/design/predecessor-inventory.md) rows L-K10, GT-2, HK-14).

Not built yet, though the predecessor relied on them ([inventory](docs/design/predecessor-inventory.md) rows in brackets):

- Growth through skills and knowledge: the curator, its raw and curated notes, and the queue of skill candidates (SK-7, SK-8, REG-4, GT-11, all kept, none written). There is no curator template.
- Notifications to a person outside the window: the attention watcher (NTF-1, kept, not written) and the incident check when the secretary does not move ([Q3](docs/design/open-questions.md#q3-incident-threshold-when-the-secretary-does-not-move): the rule is decided, who runs it is open).
- The organization settings files `org-config.md` and `projects.md` ([Q14](docs/design/open-questions.md#q14-where-do-organization-settings-and-registries-live), decided): `org config` ([#193](https://github.com/suisya-systems/paddock/issues/193)) changes them: `set` for `merge_approval_mode` (read by `org-pull-request`) and `conversation_language` (ends the secretary's launch task in `org-start` and `secretary-handover`), and `project add`, `set` and `drop` for the table `--project <name>` reads; the other values are not settings yet and the scripts use their defaults and `PADDOCK_*` variables.
- The optional features: conveyor, work discovery, metrics and defense reports ([Q15](docs/design/open-questions.md#q15-which-of-the-predecessors-optional-organization-features-carry-over), open).

Start with:

- [Architecture](docs/design/architecture.md): where each part lives, and the rules that hold it together.
- [Open questions](docs/design/open-questions.md): Q1 to Q20, each with what we know and, for most, the owner's dated decision. Still open: Q15 (which optional predecessor features carry over), and parts of Q3 (who runs the incident check) and Q11 (the predecessor tools other than the merge gate).
- [Decisions](docs/decisions/): short records of what is settled.
- [Predecessor inventory](docs/design/predecessor-inventory.md): each part of claude-org-ja, whether paddock keeps, rewrites or retires it, and what was measured.

## The screen

The window is the herdr-app layout [`layouts/paddock.json`](layouts/paddock.json) with its mod [`mods/org-cockpit/`](mods/org-cockpit/) ([architecture §7](docs/design/architecture.md#7-the-screen)): worker tiles on the left (status colour, last lines, "Needs you" when blocked; click one to open its terminal), the secretary's terminal in the centre, the secretary's questions floating at the top right while its terminal is blocked, and the oldest unanswered approval from `org-state` as one card at the bottom right, following who answers it (`answer_in`): for a worker's own permission prompt, one button that opens that worker's terminal; otherwise Yes and No buttons that send the answer to the secretary through the mailbox (`ANSWER <approval id> yes|no`, from `person`; the card reaches `org` where `org-start` places it) and a link to the secretary's pane to answer in words. Workers are the terminals labelled `task_id`; the secretary is the terminal named `secretary`.

To open it, run `org-start`: it places `layouts/paddock.json` and `mods/org-cockpit/` under `~/.config/herdr-app`, keeps a `secretary` prop already in the installed layout, and runs `herdr-app check` when it is on `PATH`. Then `herdr-app do layout.switch '{"name":"paddock"}'`. `ctrl-shift-l` switches back.

The centre is the layout's active tab. The mod labels the secretary's terminal `herdr.space=paddock` and `herdr.tab=secretary` when it lacks them, so herdr-app adopts it as the only pane of a `paddock` space, and it brings that pane to the front whenever the secretary's address changes (a renewed secretary is adopted the same way). The centre does not use a layout terminal block: in herdr-app 0.1.13 such a block is removed when its terminal ends, and the next save rewrites the layout file without it. When the secretary runs on another machine (for example a `wsl` machine added with `hc machine add`), add a `"secretary": "<machine>/secretary"` prop to each `org-cockpit` block in your copy of the layout. The mod then also reads `org-state` from that machine's core, where the secretary writes it.

## Goal

Portability. The predecessor carried its own terminal transports, pane launcher, screen-scraping monitor and dashboard. herdr already splits a headless terminal server (core) from a desktop client (app). paddock stands on that split so that the organization itself (roles, skills, messages, records) does not depend on any one terminal or window.

## Assumptions

- **herdr-core** (`hc`, 0.1 series, Apache-2.0) runs every agent terminal. It draws nothing, keeps terminals alive when no window is open, and exposes an OpenRPC API.
- **herdr-app** (0.1 series, Apache-2.0) is the default window. Its panels are JavaScript mods.
- **Claude Code** is the agent. It reports its own status to herdr-core through OSC 7501 (the Program Status Protocol), so nothing reads the screen to guess what an agent is doing.
- **Rules in English, conversation in your language.** Everything that governs agents (role instructions in `hc` template bodies, `AGENTS.md` (Claude Code reads it when there is no CLAUDE.md), skills, contract documents) is written in English. The language the secretary speaks with people is a setting, defaulting to the environment's; instructions enforce it. Today it is the line `Conversation language: auto` in the secretary template; the decided place, one line in `org-config.md` passed when the secretary starts ([Q9](docs/design/open-questions.md#q9-where-does-the-conversation-language-setting-live)), is not built yet.
- **Nothing to install beyond herdr.** paddock is written for the environments herdr already brings: the JavaScript runtime that runs herdr-app mods, `hc` templates and its CLI, and the shell. It does not assume a language or runtime that needs a separate install, such as Python or Node. What each component is written in is [Q8](docs/design/open-questions.md#q8-what-is-each-component-written-in): the mailbox is shell commands and the records are core documents plus JSON lines, with no SQLite ([decision 0004](docs/decisions/0004-records-documents-and-jsonl.md)); there is no events bridge now, and one would be a shell pipeline in a kept terminal if ever needed.
- **Windows through WSL2.** On Windows, herdr-core and the agents run only inside WSL2; herdr-app may stay native and reach the core there ([Q7](docs/design/open-questions.md#q7-windows)).

## What paddock is not

- **Not a fork or a new version of claude-org-ja.** It lives in its own repository ([decision 0001](docs/decisions/0001-separate-repository.md)). claude-org-ja keeps running as it is.
- **Not a terminal multiplexer or a terminal server.** herdr-core is the server. paddock does not run its own terminals or support other transports.
- **Not built on the older Herdr TUI** (`herdrdev/herdr`). That product does not share agents with herdr-core or herdr-app.
- **Not a management console.** No tables, no charts. The screen shows the conversation with the secretary and live views of the workers.
- **Not a sandbox.** herdr-core runs commands with your account's access and is not a permission broker. Permissions, hooks and sandboxing stay with Claude Code's own settings.
- **Not a general multi-stack framework.** Only herdr-core, herdr-app and Claude Code are in scope.

## CI

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs, on every push and pull request:

- `scripts/check-links.sh` on relative Markdown links, after its own test.
- Every `tests/*.test.sh`, in one step (a new test file needs no change to the workflow). They test the skills, the `org` commands, the worker template and settings, and the shape of the screen's layout and mods, against a stubbed `hc` (and a stubbed GitHub CLI for `org-pull-request`).
- `scripts/check-templates.sh` on every template header.
- `sh -n` on the probe scripts in [`scripts/probes/`](scripts/probes/). The probes themselves are host runs against a real core; their results are recorded in the design documents. The mailbox probe [`org-mailbox-restart.sh`](scripts/probes/org-mailbox-restart.sh) (messages survive a window restart) has no recorded result yet.
- For each mod, `mod.json` parses and `main.js` passes `node --check`. `herdr-app check` needs a display, so it and a screenshot are host-side checks.

## License

Not decided yet. The repository is private.
