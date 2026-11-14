---
name: secretary-handover
description: Renew the secretary's context. Reads the secretary-handover document, ends the old secretary terminal, and launches a fresh secretary from its template with "resume from the handover" as the task. Run it from your own login shell or a service, never from the secretary.
---

# secretary-handover

Renews the secretary's context from a handover document. Why it is built this way: [references/rationale.md](references/rationale.md). Run it from the person's login shell (or a service). Never from inside an agent, and never typed into the secretary.

```sh
bash skills/secretary-handover/scripts/secretary-handover.sh
```

Bash only, like [org-start](../org-start/SKILL.md).

## The two halves

1. **The secretary writes the handover document** when its context is getting full (the instruction is in [`templates/secretary.md`](../../templates/secretary.md)), then tells the person it is ready. The secretary never ends its own terminal.
2. **This script** runs outside the secretary and does the renewal.

## What the script does

1. Refuses (exit 4) when its own environment shows it runs inside an agent, as `org-start` does.
2. Reads the core document `secretary-handover` with `doc.get` through `hc connect`. If it was never written or was cleared (a `null` value), exits 9 and ends nothing.
3. Reads `hc get --json secretary` once. If the status is `working` or `blocked` (a turn is in progress), exits 8 and ends nothing. If the read fails, or the output has no `state`, exits 11 and ends nothing: an unreadable status is never taken as idle. Otherwise `hc kill`, then `hc rm`. Only a `not_found` answer means the terminal is gone, so a rerun after a partial failure continues.
4. Runs `hc run --bg --keep --name secretary --cwd <paddock folder> secretary "<resume from the handover>"` (the repository root, so the new secretary finds its tools whatever folder you ran from). The task is in the launch ([decision 0002](../../docs/decisions/0002-org-mailbox-not-hc-send.md)). The task text tells the new secretary to read `secretary-handover` and `org-state`, find the running workers by their `task_id` label (`hc ls`), and then clear `secretary-handover`.
5. Checks `first_message.sent` in the result; exits 10 if it is not true, and then you read the screen (`hc read`) before anything else.

Workers are not touched: they were started with `--outlive-parent`. It never runs `hc server stop` or `hc server restart`, and never `hc send` or `hc keys`.

## Name

`PADDOCK_SECRETARY_NAME` sets the terminal name (default `secretary`), for the kill, rm and run. The template stays `secretary`. The script supports it now; `org-start` does not honour it until the org-start name override lands, so set it for both only after that.

## Idempotence

The document is cleared by the new secretary once it has resumed, so a second run then exits 9 and ends nothing. A run before it has cleared the document relaunches again from the same document (resuming is repeatable). A run when the old terminal is already gone skips kill and rm.

## Exit codes

0 relaunched, 2 bad argument, 3 `hc` not found, 4 run inside an agent, 5 core unreachable or `hc kill`, `hc rm` or `hc run` failed, 8 a turn is in progress, 9 no handover document, 10 the first message was not sent, 11 the secretary's status could not be read.

## Not measured

Measured 2026-11-10 end to end against a real core and a real Claude Code secretary (`scripts/probes/secretary-renewal.sh`): exit 0, a different terminal under the same name, the document cleared by the new secretary, the worker untouched. The `doc.get` answer shape the script reads matched. Still unmeasured: the layout re-adopting the new secretary (no herdr-app was attached), whether `hc run` rejects a name still held by a finished terminal (the script removes it first, and that succeeded), and how the old secretary's idle state is known beyond `hc get` status.
