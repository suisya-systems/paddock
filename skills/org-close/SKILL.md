---
name: org-close
description: End a finished or failed worker in one call. Checks the worker's done record in the mailbox and its task_id label, then hc kill, hc rm and removes the work entry; --drop also removes the worktree and the unused branch. Run it from the secretary.
---

# org-close

Implements row 7 of [routine procedures](../../docs/design/routine-procedures.md). Run it from the secretary.

```sh
bash skills/org-close/scripts/org-close.sh --task <task_id> [--drop]
```

## What it does

Without `--drop` (the worker finished):

1. Needs a `done` record for the task, written by `w-<task_id>` and addressed to `secretary`. A `done` sent to anyone else does not count, and nothing is ended.
2. Needs the terminal `w-<task_id>` to carry the label `task_id=<task_id>`. A terminal without it, or with another task's label, is never touched.
3. `hc kill`, then `hc rm`, then removes the `work` entry of the task from `org-state` (its `approvals` are left alone).

The worktree and branch stay: [org-pull-request](../org-pull-request/SKILL.md) works from them.

With `--drop` (the work is abandoned, or the launch failed): no report needed. It ends the terminal when there is one (same label rule), removes the worktree under `PADDOCK_WORKERS_DIR` (uncommitted work in it is lost), deletes the branch only when it has no commit beyond its base (`git branch -d`; otherwise the branch is kept and named), and removes the `work` entry. Afterwards the same `task_id` can be delegated again.

## Exit codes

0 closed, 2 bad argument, 3 `hc` not found, 5 core or `org-state` error (or `hc kill` / `hc rm` failed), 6 no done record addressed to secretary, 7 the terminal does not carry the task's label, 8 the worktree could not be removed.

## Known limits

- The `work` entries of `org-state` are cut out with a scan that skips string contents, so a `]` or a brace inside a task or title does not end an entry (Issue #182); the entries are flat objects, like [org-suspend](../org-suspend/SKILL.md).
- `git branch -d` keeps an unused branch when the project's `HEAD` is not at or past the branch's base.

## Not measured

Tested only against a stubbed `hc` (`tests/org-close.test.sh`); no real core ran.
