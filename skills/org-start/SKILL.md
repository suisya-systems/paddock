---
name: org-start
description: Start the paddock organization. Reuses the herdr core, starts the secretary from templates/secretary.md with --keep, places the org-agents mod, and reports readiness. Run it from your own login shell.
---

# org-start

Starts the organization. Why it is built this way: [references/rationale.md](references/rationale.md). Run this from the person's login shell (or a service). Never from inside an agent.

```sh
bash skills/org-start/scripts/org-start.sh
```

Bash only. There is no `.ps1` yet: the pwsh path could not be tested, so it is not shipped. On Windows, run it inside WSL2: core and agents run only there. Native Windows (Git Bash) is not supported for the core or agents.

## What it does

0. **Notes off.** Before anything is placed, it looks for a top-level `notes = false` line (before the first `[table]`) in `config.toml` of the core's config folder (`PADDOCK_CORE_CONFIG_DIR`, default `$XDG_CONFIG_HOME/herdr-core`; other files there do not count) (decision 0002). Missing: exit 8 with one line saying to add it and to restart the core if the change does not take effect (not measured whether the core re-reads the file). It never writes the core's config.
1. **Core.** Starts no core itself. The first `hc` command starts one if none runs, and that core inherits this shell's environment, so the script refuses (exit 4) when it finds `CLAUDECODE` or one of the `CLAUDE_CODE_*` session variables set in its own environment. This is the start rule. It **cannot yet tell** whether an already running core was started from an agent: no probe has read a core's own environment. Until one does, the template's `env -u ...` prefix is the second line of defence.
2. **Templates.** Copies `templates/secretary.md` and `templates/worker.md` into herdr-core's `templates` folder. It copies `scripts/org`, the second-model review gate `scripts/second-model-review.sh` (the worker template exports it as `PADDOCK_CODEX_GATE`), the premise-reminder hook `scripts/hooks/premise-reminder.sh` and the secretary's `templates/secretary-settings.json` (the secretary template passes it with `--settings`; its `UserPromptSubmit` hook prints one "verify before agreeing" line when the person's message carries a number with a unit, a setting name or a claim about behaviour, and never blocks), and the worker's two role files, `templates/worker-rules.md` and `templates/worker-settings.json`, to `$XDG_DATA_HOME/paddock/bin/` (else `~/.local/share/paddock/bin/`; `PADDOCK_BIN_DIR`, an absolute path, names another folder, but not the templates folder or one inside it: exit 2). The worker template's command exports `<that folder>/org` as `PADDOCK_ORG` and passes the role files with `--append-system-prompt-file` and `--settings`. Not beside the templates: the worker settings deny reading the herdr-core folder, so a worker could not run the script there, and herdr-core lists every `*.md` in its templates folder as a template, so the rules file showed up in `hc templates` as a broken one. The worker settings deny writing this folder, so a worker cannot rewrite its own rules or settings. It removes the `worker-rules.md` and `worker-settings.json` an older org-start left in the templates folder (exit 6 if it cannot); an old `org` copy there is no longer used.
3. **Mods and layout.** Copies `mods/org-cockpit/` into herdr-app's `mods/org-cockpit` and `layouts/paddock.json` into its `layouts` folder (`PADDOCK_APP_LAYOUTS_DIR`, default `layouts` beside the mods folder). A `"secretary"` prop already in the installed layout is put back into the new copy. When the app sees this core as another machine, the prop is written as `<machine>/<secretary name>` in every cockpit block: the machine is `PADDOCK_APP_MACHINE`, else the one in the installed prop, else `wsl` on WSL with herdr-app for Windows. It then runs `herdr-app check` on the cockpit mod when `herdr-app` is on `PATH` (on WSL, else the Windows exe in the installer's default folder) and prints the `layout.switch` command that opens the screen; a failed check only warns (the check needs a display). Then it runs that `layout.switch` itself (a failure only warns). On WSL, a `herdr-app` on `PATH` that is a Linux program looks for the window at `HERDR_APP_HOME` or `~/.config/herdr-app/herdr-app.sock`; when that file is missing and the Windows user's `.config/herdr-app/herdr-app.sock` exists, the Windows program is used instead. On WSL it prints both socket paths it looked for. Also copies `mods/org-agents/` into herdr-app's `mods/org-agents` folder (overwriting the same two files, so a rerun duplicates nothing). On the first run, when `herdr-app` is on `PATH`, it first runs `mod.clone` so the folder gets the type files. This mod is the organization layout the window shows.
4. **Secretary.** If `hc get secretary` finds none, runs `hc run --bg --keep --name secretary --cwd <paddock folder> secretary` (`--cwd` is the repository root, so the secretary finds `scripts/org` and the skill scripts whatever folder you ran from). If one exists it starts nothing. If that terminal has `state: finished` (it ended), the script runs `hc rm` on it first (exit 5 if that fails) and then starts a new one.
5. **Watcher.** Starts [org-watch](../org-watch/SKILL.md) as `hc run --bg --keep --no-notify --name watcher --label paddock_role=watcher --cwd <paddock folder> -- bash <paddock folder>/skills/org-watch/scripts/org-watch.sh` unless a `watcher` terminal exists (`PADDOCK_WATCHER_NAME` renames it); a finished one is removed first. A failure to start it only warns. It runs next to the secretary so a person is told outside the window of a waiting approval or a stopped secretary.
6. **Readiness.** Waits up to 15 s for `hc get --json secretary` to show a status, then prints `ready` (exit 0) or exits 7.
7. **Folder trust.** While there is no status, it reads the secretary's screen (`hc read`). When Claude Code's folder-trust dialog is there (`Quick safety check` / `Yes, I trust this folder`), it presses `down`, reads the screen again and presses `enter` only when the cursor `❯` is on "Yes, I trust this folder" (the default is "No, exit"; never a blind Enter). A cursor that did not get there stops with exit 7 and nothing confirmed. Then it waits up to 15 s for the status again and, since the dialog kept the first message from arriving, sends it with one `hc send`: the body of the installed `secretary.md` (what hc sends first), plus a blank line and the launch task when there is one (the conversation-language line). It does this only for a secretary this run started (its `--cwd` is the paddock folder); an existing secretary at the dialog, which may sit in another folder, keeps the plain exit 7. This is the one-time step for the secretary's own root; it never writes `~/.claude.json`, and for worker worktrees org-delegate presses no keys. A screen without the dialog keeps the old exit 7.

It never runs `hc server stop` or `hc server restart`.

## First-run check (`--check`, decision 0007)

First-run setup is a person's one-time job per machine, outside the round (G1 covers a round only). `bash skills/org-start/scripts/org-start.sh --check [--project DIR]...` is the one command that lists what is left. It prints `ok <step>: ...` or `TODO <step>: <exact fix>` for every step (hc, agent-shell, claude, notes, core-path, and trust for each `--project` clone), and `skip core-path: <why>` when there is no core yet or `/proc` is not readable. It is read-only: no hc call, nothing placed, no secretary; it never writes the core's config and never restarts the core. Exit 0 only when no TODO is left, 1 otherwise, 2 for a bad argument. A clean host reaches `org-start: ready` after the person's actions, with `--check` clean: `notes = false` in the core config, the core started from a login shell that has hc's folder on PATH, and each project clone trusted once with `claude`.

The core PATH check reads `/proc/<core pid>/environ` of the running core, not the PATH of the shell that runs org-start (the Run 6 case). Linux and WSL only: elsewhere the normal run skips it silently and `--check` says so. The checks live in `first-run-checks.sh` and are shared with `prototype-3.sh prepare` and `prototype-3-setup.sh`.

## Folders

Defaults are `$XDG_CONFIG_HOME` (else `~/.config`), or `%APPDATA%` when set, plus `herdr-core/templates` and `herdr-app/mods`. On WSL, when `herdr-app` is not on `PATH` or is a Windows `.exe`, the app's folders are the Windows user's `.config/herdr-app` (found with `cmd.exe` and `wslpath`), since herdr-app for Windows reads them there. Override with `PADDOCK_CORE_TEMPLATES_DIR` and `PADDOCK_APP_MODS_DIR`. The org script and the worker role files go to `$XDG_DATA_HOME` (else `~/.local/share`) plus `paddock/bin`, or `PADDOCK_BIN_DIR`. These default paths are not verified on every platform. `PADDOCK_SECRETARY_NAME` changes the secretary's terminal name (default `secretary`); the template keeps its name. It exists so a probe can run beside a real secretary.

## Worker GitHub access

A worker holds no GitHub credential and org-start asks the person for none (the local mirror). The worker template gives it an empty `GH_CONFIG_DIR` and removes the token variables; it reads its base from the project clone's `origin/*`, which the secretary fetches (see [org-delegate](../org-delegate/SKILL.md)). The template reads `PADDOCK_BIN_DIR` when set, so it finds the role files and the org script wherever org-start placed them.

## Exit codes

0 ready, 2 bad argument, 3 `hc` not found, 4 run inside an agent, 5 core unreachable or `hc run` failed, 6 files could not be placed, 7 no status yet (the message gives the terminal's exit code and last output line, and names a missing `claude`), 8 the core's notes are not off, 9 `claude` not found from org-start's shell (its absolute path is recorded in `claude-path` beside the org script, and the templates start it by that path; the same is done for `codex` in `codex-path`, which the review gate reads when its PATH lacks it), 10 `hc` is not on the running core's PATH (restart herdr from a login shell that has it).

## After it runs

A host probe checks that `env` inside the secretary has no `CLAUDE_CODE_CHILD_SESSION`. The script does not check that itself.

## Known limit

The script places the mod but does not open it: `mod.json` has `"place": "none"`, and opening the dialog is a separate herdr-app step that can toggle, so it is not scripted until an idempotent form is measured. Open it with the `layout.switch` command org-start prints.

The deny and sandbox paths in `templates/worker-settings.json` are the default folders (`~/.config/herdr-core`, `~/.config/herdr-app`, `~/.local/state/herdr-core`, `~/.config/gh/hosts.yml`, and `~/.local/share/paddock`, the org script and role files, denied for writing only). A JSON settings file cannot expand `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `PADDOCK_BIN_DIR` or `APPDATA`, so with those set to another place the paths do not follow. Not solved here.

`scripts/org` writes under `$PADDOCK_STATE_DIR` (default `~/.local/state/paddock`). A worker may write only its own files there: org-delegate names them in the worker's own settings file, so they follow `PADDOCK_STATE_DIR`; the file-tool hook in `worker-settings.json` reads `PADDOCK_STATE_DIR` from the worker's environment, as `scripts/org` does.

The `PADDOCK_*` overrides reach a worker only through the environment of the core. Set them in the login shell that starts the core; setting them for an org-start run against a core that is already running changes only org-start's own check and placement.
