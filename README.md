# paddock

An organization cockpit for coding agents, built on herdr-core (`hc`) and herdr-app.

You talk to one agent, the **secretary**. The secretary delegates work to **workers**, answers their questions, and brings to you only what it cannot decide. The organization grows by adding **skills**, and it keeps **its own records** of what ran and what was said.

paddock rebuilds these ideas from its predecessor, claude-org-ja, on a new base: herdr-core owns terminals and agent status, and herdr-app (or a client of our own) owns the screen.

## Status

Design only. There is no code yet. Start with:

- [Architecture](docs/design/architecture.md): where each part lives, and the rules that hold it together.
- [Open questions](docs/design/open-questions.md): decisions the owner has not made yet, with what we know so far.
- [Decisions](docs/decisions/): short records of what is settled.

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

CI: relative Markdown links are checked by `scripts/check-links.sh`.

## License

Not decided yet. The repository is private.
