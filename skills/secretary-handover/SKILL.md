---
name: secretary-handover
description: Renew the secretary's context. The secretary writes the secretary-handover document and leaves a renewal request (scripts/org renew_secretary); the watcher runs the script, which reads the document, ends the old secretary terminal and launches a fresh secretary from its template with "resume from the handover" as the task.
when_to_use: Your context is getting full, or the person asks you to renew yourself, and you are at the end of a turn with nothing half done (the writing half and the request, yours). Running the script is the watcher's, or the person's from their own shell when the watcher cannot.
---

# secretary-handover

Renews the secretary's context from a handover document. Why it is built this way: [references/rationale.md](references/rationale.md). The watcher ([org-watch](../org-watch/SKILL.md)) runs it when the secretary asks; the person can still run it from their login shell (or a service). Never from inside an agent, and never typed into the secretary.

```sh
bash <paddock folder>/skills/secretary-handover/scripts/secretary-handover.sh   # the folder: echo "$PADDOCK_HOME"
```

Bash only, like [org-start](../org-start/SKILL.md).

## The two halves

1. **The secretary writes the handover document** when its context is getting full or the person asks, at the end of a turn with nothing half done, then leaves a renewal request and ends its turn. The secretary never ends its own terminal and never runs the script; nothing is typed into it.
2. **This script** runs outside the secretary and does the renewal: the watcher runs it once the secretary is idle; the person runs it when the watcher cannot.

### The writing half (the secretary)

You renew yourself by handover, not by clearing your own context.

- Write the core document with `bash "$PADDOCK_HOME/scripts/org" --as secretary doc set secretary-handover`, as for `org-state`. Replace the whole value each time. Keep it under 32 KiB.
- Write only what `org-state` and the mailbox do not already hold: `last_exchange` (the last thing the person asked and what you answered, and what they are waiting for), `unrecorded_decisions` (decisions made in this conversation that no record has yet), `open_threads` (per worker `task_id`: what you asked or promised it, what you expect back), and `written_at` (UTC, ISO 8601).
- Then, as the last call of the turn, leave the request: `bash "$PADDOCK_HOME/scripts/org" --as secretary renew_secretary`. It writes the marker `watcher/renew-secretary` (a new request id) in the state folder and types into nothing. Tell the person in one line that you are being renewed, and end the turn.
- If it says no watcher was seen, tell the person to run `bash <paddock folder>/skills/secretary-handover/scripts/secretary-handover.sh` from their own shell, with the folder written out (`echo "$PADDOCK_HOME"` gives it).

The fresh secretary's task text carries the resume steps: read `secretary-handover` and `org-state`, find the running workers by their `task_id` label (`hc ls`), take up the open threads, check the mailbox, clear the handover (`echo null | bash "$PADDOCK_HOME/scripts/org" --as secretary doc set secretary-handover`), and tell the person it is back.

## Who runs the script

- **The watcher**, on the marker: once the secretary is `idle` or `done` (read fresh with `hc get`; a `done` read again just before, same turn) with no typed input on its prompt, as for a wake. `working`, `blocked`, no status or an unreadable status or screen: not this pass. It runs the script from its own environment (org-start started it from the person's login shell; nothing is unset, so the agent check below still holds) and logs the run as `renew` in `watcher/woke`, the output in `watcher/renew.log`. Exit 0: the marker is cleared. Exit 8 (a turn began, or input was typed, after its read) or 13 (another run holds the claim, or took this request): the marker waits for the next pass, nobody is told. Exit 9: the marker is cleared, and the person (a toast) and you (a mailbox line) are told. Any other exit: the marker is kept, that request is not run again, and the person is told outside the window with the exit code and the script's last line (again every N minutes while it holds). A new `renew_secretary` is a new request. A request left during a run is dropped with the marker.
- **The person**, by hand, when the watcher told them a renewal failed, or no watcher runs. A run that ends with exit 0 also clears the marker.

## What the script does

1. Refuses (exit 4) when its own environment shows it runs inside an agent, as `org-start` does.
   It then claims the run: `<state>/watcher/renew.claim` holding its pid, created with noclobber, removed on exit. A claim held by a live run refuses with exit 13 (a dead holder's is broken), so the watcher's run and a hand run never overlap. With `PADDOCK_RENEW_ID` (the watcher's request id) it also exits 13 when `watcher/renew-secretary` no longer holds that id.
2. Reads the core document `secretary-handover` with `doc.get` through `hc connect`. If it was never written or was cleared (a `null` value), exits 9 and ends nothing.
3. Reads `hc get --json secretary` once. If the status is not `idle` or `done` (a turn in progress, or no status), exits 8 and ends nothing. Then it reads the screen (`hc read`) last before the kill: typed input on the prompt line, or no prompt line, exits 8 (the person's draft is never lost); an unreadable screen exits 11. If the read fails, or the output has no `state`, exits 11 and ends nothing: an unreadable status is never taken as idle. Otherwise `hc kill`, then `hc rm`. Only a `not_found` answer means the terminal is gone, so a rerun after a partial failure continues.
4. Refuses (exit 12, nothing ended) when the rules `org-start` places are missing from `<state>/secretary` (`AGENTS.md`, `CLAUDE.md`). Runs `hc run --bg --keep --name secretary --cwd <state>/secretary secretary "<resume from the handover>"` (the secretary's own folder, whatever folder you ran from; its tools are found through `PADDOCK_HOME`, which the template's command sets). The task is in the launch ([decision 0002](../../docs/decisions/0002-org-mailbox-not-hc-send.md)). The task text tells the new secretary to read `secretary-handover` and `org-state`, find the running workers by their `task_id` label (`hc ls`), and then clear `secretary-handover`.
5. Checks `first_message.sent` in the result. If it is not true because the folder-trust dialog of `<state>/secretary` stopped the new secretary, it answers the dialog once (Yes, checked on the screen first, the same `trust-dialog.sh` as `org-start`), waits for a status (`PADDOCK_READY_TRIES`, default 15 s) and sends the template body and the task again. Otherwise it exits 10, and then you read the screen (`hc read`) before anything else.
6. On exit 0, removes the marker `<state>/watcher/renew-secretary`: the request is fulfilled, whoever ran it.

Workers are not touched: they were started with `--outlive-parent`. It never runs `hc server stop` or `hc server restart`, and never `hc send` or `hc keys` except to answer that trust dialog and resend the first message.

## Name

`PADDOCK_SECRETARY_NAME` sets the terminal name (default `secretary`), for the kill, rm and run. The template stays `secretary`. The script supports it now; `org-start` does not honour it until the org-start name override lands, so set it for both only after that.

## Idempotence

The document is cleared by the new secretary once it has resumed, so a second run then exits 9 and ends nothing. A run before it has cleared the document relaunches again from the same document (resuming is repeatable). A run when the old terminal is already gone skips kill and rm.

## Exit codes

0 relaunched, 2 bad argument, 3 `hc` not found, 4 run inside an agent, 5 core unreachable or `hc kill`, `hc rm` or `hc run` failed, 8 a turn is in progress, 9 no handover document, 10 the first message was not sent, 11 the secretary's status could not be read, 12 the secretary's rules are not placed, 13 another renewal holds the claim or the watcher's request is gone.

## Not measured

The watcher-run renewal is tested against a stubbed `hc` only (`tests/org-watch-renew.test.sh`); not yet run by a real watcher against a real secretary. Measured 2026-11-10 end to end against a real core and a real Claude Code secretary (`scripts/probes/secretary-renewal.sh`): exit 0, a different terminal under the same name, the document cleared by the new secretary, the worker untouched. The `doc.get` answer shape the script reads matched. Still unmeasured: the layout re-adopting the new secretary (no herdr-app was attached), whether `hc run` rejects a name still held by a finished terminal (the script removes it first, and that succeeded), and how the old secretary's idle state is known beyond `hc get` status.
