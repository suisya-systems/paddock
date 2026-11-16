---
name: org-delegate
description: Delegate one task to a new worker. Creates a git worktree under the trusted workers folder, writes the per-task Claude Code settings file into it, starts the worker with hc run --bg and a task_id label, and records the start. With --repo OWNER/NAME it first clones a repository that is not on the machine.
when_to_use: A task is ready to hand to a worker (also when the request names a repository not in projects.md and not on the machine, or names no repository at all), a worker started but did not get its first message, or a worker sends "base is stale". Run it from the secretary, never by hand-made worktrees or hc run.
---

# org-delegate

Starts one worker for one task. Why it is built this way, and the measurements behind it: [references/rationale.md](references/rationale.md). The secretary runs it once per task, from a shell in its own terminal (unlike [org-start](../org-start/SKILL.md), it is meant to run inside an agent). Flags, exit codes and what to do after each are in `--help` and in the `next:` line that ends every non-zero exit: do what that line says.

```sh
bash "$PADDOCK_HOME/skills/org-delegate/scripts/org-delegate.sh" \
  --project <git repository or projects.md name> --task-id <id> --title "<a few words>" --task "<task text>" \
  [--task-file <file>] [--base main] [--branch work/<id>] [--allow-write <path>]... [--model <id>]
bash "$PADDOCK_HOME/skills/org-delegate/scripts/org-delegate.sh" --repo OWNER/NAME --task-id <id> --title "..." --task "..."
```

Give the task one worker with an exact scope (what to change, what not to touch, how to report). `--title` adds the `work` entry to `org-state` after the launch, with its `worktree` and `task`; `--task-file <file>` (or `-` for stdin) is for a long text. `--project` may be a name from `projects.md` (the row gives the path and the base; `--base` overrides it), a path, or, with `--repo`, nothing. `--repo OWNER/NAME` (or a github.com URL) clones the repository with the secretary's own login when it is not on the machine, records it in `projects.md`, then delegates into it; a recorded one is reused. A bare name is never guessed: ask the person for `OWNER/NAME`.

`--model <id>` runs the worker on that model, an alias or id such as `fable`, `opus`, `sonnet`, `haiku` or `claude-fable-5-2` (letters, digits and `. _ : [ ] -` only, else exit 2): it goes to the `model` key of the worker's own `--settings` file, and the start record and the `work` entry name it. Without it the worker runs on the default model. Use it when the person asks for a model for a task; never type `/model` into a running worker. A host on which `ANTHROPIC_MODEL` is exported overrides it (rationale).

Do not make the worktree or run `hc run` by hand. The script creates the worktree under the trusted workers folder, writes the task's settings file, starts the worker with the task in the launch (`hc run --bg --outlive-parent --name w-<task_id> --label task_id=<task_id> worker ...`, so workers survive your renewal and a new secretary finds them by that label), and records the start. It puts "Your org id is w-<task_id>." in the task for you. A `task_id` is short, lowercase letters, digits, `_` and `-`, at most 30 characters, unique among the tasks in progress.

## What to do with the result

- **Exit 0:** the worker runs. Nothing else to do; `org-watch` tells you when it reports.
- **A non-zero exit:** the message says what happened and the last line, `next: ...`, says what to do. The ones with a judgment in them: 10 (the worker started but did not get its first message): read its screen with `hc read w-<task_id>` and press no keys; at the folder-trust dialog of a fresh clone ask the person (see [org-clone](../org-clone/SKILL.md)); 5 with a terminal, worktree and branch named: the worker may exist, so `hc get w-<task_id>` comes before anything else; 12: nothing was started, fix the cause and run it again; 13: the worker runs but its `work` entry was not written, add it by hand.
- **After exit 10, or exit 5 with things kept,** the same `task_id` is refused (the terminal, worktree or branch exists). Inspect the worker, then end it with `org-close --task <id> --drop` ([org-close](../org-close/SKILL.md)) before trying again.

## A request that names a repository not on the machine

Delegate with `--repo OWNER/NAME`: it clones when needed and stops only at the trust card. Any clone failure ends the run with nothing started (exit 4 no access or not found, 5 network, 6 a folder is in the way, 7 the name is taken: ask for another); report the cause in one sentence and do not delegate. The first worker on a fresh clone stops at the folder-trust dialog, which is not answered automatically: the trust judgment and the card are in [org-clone](../org-clone/SKILL.md).

## A request that names no repository (decision 0010)

Make a repository for the task, then delegate as above (worktree, settings and review-gate base work unchanged, with no `origin`):

```sh
repo=$(bash "$PADDOCK_HOME/skills/org-delegate/scripts/local-repo.sh" --task-id <id>)   # $PADDOCK_LOCAL_DIR/<id>, default ~/paddock-local/<id>
bash "$PADDOCK_HOME/skills/org-delegate/scripts/org-delegate.sh" --project "$repo" --task-id <id> --task "<task text>" --title "<a few words>"
```

`local-repo.sh` runs `git init` on `main` plus one empty commit, one repository per task. A person who wants reuse adds a `projects.md` row and names it; that is the ordinary path. A path that exists is refused (exit 6). Each new repository raises the folder-trust dialog once (the parent folder being trusted is not enough): after exit 10, read the screen with `hc read w-<id>` and ask the person; never a blind Enter, the default is "No, exit".

**Task text for such a task.** Tell the worker: no PR (it has no GitHub access anyway), and its `report done` carries a short summary and the worktree path. Do not accept an `Acceptance-Test:` declaration for it: acceptance mode needs a required CI job and a repository with no CI has none, so it closes in `human` mode whatever `merge_approval_mode` says. The Codex review gate stays (its base is the recorded `main`).

**Close.** Tell the owner the summary and the path. After the owner agrees: `bash "$PADDOCK_HOME/skills/org-close/scripts/merge-local.sh" --task <id>` (fast-forwards the repository's `main`), then [org-close](../org-close/SKILL.md); to throw it away, `org-close --drop`. Never `org-pull-request`. Pushing to a new remote happens only when the owner asks. Folders under `$PADDOCK_LOCAL_DIR` are never cleaned up by paddock.

## A worker says "base is stale"

A worker holds no GitHub credential: its `command` gives it an empty `GH_CONFIG_DIR` and removes the token variables, and it reads the base from the project clone's `origin/*`, which org-delegate fetched at delegate time (`--no-fetch` leaves the base as the last fetch made it). When a worker sends "base is stale", run `git fetch origin` in the project clone (the `--project` folder, from the paddock folder), then answer it with `send_message w-<task_id> <text>` saying `origin/<branch>` is updated; it rebases itself. You do the pushing and the PRs. Never put a token in a task text.

## What the script does

1. **Checks before it creates anything:** the arguments, `hc ls` (the core answers), and that no terminal `w-<id>` exists.
2. **Worktree:** `git fetch origin` when the project has an `origin` and branches from `origin/<base>` when it exists, then `git worktree add` under the workers folder (`PADDOCK_WORKERS_DIR`, default `~/paddock-workers`, an absolute path). The base is recorded for the review gate.
3. **Settings:** the worktree's `.claude/settings.local.json` (socket folder deny, cache env), a `.claude/.gitignore` for what paddock places, and the worker's own `--settings` file in the state folder (own files, `--allow-write` paths, the review gate's two exact calls, and `git add` / `git commit` allowed inside the sandbox).
4. **Record:** `report start` before the launch, so the worker's later `done` or `blocked` is the latest record.
5. **Launch:** `hc run --bg ...` with the task in the launch; `first_message.sent` must be `true`, else exit 10 with the first message (and the `--title` entry) saved for `org-escalation answer` or `bash "$PADDOCK_HOME/skills/org-delegate/scripts/resend.sh" <id>`.
6. **Work entry** (with `--title`): added to `org-state.work` after the first message was sent.

It prints `org-delegate: worker=w-<id> worktree=<path> branch=<branch>` on success. The details of each step (paths, JSON, sandbox behavior, measurements) are in [references/rationale.md](references/rationale.md).

## What it does not do

- **No `AGENTS.md`, no `CLAUDE.md`, no rules file in the worktree.** The role rules are `templates/worker-rules.md`, passed by the template with `--append-system-prompt-file`; the task is the launch's text.
- **No token, no GitHub access for the worker.** The task text must not hold one.
- **No `org-state` entry without `--title`; no worker cap; no answer to the trust dialog** (the person's yes, or the secretary's once from the screen, never a blind Enter).

## Secret block (per project, off by default)

A worker reads everything in its worktree unless the project turns the block on: the `secret-block` column of its row in `projects.md` (or `--secret-block`, which wins) is `on` (`.env`, `.env.*`, `credentials*`, `*.pem`), `off`, or comma-separated patterns that replace those. **What the project loses:** the worker's own programs and tests cannot open the denied files, or the example files, either (only the Read tool can read the examples); secrets have to come from the environment or from files the patterns do not name. The measurements are in the rationale.

## Check it against a real worker

Needs a running core, [org-start](../org-start/SKILL.md) already run, and a workers folder a person has trusted once. Not run by CI:

```sh
bash "$PADDOCK_HOME/skills/org-delegate/scripts/org-delegate.sh" --project <repo> --task-id probe-1 \
  --task "Reply ready, then report done with scripts/org."
hc get w-probe-1          # status reaches working, then done
bash "$PADDOCK_HOME/scripts/org" --as secretary check_messages
```

`--model`, once: add `--model haiku` to the probe above, then `hc read w-probe-1` and read the model in the startup banner (or, as the person, type `/status` in that worker); it should name Haiku.
