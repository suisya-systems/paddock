---
name: org-suspend
description: Record the organization's state before a pause. Saves the org-state document, the terminals that carry a task_id label, and each worker's worktree git state; leaves every terminal alive. Run it from your own login shell.
---

# org-suspend

Implements inventory row [SUS-1](../../docs/design/predecessor-inventory.md). Run it from the person's login shell (or a service), never from inside an agent.

```sh
bash skills/org-suspend/scripts/org-suspend.sh
```

Bash only, like [org-start](../org-start/SKILL.md).

## What it does

1. Refuses (exit 4) inside an agent, as `org-start` does ([Q17](../../docs/design/open-questions.md#q17-what-environment-do-the-core-and-its-terminals-start-with)).
2. Lists the terminals with `hc ls --json` and keeps those whose `hc get --json` shows a `task_id` label. The secretary and every unlabelled terminal are left out.
3. Reads the `org-state` document with `doc.get` through `hc connect` ([decision 0004](../../docs/decisions/0004-records-documents-and-jsonl.md)).
4. For each `work` entry that has a `worktree`, records the git `HEAD` and the number of uncommitted files (`missing` when the folder is not a repository).
5. Writes one local file, `suspend.record`, replacing the last one: `$PADDOCK_STATE_DIR`, else `${XDG_STATE_HOME:-~/.local/state}/paddock`.

It ends nothing, starts nothing, sends nothing into any agent ([decision 0002](../../docs/decisions/0002-org-mailbox-not-hc-send.md): no `SUSPEND:` message, no `hc send`), and never runs `hc server stop` or `restart`. Terminals keep running with no window open, so suspending is a record, not a stop.

## Assumptions (open points left open)

- The record is a local file, not a core document: [decision 0004](../../docs/decisions/0004-records-documents-and-jsonl.md) fixes the allowed document names, and adding one is a design change this skill does not make.
- `work` entries in `org-state` carry two optional fields beyond [prototype 1](../../docs/design/prototype-1.md#the-org-state-document): `worktree` (path) and `task` (the original task text). [Q4](../../docs/design/open-questions.md#q4-worker-recovery-after-a-core-restart) says the records must hold them; where the secretary writes them is for the secretary template to settle. Without them `org-resume` cannot relaunch that worker.
- The shape of `hc ls --json` and of the `labels` and `status` objects in `hc get --json` is taken from the `org-agents` mod's code and the other skills, not measured here.

- Known limit: the entries of `work` are cut out with a scan that skips string contents (Issue #182), so braces, brackets and commas in a `task` or `title` survive; the fields are then read with sed, which assumes flat entries. Quotes and backslashes survive, as do `\n`, `\t` and `\r` (org-resume decodes them); Unicode (`\uXXXX`) escapes are kept as written, and a work entry that cannot be read makes the suspend fail rather than be dropped.

## Exit codes

0 recorded, 2 bad argument, 3 `hc` not found, 4 run inside an agent, 5 core unreachable or the record could not be written.

## Not measured

Everything is tested only against a stubbed `hc` (`tests/org-suspend.test.sh`); no real core ran.
