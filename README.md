# paddock

An organization cockpit for coding agents, built on herdr-core (`hc`) and herdr-app.

You talk to one agent, the **secretary**. The secretary delegates work to **workers**, answers their questions, and brings to you only what it cannot decide. The organization grows by adding **skills**, and it keeps **its own records** of what ran and what was said.

paddock rebuilds these ideas from its predecessor, claude-org-ja, on a new base: herdr-core owns terminals and agent status, and herdr-app (or a client of our own) owns the screen.

## Status

A first prototype: the secretary template, the worker template ([`templates/worker.md`](templates/worker.md), with its rules and settings files; needs a read-only GitHub token file, see the [org-start skill](skills/org-start/SKILL.md)) and a mod that shows approvals and work in progress ([prototype 1](docs/design/prototype-1.md)). To start the secretary and install the mod, run `bash skills/org-start/scripts/org-start.sh` from your own login shell, never from inside an agent ([skill](skills/org-start/SKILL.md); Bash only for now). To renew the secretary's context, run `bash skills/secretary-handover/scripts/secretary-handover.sh` the same way, once the secretary has written its handover ([skill](skills/secretary-handover/SKILL.md)). To pause and come back: [`org-suspend`](skills/org-suspend/SKILL.md) records the state and leaves terminals alive, [`org-resume`](skills/org-resume/SKILL.md) prints a plan (and relaunches workers with `--apply`), and [`org-down`](skills/org-down/SKILL.md) ends only the terminals carrying a `task_id` label and stops your core only with `--stop-core`. The secretary is always started with `--cwd` set to this folder (by `org-start` and by the handover script), and its template says so, so it finds `scripts/org` and the skill scripts from any starting folder. Agents talk through the mailbox commands in [`scripts/org`](scripts/org) (`send_message`, `check_messages`, `set_summary`, `report`, `list_runs`, and `doc` for the secretary's two core documents): shell only, no resident process, so they work with no window open. Messages and run records are JSON lines under `~/.local/state/paddock/events/` (`PADDOCK_STATE_DIR` changes it); a sender appends only to its own file (`bash scripts/org --help`). Workers reach the copy that `org-start` places in `~/.local/share/paddock/bin` (outside the herdr-core folder their settings deny) as `$PADDOCK_ORG`. The sender id is the caller's own claim (`--as`); nothing checks it. To hand a task to a new worker, the secretary runs [`org-delegate`](skills/org-delegate/SKILL.md): it creates the worktree under the trusted workers folder (`PADDOCK_WORKERS_DIR`, default `~/paddock-workers`), writes the per-task settings file, starts the worker with `hc run --bg` and a `task_id` label, and records the start. Whether a worker it started takes effect (the probes of Issues #40, #42, #43) is not measured yet. When a worker is done, the secretary runs [`org-pull-request`](skills/org-pull-request/SKILL.md): it pushes, opens the PR, watches CI as a child terminal, and stops for you or merges by the approval mode. Start with:

- [Architecture](docs/design/architecture.md): where each part lives, and the rules that hold it together.
- [Open questions](docs/design/open-questions.md): decisions the owner has not made yet, with what we know so far.
- [Decisions](docs/decisions/): short records of what is settled.

## The screen

The window is the herdr-app layout [`layouts/paddock.json`](layouts/paddock.json) with its mod [`mods/org-cockpit/`](mods/org-cockpit/) ([architecture §7](docs/design/architecture.md#7-the-screen)): worker tiles on the left (status colour, last lines, "Needs you" when blocked; click one to open its terminal), the secretary's terminal in the centre, the secretary's questions floating at the top right while its terminal is blocked, and the oldest approval from `org-state` as one card at the bottom right. Workers are the terminals labelled `task_id`; the secretary is the terminal named `secretary`.

To open it, copy `layouts/paddock.json` into herdr-app's `layouts/` folder and `mods/org-cockpit/` into its `mods/` folder (under `~/.config/herdr-app`), run `herdr-app check <that folder>/mods/org-cockpit`, then `herdr-app do layout.switch '{"name":"paddock"}'`. `ctrl-shift-l` switches back.

The centre is the layout's active tab. The mod labels the secretary's terminal `herdr.space=paddock` and `herdr.tab=secretary` when it lacks them, so herdr-app adopts it as the only pane of a `paddock` space, and it brings that pane to the front whenever the secretary's address changes (a renewed secretary is adopted the same way). The centre does not use a layout terminal block: in herdr-app 0.1.13 such a block is removed when its terminal ends, and the next save rewrites the layout file without it. When the secretary runs on another machine (for example a `wsl` machine added with `hc machine add`), add a `"secretary": "<machine>/secretary"` prop to each `org-cockpit` block in your copy of the layout. The mod then also reads `org-state` from that machine's core, where the secretary writes it.

## Goal

Portability. The predecessor carried its own terminal transports, pane launcher, screen-scraping monitor and dashboard. herdr already splits a headless terminal server (core) from a desktop client (app). paddock stands on that split so that the organization itself (roles, skills, messages, records) does not depend on any one terminal or window.

## Assumptions

- **herdr-core** (`hc`, 0.1 series, Apache-2.0) runs every agent terminal. It draws nothing, keeps terminals alive when no window is open, and exposes an OpenRPC API.
- **herdr-app** (0.1 series, Apache-2.0) is the default window. Its panels are JavaScript mods.
- **Claude Code** is the agent. It reports its own status to herdr-core through OSC 7501 (the Program Status Protocol), so nothing reads the screen to guess what an agent is doing.
- **Rules in English, conversation in your language.** Everything that governs agents (role instructions in `hc` template bodies, `AGENTS.md` (Claude Code reads it when there is no CLAUDE.md), skills, contract documents) is written in English. The language the secretary speaks with people is a setting, defaulting to the environment's; instructions enforce it. Where that setting lives is [an open question](docs/design/open-questions.md#q9-where-does-the-conversation-language-setting-live).
- **Nothing to install beyond herdr.** paddock is written for the environments herdr already brings: the JavaScript runtime that runs herdr-app mods, `hc` templates and its CLI, and the shell. It does not assume a language or runtime that needs a separate install, such as Python or Node. What each component is written in is [an open question](docs/design/open-questions.md#q8-what-is-each-component-written-in).

## What paddock is not

- **Not a fork or a new version of claude-org-ja.** It lives in its own repository ([decision 0001](docs/decisions/0001-separate-repository.md)). claude-org-ja keeps running as it is.
- **Not a terminal multiplexer or a terminal server.** herdr-core is the server. paddock does not run its own terminals or support other transports.
- **Not built on the older Herdr TUI** (`herdrdev/herdr`). That product does not share agents with herdr-core or herdr-app.
- **Not a management console.** No tables, no charts. The screen shows the conversation with the secretary and live views of the workers.
- **Not a sandbox.** herdr-core runs commands with your account's access and is not a permission broker. Permissions, hooks and sandboxing stay with Claude Code's own settings.
- **Not a general multi-stack framework.** Only herdr-core, herdr-app and Claude Code are in scope.

## CI

CI: relative Markdown links are checked by `scripts/check-links.sh`, and one CI step runs every `tests/*.test.sh` (a new test file needs no change to the workflow). `tests/secretary-cwd.test.sh` (a secretary started from another folder gets `--cwd`), `tests/org-start.test.sh`, `tests/secretary-handover.test.sh`, `tests/org-suspend.test.sh`, `tests/org-resume.test.sh`, `tests/org-down.test.sh` and `tests/org-delegate.test.sh` (with `tests/org-delegate-edge.test.sh` for review regressions) test the skills of the same names against a stubbed `hc`; `tests/org-pull-request.test.sh` tests [`org-pull-request`](skills/org-pull-request/SKILL.md) against a stubbed `hc` and GitHub CLI; `tests/org-commands.test.sh` and `tests/org-commands-edge.test.sh` test the `org` commands against a stubbed `hc`; the host probe [`scripts/probes/org-mailbox-restart.sh`](scripts/probes/org-mailbox-restart.sh) shows the messages survive a window restart (not measured yet); `tests/org-layout.test.sh` checks the shape of the screen's layout and mods (`herdr-app check` and a screenshot are host-side checks).

## License

Not decided yet. The repository is private.
