---
name: org-start
description: Start the paddock organization. Reuses the herdr core, starts the secretary from templates/secretary.md with --keep, places the org-agents mod, and reports readiness. --place-only places the files again and starts nothing.
when_to_use: The person starts the organization from their own login shell, checks first-run setup (--check), or a landing changed a placed file and the files must be placed again (--place-only --from-origin main, which prints the renewal and skill changed lines).
disable-model-invocation: true
---

# org-start

Starts the organization. Why it is built this way: [references/rationale.md](references/rationale.md). Run this from the person's login shell (or a service). Never from inside an agent, except `--place-only` (below), which starts nothing.

```sh
bash skills/org-start/scripts/org-start.sh
```

The steps it runs (notes check, core, templates, mods and layout, secretary, watcher, readiness, folder trust), the folders it uses and its known limits are in [references/details.md](references/details.md).

Bash only. There is no `.ps1` yet: the pwsh path could not be tested, so it is not shipped. On Windows, run it inside WSL2: core and agents run only there. Native Windows (Git Bash) is not supported for the core or agents.

## Place again (`--place-only`)

`bash skills/org-start/scripts/org-start.sh --place-only [--from-origin BRANCH]` (the secretary: `bash "$PADDOCK_HOME/skills/org-start/scripts/org-start.sh" --place-only ...`) does step 2 and the file copies of step 3 and nothing else: no `hc` call (so no core starts), no secretary, no watcher, no `herdr-app` command (no `mod.clone`, `check` or `layout.switch`). It skips the agent check, the notes and core-PATH checks, and keeps the `claude-path` and `codex-path` an earlier run recorded. So the secretary may run it after a landing that changed a placed file; nobody reruns org-start from a login shell for that. With `--from-origin BRANCH` it runs `git fetch origin BRANCH` in the paddock folder and places the files of `origin/BRANCH` (by `git archive`), not the checkout, which a landing does not update. Then it fast-forwards the paddock checkout to `origin/BRANCH` (`git merge --ff-only`) when that checkout is clean (no tracked changes), on `BRANCH`, and behind; when it is not (dirty, another branch, diverged, or the merge fails) it leaves it alone and prints one `left alone` line with why and the command to run. That is not a failure: the placing still exits 0. So `org-delegate` and the secretary's own scripts use the landed commit with nobody typing. [org-pull-request](../org-pull-request/SKILL.md) runs it after its own merge in the paddock repository; after a merge by hand the secretary runs `--place-only --from-origin main`.

It prints the placed template and bin files that changed (or `nothing changed`) and what each needs. When the fast-forward changed a `SKILL.md`, it also prints one `skill changed: paddock:<name> (invoke it again before you use it)` line per skill and one line saying the watcher types `/reload-plugins` (a running secretary serves the text it loaded until then, decision 0014 part 4). It leaves an empty marker `watcher/reload-plugins` in the state folder; the watcher ([org-watch](../org-watch/SKILL.md)) types `/reload-plugins` into the secretary once it is idle, clears the marker on the `Reloaded:` line, and tells the person outside the window when none shows N minutes later. Nobody is asked to type it:

- The bin copies (`org`, which workers run as `PADDOCK_ORG`, the review gate, the hook scripts) and `secretary-settings.json`: in effect at once. A script is read on each run, and Claude Code re-reads the hooks of a settings file that changed, so no restart is needed. The secretary's own `scripts/org` and skill scripts run from the paddock folder's checkout, which `--from-origin` fast-forwards (see above).
- `worker.md`, `worker-rules.md`, `worker-settings.json`, `curator.md`: they reach new workers or a new curator fully only once the paddock folder's checkout is at the landed commit too (`--from-origin` fast-forwards it; a `left alone` line says when it did not and what to run), because org-delegate builds each worker's settings from that checkout's `templates/worker-settings.json` and resends the checkout's `worker.md` after a folder-trust dialog. Running ones keep the old ones.
- `secretary.md`: a template body reaches only a new secretary. It then prints a `RENEWAL NEEDED: ...` line as soon as that file is copied (so a failed later copy cannot hide it), and the secretary asks the person to renew it (`secretary-handover`).

Exit 0 placed, 2 bad argument, 6 a file could not be placed or the fetch failed.

## First-run check (`--check`, decision 0007)

First-run setup is a person's one-time job per machine, outside the round (G1 covers a round only). `bash skills/org-start/scripts/org-start.sh --check [--project DIR]...` is the one command that lists what is left. It prints `ok <step>: ...` or `TODO <step>: <exact fix>` for every step (hc, agent-shell, claude, notes, core-path, trust for each `--project` clone, and mods: the herdr-app mods folder org-start places into and whether its cockpit equals the checkout; a differing cockpit or an undeterminable folder is a TODO), and `skip core-path: <why>` when there is no core yet or `/proc` is not readable. It is read-only: no hc call, nothing placed, no secretary; it never writes the core's config and never restarts the core. Exit 0 only when no TODO is left, 1 otherwise, 2 for a bad argument. A clean host reaches `org-start: ready` after the person's actions, with `--check` clean: `notes = false` in the core config, the core started from a login shell that has hc's folder on PATH, and each project clone trusted once with `claude`.

The core PATH check reads `/proc/<core pid>/environ` of the running core, not the PATH of the shell that runs org-start (the Run 6 case). Linux and WSL only: elsewhere the normal run skips it silently and `--check` says so. The checks live in `first-run-checks.sh` and are shared with `prototype-3.sh prepare` and `prototype-3-setup.sh`.

## Exit codes

0 ready, 2 bad argument, 3 `hc` not found, 4 run inside an agent, 5 core unreachable or `hc run` failed, 6 files could not be placed, 7 no status yet (the message gives the terminal's exit code and last output line, and names a missing `claude`), 8 the core's notes are not off, 9 `claude` not found from org-start's shell (its absolute path is recorded in `claude-path` beside the org script, and the templates start it by that path; the same is done for `codex` in `codex-path`, resolved to a stable folder (never one under fnm's `fnm_multishells`), which the review gate runs before any codex on its PATH; org-start warns when two different codex installs are on PATH), 10 `hc` is not on the running core's PATH (restart herdr from a login shell that has it).

## After it runs

A host probe checks that `env` inside the secretary has no `CLAUDE_CODE_CHILD_SESSION`. The script does not check that itself.

