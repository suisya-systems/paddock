---
name: org-delegate
description: Delegate one task to a new worker. Creates a git worktree under the trusted workers folder, writes the per-task Claude Code settings file into it, starts the worker from the worker template with hc run --bg and a task_id label, and records the start. Run it from the secretary.
---

# org-delegate

Implements inventory row [SK-3](../../docs/design/predecessor-inventory.md) and Issue #62. The secretary runs it once per task, from a shell in its own terminal (unlike [org-start](../org-start/SKILL.md), it is meant to run inside an agent).

```sh
bash skills/org-delegate/scripts/org-delegate.sh \
  --project <git repository> --task-id <id> --task "<task text>" \
  [--base main] [--branch work/<id>] [--allow-write <path>]...
```

`--task-file <file>` (or `-` for stdin) replaces `--task` for a long text. Bash only, plus `git` and `hc`.

## What it does

1. **Checks before it creates anything.** The arguments, `hc ls` (the core answers), and that no terminal named `w-<id>` exists (exit 7). A `task_id` is lowercase letters, digits, `_` and `-`, not starting with `-`, at most 30 characters.
2. **Worktree.** `git -C <project> worktree add -b <branch> $PADDOCK_WORKERS_DIR/<id> <base>`. The workers folder (default `~/paddock-workers`; `PADDOCK_WORKERS_DIR` must be an absolute path, else exit 2) is the one folder trusted once per machine ([Q13](../../docs/design/open-questions.md#q13-how-does-a-new-worktree-get-past-claude-codes-folder-trust-dialog), decided (b)); measured once (hc 0.1.18, Claude Code 2.1.322; [#133](https://github.com/suisya-systems/paddock/issues/133)), with that folder trusted a worktree of a fresh scratch repository still raised the dialog while a worktree of an already trusted clone did not, so trust appears to follow the project the worktree belongs to, not the folder it sits in; the script checks the worktree landed directly inside it, and refuses a path that already exists (exit 6).
3. **Settings.** Writes `<worktree>/.claude/settings.local.json` with `hc file write` ([probe P1](../../docs/design/predecessor-inventory.md)): `{"sandbox":{"filesystem":{"denyRead":[<socket folder>],"denyWrite":[<socket folder>]}}}`, plus `allowWrite` with `--allow-write` paths. The socket folder is the core's (`$XDG_RUNTIME_DIR/herdr-core` on Linux; L-N2, [#155](https://github.com/suisya-systems/paddock/issues/155)): per user, so the shared settings file cannot name it; it is `PADDOCK_CORE_SOCKET_DIR`, else the folder of `$HC_TERMINAL_SOCKET`, and with neither the script stops before creating anything (exit 2). This also applies to every probe that calls org-delegate: run one from outside a core terminal with `PADDOCK_CORE_SOCKET_DIR="$XDG_RUNTIME_DIR/herdr-core"` (Linux). Only what changes per task or per user goes here; the role's deny list, sandbox and hooks come from the worker template's `--settings` file ([Q10](../../docs/design/open-questions.md#q10-who-distributes-permissions-hooks-and-skills-and-when), decided (b) plus (a)). It refuses (exit 6, worktree removed) when the base tracks a `.claude` symlink or a `settings.local.json`: nothing is written through a symlink and no file is overwritten.
4. **Record.** `bash scripts/org --as secretary report start --task <id> --to secretary "Delegating to w-<id> ..."`, written before the launch so that the worker's own later `done` or `blocked` is the latest record in `list_runs` and is not hidden by this one. If it cannot be written, nothing is started (exit 12). A failure after this point that leaves no worker appends a `blocked` record.
5. **Launch.** `hc run --bg --outlive-parent --name w-<id> --cwd <worktree> --label task_id=<id> worker "<text>"`. The text is `Your org id is w-<id>. Your task id is <id>.` and a blank line, then the task. The task travels in the launch, so nothing is typed into the worker afterwards. If `hc run` fails, the request may still have been accepted: the worktree and branch are removed only when `hc get w-<id>` answers `not_found`; otherwise everything is kept and the terminal, worktree and branch are named (exit 5).
6. **First message.** `first_message.sent` must be `true`; a missing or unreadable answer counts as not sent. If not (exit 10), the script prints the result and leaves the worktree and terminal as they are. It presses no keys and kills nothing ([Q13](../../docs/design/open-questions.md#q13-how-does-a-new-worktree-get-past-claude-codes-folder-trust-dialog); raising it as an incident on the screen is a follow-up named in [Q3](../../docs/design/open-questions.md)). Read the worker with `hc read w-<id>`.

It prints `org-delegate: worker=w-<id> worktree=<path> branch=<branch>` on success.

## What it does not do

- **No `AGENTS.md`, no `CLAUDE.md`, no rules file in the worktree.** The role rules are `templates/worker-rules.md`, passed by the template with `--append-system-prompt-file`; the task is the launch's text ([Q12](../../docs/design/open-questions.md#q12-where-do-a-workers-role-rules-and-task-brief-live), decided). Writing `AGENTS.md` would collide with a target repository's own files.
- **No token.** The worker template sets `GH_CONFIG_DIR` and the read-only `GH_TOKEN` itself ([Q20](../../docs/design/open-questions.md#q20-how-is-a-workers-github-access-held-to-read-only)). The script never reads or passes a token, and the task text must not hold one.
- **No `org-state` entry.** The secretary adds the `work` entry itself, as its template says.
- **No fetch of the base.** Run `git fetch` in the project first if `--base` should be current. No worker cap and no project registry ([Q14](../../docs/design/open-questions.md#q14-where-do-organization-settings-and-registries-live) is open).
- **No answer to the trust dialog.** The first time a workers folder is used, a person accepts the dialog once in the window (or the secretary answers it once from the screen, never with a blind Enter: the default is "No, exit").

## Exit codes

0 worker running (first message sent) and recorded, 2 bad argument, 3 `hc` or `git` not found, 5 core unreachable or `hc` failed (the new worktree and branch are removed when no worker can exist, so the same `task_id` can be tried again; if the terminal may exist they are kept and named; a removal that fails is named too), 6 project, base, worktree path or settings path problem (the worktree is removed), 7 a terminal `w-<id>` exists, 10 started but the first message was not sent (left as it is), 12 the start record could not be written (nothing was started).

After exit 10, or exit 5 with things kept, the same `task_id` is refused (the terminal, worktree or branch exists). Inspect the worker, then end it with `org-close --task <id> --drop` ([org-close](../org-close/SKILL.md)) before trying again.

## Check it against a real worker

Needs a running core, [org-start](../org-start/SKILL.md) already run, and a workers folder a person has trusted once. Not run by CI, and not measured yet (the probes below are separate issues):

```sh
bash skills/org-delegate/scripts/org-delegate.sh --project <repo> --task-id probe-1 \
  --task "Reply ready, then report done with scripts/org."
hc get w-probe-1          # status reaches working, then done
bash scripts/org --as secretary check_messages
```

Then run the probes of Issues #40, #42 and #43 against `w-probe-1` (the worker this skill started) and note each result in the PR.
