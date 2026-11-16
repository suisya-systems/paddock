---
name: org-watch
description: The resident watcher. It tells the person (a toast, outside the window) when an approval card waits, the secretary has stopped moving or a terminal never reported; writes worker events into the secretary's mailbox as watcher; wakes an idle secretary or worker that has unread mail; and watches CI for each ci_requested record. org-start runs it as the kept terminal named watcher; org-down ends it.
when_to_use: Mail from watcher arrives (blocked, done with no report, gone, no status, a CI result); you end a turn idle and wait for the wake line; a worker's CI result or "CI watch failed" line arrives; the person asks why nothing woke you or why a toast came.
---

# org-watch

A shell loop that tells the person what the window cannot, because the window is closed or the secretary is the one not moving. Why it is built this way: [references/rationale.md](references/rationale.md).

## For the secretary

- End your turns idle at your prompt. The watcher wakes you: while you are idle or done with unread mail, it types one line into your prompt, `You have mail: run bash "$PADDOCK_HOME/scripts/org" --as secretary check_messages and act on it.` Run `check_messages` and act (an `ANSWER` goes through `org-escalation answer`). It does not type while you work (a `done` status is read again just before the send; a short window remains, decision 0013), nor over a line the person has half typed; mail that came while you worked is announced on its first pass after your turn ends. If the watcher terminal is gone, nothing wakes you: tell the person to rerun `org-start`.
- A job that may take more than a few seconds runs in its own terminal and ends with a line to your mailbox; then end your turn: `hc run --bg -- env PADDOCK_HOME="$PADDOCK_HOME" sh -c '<command>; bash "$PADDOCK_HOME/scripts/org" --as secretary send_message secretary "<job> ended: exit $?"'`. The `env` is needed: a terminal `hc` starts gets the core's environment, not yours.
- Mail from `watcher` is its own: one recorded fact per line (tables below). Read it like a report and decide as usual:
  - `w-<task> is blocked`: run `org-escalation prompt` for it.
  - `w-<task> is done and sent no report`: `hc read` it, then close it or ask it.
  - `w-<task> has no terminal and sent no done report`: look at `hc read w-<task_id>` if it is still there; tell the person.
  - `w-<task> has reported no status for N minutes`: as for gone.
  - `CI success|failure on PR <n> ...` or `CI watch failed on PR <n> ...`: see `org-pull-request`.
- `bash "$PADDOCK_HOME/scripts/org" --as secretary wait --children` is a manual tool, not a rule: it holds until mail, a child terminal's end, the person's typed line or a timeout, and prints one JSON line: `"reason":"mail"`, `"children"`, `"exit"`, `"timeout"`, or `"reason":"message"` when the person typed a line during it (read and answer that line on your next turn). With `"gone"`, `"waiting"`, `"unreported"`, `"unreadable"` or `"watch_error"` read as for the watcher's lines. You need it for nothing; the watcher already does that check.

## Run it

```sh
bash <paddock folder>/skills/org-watch/scripts/org-watch.sh [--once]   # the folder: echo "$PADDOCK_HOME"
```

org-start runs it as `hc run --bg --keep --name watcher`; the person runs it by hand with `--once` to see one pass (give them the path written out).

## What it tells

Each item once, and again after N minutes (default 10, `PADDOCK_WATCH_N`) if it is still waiting. One ledger, `watcher/told` in the state folder, holds "key, last told"; an item that stops waiting is dropped from it.

| Item | Condition | Message |
| --- | --- | --- |
| Approval card | an entry in `org-state.approvals` | "Approval waiting: <task>" and the question |
| Incident | a worker is `blocked` and the secretary's status, `turn` count and screen (`hc read --lines 0`) have not changed for N minutes | "Secretary not moving" |
| No status | a terminal with a `task_id` label, or the secretary, reports no status N minutes after it was created | "No status from <terminal>" |

It polls every 30 seconds (`PADDOCK_WATCH_INTERVAL`) and reads `hc ls`, `hc get`, `hc read`, the org-state document and the mailbox history through `scripts/org`. What it writes and types is below (decision 0013). Since its stage 3 it is the only thing that wakes the secretary or a worker: the secretary holds no wait and has no `Stop` hook, and no write types into a terminal; if this terminal ends, nothing wakes them until `org-start` is rerun. The cockpit's workers rail shows this from the files below, read only: the last pass (the change time of `watcher/told`, rewritten each pass once it exists), the live `watcher/ci/*.pid` watches, the last `wake` lines of `watcher/woke` and the watcher's last mailbox lines, and a warning when this terminal is gone.

## What it writes to the secretary's mailbox

Each item is one line, written with `scripts/org --as watcher send_message secretary`, once while it holds (ledger key `mail:<kind>:<terminal>` in `watcher/told`, dropped when it stops being true, so it is written again if it comes back). Each states a recorded fact and nothing else.

| Item | Condition | Line |
| --- | --- | --- |
| Blocked worker | a `task_id` terminal's status is `blocked` | `w-<task> is blocked` |
| Done without a report | `org work_check`'s `unreported`: status `done`, no `run_completed` since the latest `run_started` | `w-<task> is done and sent no report` |
| Worker gone | `org work_check`'s `gone`: an `org-state.work` task whose terminal is not found or `finished`, with no done record | `w-<task> has no terminal and sent no done report` |
| No status | a `task_id` terminal with no status N minutes after it was created | `w-<task> has reported no status for N minutes` |
| CI result | its own CI watch ended (below) | `CI <success\|failure> on PR <n>, head <sha7>, run <id>. Runs read: <id> <event> <conclusion>, ...` or `CI watch failed on PR <n>, head <sha7>: <reason> (log <path>).` |
| Green PR, no card | N minutes after a green `ci_completed` of a PR's newest head, its task has no card in `org-state.approvals` and is still in `org-state.work` (not landed); once per head | `PR #<n> is green and no card asks about it` |
| Answered card still up | a card in `org-state.approvals` whose `ANSWER <id>` has been in the person's history for N minutes | `answer for <id> arrived; the card is still up` |

`org work_check` is the worker check of `org wait` (moved out of it, not copied), run as `watcher`.

## The wake

The secretary and every `w-<task>` worker with a live terminal and unread mail (`check_messages --peek` as that id) are sent one constant line: `You have mail: run bash "$PADDOCK_HOME/scripts/org" --as secretary check_messages and act on it.` for the secretary, `You have mail: run bash "$PADDOCK_ORG" --as w-<task> check_messages and act on it.` for a worker. No text from a worker or a person is ever typed.

- Only on an exact status: `idle` with `hc send --if idle`; `done` (read with `hc get`, since hc has no `--if done`) with a plain `hc send`, only if one more `hc get` just before it still reads `done` with the same `turn` and `status_ms` (else `moved` in `watcher/woke`, tried again next pass; a turn that starts between that get and the send is still typed into). `working`, `blocked`, no status or not found: nothing this pass.
- Never over typed input: just before a send it reads the screen once (`hc read`) and checks the prompt line, the last line that starts (after spaces and an optional box) with the marker `❯` or `>`; text after the marker and a space or NBSP holds the wake off for that pass, and so does a screen that cannot be read or shows no prompt line (`noprompt` in `watcher/woke`).
- One wake per unread batch (the highest unread `seq` per sender) per `PADDOCK_WATCH_WAKE` seconds (default 60); new mail is a new batch. A failed send is tried again on the next pass.
- Every wake, every skip (status, typed input, rate limit) and every mailbox line is printed and appended to `watcher/woke` in the state folder, one tab-separated line: time (epoch), `wake`/`skip`/`mail`, target, batch or ledger key, status read, typed input (`yes`/`no`/`unreadable`/`noprompt`/`moved`/`-`), send exit code (`rate` for a rate-limit skip, `-` when nothing was sent).
- `watcher/reload-plugins`: types `/reload-plugins` once ([why](references/rationale.md#plugin-reload)).

## CI watching

`org-pull-request` appends `ci_requested` (`scripts/org --as secretary ci_requested --pr N --sha SHA --repo OWNER/NAME [--task ID]`). Each pass, a request is open while no `ci_completed` or `ci_watch_failed` of the watcher for the same `repo`, `pr` and `sha` is at or after it (a `ci_completed` the skill wrote itself before stage 3, `from: secretary`, does not close it). For the newest open request of each PR (of each repository: the same number in two projects is two PRs) with no live watch, it starts `scripts/ci-watch.sh --pr N --sha SHA --repo R [--task ID]` in the background of its own shell; the pid, head, repository and PR go to `watcher/ci/<owner>_<name>-<pr>.pid`, the output to `watcher/ci/<owner>_<name>-<pr>-<sha7>.log`.

`ci-watch.sh` finds every run of the head (`gh run list --commit`, push and pull_request alike; `PADDOCK_RUN_TRIES` / `PADDOCK_RUN_SLEEP` as in org-pull-request). While one has not completed it runs `gh run watch <run> --exit-status --interval 30` on it and lists the runs again, so there is no result until every run of the head has ended. `success` needs every run concluded `success`, `skipped` or `neutral`; any other conclusion is `failure`, and the record's `run_id` and the line's `run <id>` name the first such run (on success, the first listed). The line ends with `Runs read:` and each run's id, event and conclusion. A run that appears only after all the others ended is not waited for. Whatever ends it, it writes one record as watcher and one mailbox line: `ci_completed` (`success` or `failure`), else `ci_watch_failed` with `reason` `no_run`, `gh_error` (a `gh` call failed, or no conclusion), `signal` (HUP, INT, TERM) or `superseded` (a newer request for the PR of the same repository: the watcher sends it USR1), `exit_code` and `log`. A watch that died with no chance to trap (SIGKILL) is written `vanished` by the next pass (a recorded pid counts as the watch only while `/proc/<pid>/cmdline` names `ci-watch.sh`, so after a restart another process with that pid is neither waited for nor signalled); an older request never watched before a newer one came is written `superseded` by the pass. Example: `{"seq":3,"ts":"...","kind":"ci_watch_failed","from":"watcher","task_id":"t1","pr":42,"sha":"<head>","repo":"o/r","reason":"no_run","exit_code":0,"log":"<state>/watcher/ci/o_r-42-0123456.log"}`; the watcher's `ci_completed` carries `repo` the same way`. The watcher never merges.

## Channel

The first that works, per message:

1. Windows toast with the system sound, through `powershell.exe` (WSL). When Windows reports notifications disabled for it (`Setting` is not `Enabled`) the toast counts as failed and the next channel runs. The script goes in on stdin and the text in environment variables, so a question with quotes or shell syntax is never run. A kept terminal's PATH lacks `/mnt/c`, so the default `/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe` is tried too (`PADDOCK_POWERSHELL` names another).
2. `notify-send` (Linux desktop with a notification daemon).
3. The terminal bell, plus the message on the watcher's terminal. Always printed, whatever channel worked.

## Exit codes

0 done, 2 bad argument, 3 `hc` not found, 5 core unreachable (`--once` only; the loop logs it and tries again).
`ci-watch.sh`: 0 a result recorded, 1 `ci_watch_failed` recorded, 2 bad argument, 129/130/143/138 ended by HUP/INT/TERM/USR1 (`ci_watch_failed` recorded).

## Not covered

- A stopped core stops the watcher with it, and nothing says so. With it stop the wakes and the CI watches; open requests are watched again when it is back (a result late, not lost).
- Not measured on a host (decision 0013, stage 2): whether `hc send` to a `done` secretary lands, `gh` on the kept terminal's PATH and login, a real `gh run watch` and its signals. Tested against stubbed `hc` and `gh` (`tests/org-watch-wake.test.sh`).
- The first-message-not-sent case of a launch is not visible to `hc get`; the N-minute no-status rule catches that terminal later.
- A watcher started during a freeze waits N minutes before telling, since "unchanged" is what it saw itself.
- Measured on the host (WSL2, powershell.exe 5.1): toasts from the person's shell and from a kept terminal by the absolute path reached the Windows notification centre (shown as from Windows PowerShell); by name from the kept terminal it was not found. Not confirmed: whether the sound played. Not measured: a long run, or a core with many terminals (`scripts/probes/toast-from-kept-terminal.sh`).
