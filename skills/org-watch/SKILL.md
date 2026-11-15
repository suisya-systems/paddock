---
name: org-watch
description: The watcher that tells the person, outside the herdr-app window, when an approval card waits, when the secretary has stopped moving while a worker is blocked, or when a terminal never reported a status; and (decision 0013, stage 1) writes worker events into the secretary's mailbox as watcher, wakes an idle or done secretary or worker that has unread mail with one constant line, and watches CI for each ci_requested record. A resident script org-start runs as the kept terminal named watcher; org-down ends it. The person's channel is a desktop toast with sound, else notify-send, else a terminal bell.
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

It polls every 30 seconds (`PADDOCK_WATCH_INTERVAL`) and reads `hc ls`, `hc get`, `hc read`, the org-state document and the mailbox history through `scripts/org`. What it writes and types is below (decision 0013 (`docs/decisions/0013-watcher-wakes-the-secretary.md`), stage 1 "Beside": the secretary's `org wait`, its `Stop` hook and the per-write nudge still run as before).

## What it writes to the secretary's mailbox

Each item is one line, written with `scripts/org --as watcher send_message secretary`, once while it holds (ledger key `mail:<kind>:<terminal>` in `watcher/told`, dropped when it stops being true, so it is written again if it comes back). Each states a recorded fact and nothing else.

| Item | Condition | Line |
| --- | --- | --- |
| Blocked worker | a `task_id` terminal's status is `blocked` | `w-<task> is blocked` |
| Done without a report | `org work_check`'s `unreported`: status `done`, no `run_completed` since the latest `run_started` | `w-<task> is done and sent no report` |
| Worker gone | `org work_check`'s `gone`: an `org-state.work` task whose terminal is not found or `finished`, with no done record | `w-<task> has no terminal and sent no done report` |
| No status | a `task_id` terminal with no status N minutes after it was created | `w-<task> has reported no status for N minutes` |
| CI result | its own CI watch ended (below) | `CI <success\|failure> on PR <n>, head <sha7>, run <id>.` or `CI watch failed on PR <n>, head <sha7>: <reason> (log <path>).` |

`org work_check` is the worker check of `org wait` (moved out of it, not copied), run as `watcher`.

## The wake

The secretary and every `w-<task>` worker with a live terminal and unread mail (`check_messages --peek` as that id) are sent one constant line: `You have mail: run bash scripts/org --as secretary check_messages and act on it.` for the secretary, `You have mail: run bash "$PADDOCK_ORG" --as w-<task> check_messages and act on it.` for a worker. No text from a worker or a person is ever typed.

- Only on an exact status: `idle` with `hc send --if idle`; `done` (read with `hc get`, since hc has no `--if done`) with a plain `hc send`. `working`, `blocked`, no status or not found: nothing this pass.
- Never over typed input: just before a send it reads the last screen line once (`hc read --lines 1`); a line that holds text after the prompt marker (`❯` or `>`, inside an optional box) holds the wake off for that pass.
- One wake per unread batch (the highest unread `seq` per sender) per `PADDOCK_WATCH_WAKE` seconds (default 60); new mail is a new batch. A failed send is tried again on the next pass.
- Every wake, every skip (status, typed input, rate limit) and every mailbox line is printed and appended to `watcher/woke` in the state folder, one tab-separated line: time (epoch), `wake`/`skip`/`mail`, target, batch or ledger key, status read, typed input (`yes`/`no`/`-`), send exit code (`rate` for a rate-limit skip, `-` when nothing was sent).

## CI watching

`org-pull-request` appends `ci_requested` (`scripts/org --as secretary ci_requested --pr N --sha SHA --repo OWNER/NAME [--task ID]`). Each pass, a request is open while no `ci_completed` or `ci_watch_failed` of the watcher for the same `pr` and `sha` is at or after it (stage 1: the skill's own `ci_completed` does not close it, so each head gets both results). For the newest open request of each PR with no live watch, it starts `scripts/ci-watch.sh --pr N --sha SHA --repo R [--task ID]` in the background of its own shell; the pid and head go to `watcher/ci/<pr>.pid`, the output to `watcher/ci/<pr>-<sha7>.log`.

`ci-watch.sh` finds the run of the head (`gh run list --commit`, `PADDOCK_RUN_TRIES` / `PADDOCK_RUN_SLEEP` as in org-pull-request), runs `gh run watch <run> --exit-status --interval 30`, then reads the conclusion (`gh run view --json conclusion`). Whatever ends it, it writes one record as watcher and one mailbox line: `ci_completed` (`success` or `failure`), else `ci_watch_failed` with `reason` `no_run`, `gh_error` (a `gh` call failed, or no conclusion), `signal` (HUP, INT, TERM) or `superseded` (a newer request for the PR: the watcher sends it USR1), `exit_code` and `log`. A watch that died with no chance to trap (SIGKILL) is written `vanished` by the next pass; an older request never watched before a newer one came is written `superseded` by the pass. Example: `{"seq":3,"ts":"...","kind":"ci_watch_failed","from":"watcher","task_id":"t1","pr":42,"sha":"<head>","reason":"no_run","exit_code":0,"log":"<state>/watcher/ci/42-0123456.log"}`. The watcher never merges.

## Channel

The first that works, per message:

1. Windows toast with the system sound, through `powershell.exe` (WSL). When Windows reports notifications disabled for it (`Setting` is not `Enabled`) the toast counts as failed and the next channel runs. The script goes in on stdin and the text in environment variables, so a question with quotes or shell syntax is never run. A kept terminal's PATH lacks `/mnt/c`, so the default path `/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe` is tried when the name is not found (`PADDOCK_POWERSHELL` names another).
2. `notify-send` (Linux desktop with a notification daemon).
3. The terminal bell, plus the message on the watcher's terminal. Always printed, whatever channel worked.

## Exit codes

0 done, 2 bad argument, 3 `hc` not found, 5 core unreachable (`--once` only; the loop logs it and tries again).
`ci-watch.sh`: 0 a result recorded, 1 `ci_watch_failed` recorded, 2 bad argument, 129/130/143/138 ended by HUP/INT/TERM/USR1 (`ci_watch_failed` recorded).

## Not covered

- A stopped core stops the watcher with it, and nothing says so. With it stop the wakes and the CI watches; open requests are watched again when it is back (a result late, not lost).
- Not measured on a host (decision 0013, stage 2): whether `hc send` to a `done` secretary lands, the last screen line of a real Claude Code prompt (the typed-input check is built on the `❯` marker the repository already reads), `gh` on the kept terminal's PATH and login, a real `gh run watch` and its signals. Tested against stubbed `hc` and `gh` (`tests/org-watch-wake.test.sh`).
- The first-message-not-sent case of a launch is not visible to `hc get`; the N-minute no-status rule catches that terminal later.
- A watcher started during a freeze waits N minutes before telling, since "unchanged" is what it saw itself.
- Measured on the host (WSL2, powershell.exe 5.1): toasts from the person's shell and from a kept terminal by the absolute path reached the Windows notification centre (shown as from Windows PowerShell); by name from the kept terminal it was not found. Not confirmed: whether the sound played. Not measured: a long run, or a core with many terminals (`scripts/probes/toast-from-kept-terminal.sh`).
