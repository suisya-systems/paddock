# paddock

An organization cockpit for coding agents, built on herdr-core (`hc`) and herdr-app.

You talk to one agent, the **secretary**. The secretary hands work to **workers**, each in its own git worktree, answers their questions, and brings to you only what it cannot decide. Work on a GitHub repository ends in a pull request.

paddock is a prototype: it has run full tasks, from a request to a pull request, on a host. How it is built and what is not built yet: [docs/development.md](docs/development.md).

## Requirements

- **herdr-core** (`hc`, 0.1 series): runs every agent terminal.
- **herdr-app** (0.1 series): the window.
- **Claude Code** (`claude`): the agents.
- `git`, `gh` (the GitHub CLI, logged in), `codex` (a second model is asked to review each worker's diff before its pull request: [`scripts/second-model-review.sh`](scripts/second-model-review.sh); without codex, Claude reviews instead, in a fresh headless session with read-only tools, which is weaker than a different model's review; a review counts when the reviewer ran at least one command, exited 0 and gave its final review text, even if some of the commands it ran while exploring failed; when no review could run, the pull request says so), `sh`, `awk` and the usual coreutils. Python and Node are not needed.
- On Windows: herdr-core and the agents run inside WSL2. The window can be herdr-app for Windows.

## Install and start

Clone this repository and go to its top folder: the script paths in this README are relative to it. Run every command from your own login shell there, never from inside an agent, unless a step names another shell.

First check your machine:

```sh
bash skills/org-start/scripts/org-start.sh --check
```

It changes nothing. It prints one line for each step (`hc`, not inside an agent, `claude`, the reviewer, `notes = false` in the herdr-core config, `hc` on the running core's PATH, the herdr-app mods folder): `ok <step>: ...` or `TODO <step>: <fix>`. Do what each `TODO` line says and run it again until no `TODO` is left. A `skip` line needs nothing from you.

### Linux, macOS, or WSL with a Linux herdr-app

1. Open herdr-app.
2. Run:

   ```sh
   bash skills/org-start/scripts/org-start.sh
   ```

   It places the paddock layout ([`layouts/paddock.json`](layouts/paddock.json)) and its mod under `~/.config/herdr-app`, switches the window to the paddock screen, and starts the secretary (and a `watcher` terminal that tells you when something waits for you). Its last line starts with `org-start: ready`; if it ends with another `org-start:` line, that line says what went wrong. Running it again starts no second secretary.
3. Normally there is nothing to do here: org-start switched the window to the paddock screen itself and printed `org-start: switched the screen to the paddock layout`. Only if it printed `org-start: warning: layout.switch failed`, or the window still shows another layout, open the screen yourself. Either run the command org-start printed on the line that starts with `org-start: to open the screen:` (everything after that colon), for example:

   ```sh
   herdr-app do layout.switch '{"name":"paddock"}'
   ```

   or click the herdr-app window and press `ctrl-shift-l`, again if needed, until the paddock screen shows. (No `to open the screen:` line means org-start found no `herdr-app` on its PATH: use the key.)

### WSL with herdr-app for Windows

The core and the agents run in WSL; the window runs on Windows.

1. Once, in PowerShell on Windows, add your WSL distribution as a machine named `wsl` (replace `Ubuntu` with your distribution):

   ```powershell
   hc machine add --via 'wsl.exe -d Ubuntu -e sh -c' --name wsl
   ```

   Use the Windows `hc` 0.1.20 or later (`hc --version`). If you choose another name, set `PADDOCK_APP_MACHINE` to it in WSL before step 2.
2. Open herdr-app on Windows. Then, in WSL, run `bash skills/org-start/scripts/org-start.sh`. It places the layout and mod in the Windows user's `.config/herdr-app`, points the screen at the secretary on the `wsl` machine, switches the window to the paddock screen and starts the secretary and the watcher. Its last line starts with `org-start: ready`.

Normally that is all. Two cases need one more action:

- **The window still shows another layout** (org-start printed `org-start: warning: layout.switch failed`, or no `org-start: switched the screen to the paddock layout` line): in WSL, run the command org-start printed on the line that starts with `org-start: to open the screen:` (everything after that colon; it starts with the path of `herdr-app.exe`). Or click the herdr-app window and press `ctrl-shift-l`, again if needed, until the paddock screen shows.
- **org-start printed `org-start: warning: WSL, but the Windows user folder was not found`** (or `WSL, but several Windows users have a herdr-app folder`): it could not tell which Windows folder herdr-app reads. In WSL, set both `PADDOCK_APP_MODS_DIR` to the Windows herdr-app's mods folder (as a WSL path, for example `/mnt/c/Users/<you>/.config/herdr-app/mods`) and `PADDOCK_APP_MACHINE` to the machine name from step 1 (`wsl` unless you chose another), then run org-start again.

### Switching screens

The secretary and the workers keep running while the window shows another layout.

- With the window focused, press `ctrl-shift-l` to go to the next layout (press again if you have more than two).
- Or name it: `herdr-app do layout.switch '{"name":"main"}'` for herdr-app's own layout, `'{"name":"paddock"}'` to come back.

## Asking the secretary for work

### The screen

The paddock screen has:

- the secretary's terminal in the centre: type your request there, in your own words, and name the repository it is about;
- the workers as tiles on the left, under a "Back to the secretary" button. A tile shows the worker's status and last lines, and "Needs you" when it waits. Click a tile to look at its terminal; "Back to the secretary" returns to the centre;
- below the tiles, the watcher strip;
- the secretary's questions at the top right, and approval cards at the bottom right.

### A request

The secretary starts a worker for each task. When work on a GitHub repository is done, it opens a pull request and, by default, asks you on an approval card before it merges; with the setting `merge_approval_mode` set to `acceptance` instead of `human`, it raises no card and merges once the pull request's checks pass ([docs/development.md](docs/development.md)). When a request needs no GitHub repository, the secretary may make a new local repository for it (under `~/paddock-local/`); that work gets no pull request: the secretary tells you the summary and the folder, and merges it into that repository's `main` only after you agree.

## Answering approval cards

When the secretary cannot decide something, a card appears at the bottom right with the question, what Yes and No each do, and its recommendation.

- Press **Yes** or **No**.
- To add something, type it in the field "Anything to add?" before you press Yes or No; it is sent with your answer.
- To answer in words, click "Open the secretary to answer in words" and reply in the secretary's terminal.

## Pause, resume and stop

From your own login shell:

| Command | What it does |
| --- | --- |
| `bash skills/org-suspend/scripts/org-suspend.sh` | Records the state of the work. Ends nothing. |
| `bash skills/org-resume/scripts/org-resume.sh` | Prints a plan for bringing the workers back. Starts nothing. |
| `bash skills/org-resume/scripts/org-resume.sh --apply` | Restarts each worker whose terminal is gone, where it left off. |
| `bash skills/org-down/scripts/org-down.sh` | Records the state, then ends the workers and the watcher. The secretary keeps running. |
| `bash skills/org-down/scripts/org-down.sh --secretary` | Also ends the secretary. |
| `bash skills/org-down/scripts/org-down.sh --stop-core` | Also stops herdr-core, with every terminal on it, paddock's or not. Without this flag the core is never stopped. |

To come back after `org-down`: run `bash skills/org-start/scripts/org-start.sh` (it starts the secretary, if it was ended, and the watcher), then `bash skills/org-resume/scripts/org-resume.sh --apply`.

The secretary renews itself: it writes its handover and leaves a request (`scripts/org --as secretary renew_secretary`), and the watcher runs `skills/secretary-handover/scripts/secretary-handover.sh` once it is idle. Run that script yourself only when the watcher tells you a renewal failed, or no watcher runs.

## Troubleshooting

Start with `bash skills/org-start/scripts/org-start.sh --check`.

**`hc unreachable`** at the top of the worker tiles, or **`Can't reach hc.`** in the card's place: the screen could not read the organization's state. The line under the message is the error:

- `sh: hc: not found` (the wording depends on the shell): `hc` is not on the PATH of the running herdr-core. The `core-path` line of `--check` says so. From a login shell that has `hc` on its PATH (outside herdr), run `bash skills/org-start/scripts/org-start.sh --restart-core`: it lists the terminals it will end (all of them, the secretary and workers too), asks y/N (`--yes` skips the question), runs `hc server stop` and `hc server start`, and then starts the organization as usual.
- herdr-app for Windows with no `wsl` machine: the screen looks for `hc` on Windows, not in WSL. Do steps 1 and 2 of [WSL with herdr-app for Windows](#wsl-with-herdr-app-for-windows).
- The machine name is wrong: `hc machine ls` lists the machines; set `PADDOCK_APP_MACHINE` to the right name and run org-start again.
- The core is not running: run org-start, which starts one.

The tiles recover within a few seconds once a read works.

**The secretary is not in the centre:** the mod brings the terminal named `secretary` there by labelling it `herdr.space=paddock` and `herdr.tab=secretary`. Check that org-start ended with `org-start: ready`.

**The watcher strip says the watcher is not running:** run org-start again.

## For developers

How paddock is built (the secretary and worker templates such as [`templates/worker.md`](templates/worker.md), the mailbox, each skill, the review by a second model, CI) and its design documents: [docs/development.md](docs/development.md).

## License

MIT License. See [LICENSE](LICENSE).
