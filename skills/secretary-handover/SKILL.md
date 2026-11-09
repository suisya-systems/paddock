---
name: secretary-handover
description: Renew the secretary's context. Reads the secretary-handover document, ends the old secretary terminal, and launches a fresh secretary from its template with "resume from the handover" as the task. Run it from your own login shell or a service, never from the secretary.
---

# secretary-handover

Implements [Q16](../../docs/design/open-questions.md#q16-how-is-the-secretarys-context-renewed) decision (c). Run it from the person's login shell (or a service). Never from inside an agent, and never typed into the secretary.

```sh
bash skills/secretary-handover/scripts/secretary-handover.sh
```

Bash only, like [org-start](../org-start/SKILL.md).

## The two halves

1. **The secretary writes the handover document** when its context is getting full (the instruction is in [`templates/secretary.md`](../../templates/secretary.md)), then tells the person it is ready. The secretary never ends its own terminal.
2. **This script** runs outside the secretary and does the renewal.

## What the script does

1. Refuses (exit 4) when its own environment shows it runs inside an agent, as `org-start` does ([Q17](../../docs/design/open-questions.md#q17-what-environment-do-the-core-and-its-terminals-start-with)).
2. Reads the core document `secretary-handover` with `doc.get` through `hc connect`. If it was never written or was cleared (a `null` value), exits 9 and ends nothing.
3. If a terminal named `secretary` exists: if `hc get --json` shows its status as `working` or `blocked` (a turn is in progress), exits 8 and ends nothing. Otherwise `hc kill`, then `hc rm`. A missing terminal is fine, so a rerun after a partial failure continues.
4. Runs `hc run --bg --keep --name secretary secretary "<resume from the handover>"`. The task is in the launch ([decision 0002](../../docs/decisions/0002-org-mailbox-not-hc-send.md)). The task text tells the new secretary to read `secretary-handover` and `org-state`, find the running workers by their `task_id` label (`hc ls`), and then clear `secretary-handover`.
5. Checks `first_message.sent` in the result; exits 10 if it is not true, and then you read the screen (`hc read`) before anything else.

Workers are not touched: they were started with `--outlive-parent` ([Q19](../../docs/design/open-questions.md#q19-do-workers-outlive-the-secretary-that-started-them)). It never runs `hc server stop` or `hc server restart`, and never `hc send` or `hc keys`.

## Name

`PADDOCK_SECRETARY_NAME` sets the terminal name (default `secretary`), for the kill, rm and run. The template stays `secretary`. Set the same value for `org-start`.

## Idempotence

The document is cleared by the new secretary once it has resumed, so a second run then exits 9 and ends nothing. A run before it has cleared the document relaunches again from the same document (resuming is repeatable). A run when the old terminal is already gone skips kill and rm.

## Exit codes

0 relaunched, 2 bad argument, 3 `hc` not found, 4 run inside an agent, 5 core unreachable or `hc kill`, `hc rm` or `hc run` failed, 8 a turn is in progress, 9 no handover document, 10 the first message was not sent.

## Not measured

The end-to-end renewal has not run against a real core; the script is tested only against a stubbed `hc` (`tests/secretary-handover.test.sh`). Also unmeasured: the answer shape of `doc.get` as the script reads it (taken from the `org-agents` mod's code), whether `hc run` rejects a name still held by a finished terminal (the script removes it first), and how the old secretary's idle state is known beyond `hc get` status ([Q18](../../docs/design/open-questions.md#q18-how-does-anything-reach-an-idle-agent)).
