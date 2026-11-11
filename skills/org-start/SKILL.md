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
2. **Templates.** Copies `templates/secretary.md` and `templates/worker.md` into herdr-core's `templates` folder. It then warns, and still goes on, when the worker token file is missing (see below). It copies `scripts/org`, the premise-reminder hook `scripts/hooks/premise-reminder.sh` and the secretary's `templates/secretary-settings.json` (the secretary template passes it with `--settings`; its `UserPromptSubmit` hook prints one "verify before agreeing" line when the person's message carries a number with a unit, a setting name or a claim about behaviour, and never blocks), and the worker's two role files, `templates/worker-rules.md` and `templates/worker-settings.json`, to `$XDG_DATA_HOME/paddock/bin/` (else `~/.local/share/paddock/bin/`; `PADDOCK_BIN_DIR`, an absolute path, names another folder, but not the templates folder or one inside it: exit 2). The worker template's command exports `<that folder>/org` as `PADDOCK_ORG` and passes the role files with `--append-system-prompt-file` and `--settings` ([Q10](../../docs/design/open-questions.md#q10-who-distributes-permissions-hooks-and-skills-and-when), [Q12](../../docs/design/open-questions.md#q12-where-do-a-workers-role-rules-and-task-brief-live)). Not beside the templates: the worker settings deny reading the herdr-core folder, so a worker could not run the script there (Issue #128), and herdr-core lists every `*.md` in its templates folder as a template, so the rules file showed up in `hc templates` as a broken one (Issue #129). The worker settings deny writing this folder, so a worker cannot rewrite its own rules or settings. It removes the `worker-rules.md` and `worker-settings.json` an older org-start left in the templates folder (exit 6 if it cannot); an old `org` copy there is no longer used.
3. **Mods and layout.** Copies `mods/org-cockpit/` into herdr-app's `mods/org-cockpit` and `layouts/paddock.json` into its `layouts` folder (`PADDOCK_APP_LAYOUTS_DIR`, default `layouts` beside the mods folder; Issue #195). A `"secretary"` prop already in the installed layout is put back into the new copy. It then runs `herdr-app check` on the cockpit mod when `herdr-app` is on `PATH`; a failure only warns (the check needs a display). Also copies `mods/org-agents/` into herdr-app's `mods/org-agents` folder (overwriting the same two files, so a rerun duplicates nothing). On the first run, when `herdr-app` is on `PATH`, it first runs `mod.clone` so the folder gets the type files. This mod is the organization layout the window shows ([prototype 1](../../docs/design/prototype-1.md)).
4. **Secretary.** If `hc get secretary` finds none, runs `hc run --bg --keep --name secretary --cwd <paddock folder> secretary` (`--cwd` is the repository root, so the secretary finds `scripts/org` and the skill scripts whatever folder you ran from, Issue #130). If one exists it starts nothing. If that terminal has `state: finished` (it ended), the script runs `hc rm` on it first (exit 5 if that fails) and then starts a new one (Issue #192).
5. **Readiness.** Waits up to 15 s for `hc get --json secretary` to show a status, then prints `ready` (exit 0) or exits 7.

It never runs `hc server stop` or `hc server restart`.

## Folders

Defaults are `$XDG_CONFIG_HOME` (else `~/.config`), or `%APPDATA%` when set, plus `herdr-core/templates` and `herdr-app/mods`. Override with `PADDOCK_CORE_TEMPLATES_DIR` and `PADDOCK_APP_MODS_DIR`. The org script and the worker role files go to `$XDG_DATA_HOME` (else `~/.local/share`) plus `paddock/bin`, or `PADDOCK_BIN_DIR`. These default paths are not verified on every platform. `PADDOCK_SECRETARY_NAME` changes the secretary's terminal name (default `secretary`); the template keeps its name. It exists so a probe can run beside a real secretary.

## Worker token

A worker starts only with a read-only GitHub token ([Q20](../../docs/design/open-questions.md#q20-how-is-a-workers-github-access-held-to-read-only)). The person creates a fine-grained token with `contents:read` for the repositories workers may fetch, and saves it as the only content of `$XDG_CONFIG_HOME/paddock/worker-gh-token` (else `~/.config/paddock/worker-gh-token`; under `%APPDATA%` when `APPDATA` is set). `PADDOCK_WORKER_GH_TOKEN_FILE` names another file. The file stays outside the repository. org-start checks only that the file exists and is not empty, never reads it, and warns when it is not there; the worker template then refuses to launch, with the same path in its message. The template also reads `PADDOCK_BIN_DIR` when set, so it finds the role files and the org script wherever org-start placed them.

## Exit codes

0 ready, 2 bad argument, 3 `hc` not found, 4 run inside an agent, 5 core unreachable or `hc run` failed, 6 files could not be placed, 7 no status yet.

## After it runs

Probe #52 (the SK-2 row of the [predecessor inventory](../../docs/design/predecessor-inventory.md)) checks that `env` inside the secretary has no `CLAUDE_CODE_CHILD_SESSION`. The script does not check that itself.

## Known limit

The script places the mod but does not open it: `mod.json` has `"place": "none"`, and opening the dialog is a separate herdr-app step that can toggle, so it is not scripted until an idempotent form is measured. Open it as described in [prototype 1](../../docs/design/prototype-1.md).

The deny and sandbox paths in `templates/worker-settings.json` are the default folders (`~/.config/herdr-core`, `~/.config/herdr-app`, `~/.local/state/herdr-core`, `~/.config/gh/hosts.yml`, and `~/.local/share/paddock`, the org script and role files, denied for writing only). A JSON settings file cannot expand `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `PADDOCK_BIN_DIR` or `APPDATA`, so with those set to another place the paths do not follow. Not solved here.

`scripts/org` writes under `$PADDOCK_STATE_DIR` (default `~/.local/state/paddock`), and the worker settings allow writing only that default path; with `PADDOCK_STATE_DIR` or `XDG_STATE_HOME` pointing elsewhere, edit `sandbox.filesystem.allowWrite` in your copy of `worker-settings.json`. Not solved here.

The `PADDOCK_*` overrides reach a worker only through the environment of the core. Set them in the login shell that starts the core; setting them for an org-start run against a core that is already running changes only org-start's own check and placement.
