---
name: secretary-handover
description: Renew the secretary's context. The secretary writes the secretary-handover document and tells the person; the person's script reads it, ends the old secretary terminal and launches a fresh secretary from its template with "resume from the handover" as the task.
when_to_use: Your context is getting full, or the person asks you to renew yourself, and you are at the end of a turn with nothing half done (the writing half, yours). Running the script is the person's, from their own shell.
---

# secretary-handover

Renews the secretary's context from a handover document. Why it is built this way: [references/rationale.md](references/rationale.md). Run it from the person's login shell (or a service). Never from inside an agent, and never typed into the secretary.

```sh
bash skills/secretary-handover/scripts/secretary-handover.sh
```

Bash only, like [org-start](../org-start/SKILL.md).

## The two halves

1. **The secretary writes the handover document** when its context is getting full or the person asks, at the end of a turn with nothing half done, then tells the person it is ready. The secretary never ends its own terminal and never runs the script; nothing is typed into it.
2. **This script** runs outside the secretary and does the renewal.

### The writing half (the secretary)

You renew yourself by handover, not by clearing your own context.

- Write the core document with `bash scripts/org --as secretary doc set secretary-handover`, as for `org-state`. Replace the whole value each time. Keep it under 32 KiB.
- Write only what `org-state` and the mailbox do not already hold: `last_exchange` (the last thing the person asked and what you answered, and what they are waiting for), `unrecorded_decisions` (decisions made in this conversation that no record has yet), `open_threads` (per worker `task_id`: what you asked or promised it, what you expect back), and `written_at` (UTC, ISO 8601).
- Then tell the person the handover is ready and that `bash skills/secretary-handover/scripts/secretary-handover.sh` renews you: they (or a service) run it from outside; it ends your terminal and starts a fresh secretary.

The fresh secretary's task text carries the resume steps: read `secretary-handover` and `org-state`, find the running workers by their `task_id` label (`hc ls`), take up the open threads, check the mailbox, clear the handover (`echo null | bash scripts/org --as secretary doc set secretary-handover`), and tell the person it is back.

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
