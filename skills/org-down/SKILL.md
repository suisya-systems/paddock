---
name: org-down
description: Shut the organization down. Runs org-suspend, then hc kill and hc rm only for terminals that carry a task_id label (and the secretary with --secretary). Never stops the person's core unless --stop-core is given. Run it from your own login shell.
---

# org-down

Implements inventory row [SUS-3](../../docs/design/predecessor-inventory.md) and hold line L-N7 ([#37](https://github.com/suisya-systems/paddock/issues/37)). Run it from the person's login shell, never from inside an agent.

```sh
bash skills/org-down/scripts/org-down.sh [--secretary] [--stop-core]
```

## What it does

1. Runs [org-suspend](../org-suspend/SKILL.md). If that fails, nothing is ended.
2. Finds the terminals with a `task_id` label and runs `hc kill`, then `hc rm`, on each. A terminal without that label is never touched, whatever its name.
3. With `--secretary`, also `hc kill` and `hc rm` the secretary (`PADDOCK_SECRETARY_NAME`, default `secretary`). Without it the secretary stays.
4. After every worker is ended, The 0-byte read-only `config.lock` that Claude Code's sandbox leaves in the clone's shared `.git` when a worker is killed mid-command ([Issue #324](https://github.com/suisya-systems/paddock/issues/324)) is removed, but only if no process has its cwd in the ended worker's worktree (it waits up to `PADDOCK_LOCK_WAIT` seconds, default 10, for a killed command to end), none has it in another linked worktree of the same clone, and the file is a regular, 0-byte, not writable file. Otherwise it stays and the output says why. What was removed is printed and appended to `removed-locks.log` in the state folder. A process whose sandbox still has the clone's `.git` mounted (`/proc/*/mountinfo`), a process of the same user that cannot be inspected, or a caller whose own sandbox has that mount, also keeps it. Without `/proc` nothing is removed. (a worker ended here no longer counts as live.)
5. With `--stop-core`, afterwards runs `hc server stop`. **Without the flag the core is never stopped.** It never runs `hc server restart`, `hc send` or `hc keys`.

## Why the core stays

`hc server stop` ends the person's whole core and every terminal on it, not only paddock's (L-N7). So the default is to clean up only what paddock started. The flag exists for when the person asks for it.

## Assumptions

- A worker whose report has not reached the mailbox ([L-N5](../../docs/design/predecessor-inventory.md)) is still ended: running this script is the person saying so. The secretary template's rule covers the secretary's own `hc kill`.
- The SUS-3 row's "stop the `org` server" has no process to stop yet (no `org` server exists); it is left out until one does.

## Exit codes

0 done, 2 bad argument, 3 `hc` not found, 4 run inside an agent, 5 core unreachable, suspend failed, or `hc kill`/`rm`/`server stop` failed (it stops at the first failure and does not stop the core).

## Not measured

Real `hc kill` and `hc rm` on labelled terminals, and `hc server stop` through this flag, have not run against a core; tested only against a stubbed `hc` (`tests/org-down.test.sh`).
