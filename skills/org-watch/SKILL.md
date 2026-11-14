---
name: org-watch
description: The watcher that tells the person, outside the herdr-app window, when an approval card waits, when the secretary has stopped moving while a worker is blocked, or when a terminal never reported a status. A resident script org-start runs as the kept terminal named watcher; org-down ends it. Read-only; the channel is a desktop toast with sound, else notify-send, else a terminal bell.
---

# org-watch

A shell loop that tells the person what the window cannot, because the window is closed or the secretary is the one not moving. Why it is built this way: [references/rationale.md](references/rationale.md).

```sh
bash skills/org-watch/scripts/org-watch.sh [--once]
```

org-start runs it as `hc run --bg --keep --name watcher`; run by hand with `--once` to see one pass.

## What it tells

Each item once, and again after N minutes (default 10, `PADDOCK_WATCH_N`) if it is still waiting. One ledger, `watcher/told` in the state folder, holds "key, last told"; an item that stops waiting is dropped from it.

| Item | Condition | Message |
| --- | --- | --- |
| Approval card | an entry in `org-state.approvals` | "Approval waiting: <task>" and the question |
| Incident | a worker is `blocked` and the secretary's status, `turn` count and screen (`hc read --lines 0`) have not changed for N minutes | "Secretary not moving" |
| No status | a terminal with a `task_id` label, or the secretary, reports no status N minutes after it was created | "No status from <terminal>" |

It polls every 30 seconds (`PADDOCK_WATCH_INTERVAL`) and only reads: `hc ls`, `hc get`, `hc read` and the org-state document through `scripts/org`. It types into nothing.

## Channel

The first that works, per message:

1. Windows toast with the system sound, through `powershell.exe` (WSL). The script goes in on stdin and the text in environment variables, so a question with quotes or shell syntax is never run. A kept terminal's PATH lacks `/mnt/c`, so the default path `/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe` is tried when the name is not found (`PADDOCK_POWERSHELL` names another).
2. `notify-send` (Linux desktop with a notification daemon).
3. The terminal bell, plus the message on the watcher's terminal. Always printed, whatever channel worked.

## Exit codes

0 done, 2 bad argument, 3 `hc` not found, 5 core unreachable (`--once` only; the loop logs it and tries again).

## Not covered

- A stopped core stops the watcher with it, and nothing says so.
- The first-message-not-sent case of a launch is not visible to `hc get`; the N-minute no-status rule catches that terminal later.
- A watcher started during a freeze waits N minutes before telling, since "unchanged" is what it saw itself.
- Measured on the host (WSL2, powershell.exe 5.1): toasts from the person's shell and from a kept terminal by the absolute path reached the Windows notification centre (shown as from Windows PowerShell); by name from the kept terminal it was not found. Not confirmed: whether the sound played. Not measured: a long run, or a core with many terminals ([probe](../../scripts/probes/toast-from-kept-terminal.sh)).
