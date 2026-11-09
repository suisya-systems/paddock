---
name: org-start
description: Start the paddock organization. Reuses the herdr core, starts the secretary from templates/secretary.md with --keep, places the org-agents mod, and reports readiness. Run it from your own login shell.
---

# org-start

Run this from the person's login shell (or a service). Never from inside an agent.

```sh
bash skills/org-start/scripts/org-start.sh
```

Bash only. There is no `.ps1` yet: the pwsh path could not be tested, so it is not shipped. On Windows run the script from Git Bash, where `sh` must be on `PATH` anyway (templates run their command through `sh`).

## What it does

1. **Core.** Starts no core itself. The first `hc` command starts one if none runs, and that core inherits this shell's environment, so the script refuses (exit 4) when it finds `CLAUDECODE` or one of the `CLAUDE_CODE_*` session variables set in its own environment. This is the start rule of [Q17](../../docs/design/open-questions.md#q17-what-environment-do-the-core-and-its-terminals-start-with) (decision d). It **cannot yet tell** whether an already running core was started from an agent: no probe has read a core's own environment. Until one does, the template's `env -u ...` prefix is the second line of defence.
2. **Template.** Copies `templates/secretary.md` into herdr-core's `templates` folder.
3. **Mods.** Copies `mods/org-agents/` into herdr-app's `mods/org-agents` folder (overwriting the same two files, so a rerun duplicates nothing). On the first run, when `herdr-app` is on `PATH`, it first runs `mod.clone` so the folder gets the type files. This mod is the organization layout the window shows ([prototype 1](../../docs/design/prototype-1.md)).
4. **Secretary.** If `hc get secretary` finds none, runs `hc run --bg --keep --name secretary secretary`. If one exists it starts nothing. If that terminal is dead, `hc kill` and `hc rm` it yourself, then rerun.
5. **Readiness.** Waits up to 15 s for `hc get --json secretary` to show a status, then prints `ready` (exit 0) or exits 7.

It never runs `hc server stop` or `hc server restart`.

## Folders

Defaults are `$XDG_CONFIG_HOME` (else `~/.config`), or `%APPDATA%` when set, plus `herdr-core/templates` and `herdr-app/mods`. Override with `PADDOCK_CORE_TEMPLATES_DIR` and `PADDOCK_APP_MODS_DIR`. These default paths are not verified on every platform. `PADDOCK_SECRETARY_NAME` changes the secretary's terminal name (default `secretary`); the template keeps its name. It exists so a probe can run beside a real secretary.

## Exit codes

0 ready, 2 bad argument, 3 `hc` not found, 4 run inside an agent, 5 core unreachable or `hc run` failed, 6 files could not be placed, 7 no status yet.

## After it runs

Probe #52 (the SK-2 row of the [predecessor inventory](../../docs/design/predecessor-inventory.md)) checks that `env` inside the secretary has no `CLAUDE_CODE_CHILD_SESSION`. The script does not check that itself.

## Known limit

The script places the mod but does not open it: `mod.json` has `"place": "none"`, and opening the dialog is a separate herdr-app step that can toggle, so it is not scripted until an idempotent form is measured. Open it as described in [prototype 1](../../docs/design/prototype-1.md).
