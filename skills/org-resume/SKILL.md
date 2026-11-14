---
name: org-resume
description: Resume the organization after a pause. Finds the workers again by task_id label, compares each worktree's git state with the suspend record, prints a plan, and with --apply relaunches workers whose terminal is gone (claude --continue first, a fresh worker as the fallback). Run it from your own login shell.
---

# org-resume

Implements inventory row [SUS-2](../../docs/design/predecessor-inventory.md) and [Q4](../../docs/design/open-questions.md#q4-worker-recovery-after-a-core-restart) decision B. Run it from the person's login shell, never from inside an agent.

```sh
bash skills/org-resume/scripts/org-resume.sh            # prints a plan, launches nothing
bash skills/org-resume/scripts/org-resume.sh --apply    # relaunches workers whose terminal is gone
```

## What it does

1. Reads the `suspend.record` that [org-suspend](../org-suspend/SKILL.md) wrote. **No record** (an unplanned core stop: a crash or a restart): it reads the `work` entries of `org-state` instead, says so in its output and lists what it could not restore (the git comparison with a record, the recorded terminal names, the recorded terminal states), then goes on as below with `w-<task_id>` as the name and the core's answer as the state. No record and no `work` entry: exit 9, nothing launched.
2. Per worker (`work` entry), finds its terminal by the `task_id` label and prints: the git comparison (`HEAD` unchanged or changed, uncommitted files, worktree missing) and whether the terminal is alive (it reports a status) or gone.
3. Prints the plan and stops. Without `--apply` it runs no `hc run`, `hc kill` or `hc rm`.
4. With `--apply`, for each worker whose terminal is gone:
   1. If a labelled terminal with that name remains without a status, it is ended first (`hc kill`, `hc rm`, only when its label is that task's). Right after it, the 0-byte read-only `config.lock` that Claude Code's sandbox leaves in the clone's shared `.git` when a worker is killed mid-command ([Issue #324](https://github.com/suisya-systems/paddock/issues/324)) is removed, but only if no process has its cwd in the ended worker's worktree (it waits up to `PADDOCK_LOCK_WAIT` seconds, default 10, for a killed command to end), none has it in another linked worktree of the same clone, and the file is a regular, 0-byte, not writable file. Otherwise it stays and the output says why. What was removed is printed and appended to `removed-locks.log` in the state folder. A process whose sandbox still has the clone's `.git` mounted (`/proc/*/mountinfo`) also keeps it. Without `/proc` nothing is removed.
   2. Runs the **continue template** with `--outlive-parent`, `--label task_id=<id>`, `--cwd <worktree>` and the original task in the launch ([decision 0002](../../docs/decisions/0002-org-mailbox-not-hc-send.md)). It counts as up when `first_message.sent` is true and the terminal shows a status within `PADDOCK_READY_TRIES` seconds.
   3. If not (transcripts off, no transcript, no status): ends that terminal and runs the **fresh template** with the same task, worktree and label. This is the fallback of Q4's decision B.
   4. If that also fails, exit 13 and `hc read <name>` tells why.

Workers that are alive are left alone. Unlabelled terminals are never touched. It never runs `hc server stop` or `restart`.

## Assumptions (open points left open)

- **Two templates, names not decided.** `claude --continue` is a different command, so there are two worker templates: `worker` (fresh) and `worker-continue` (its command ends in `claude --continue`, as in [the Q4 probe](../../scripts/probes/continue-multi-conv.sh)). Neither ships yet ([prototype 1](../../docs/design/prototype-1.md) has no worker template). Names: `PADDOCK_WORKER_TEMPLATE`, `PADDOCK_WORKER_CONTINUE_TEMPLATE`.
- **The original task** is the `task` field of the worker's `work` entry in `org-state`, copied into the record by `org-suspend` (see its assumptions). A worker without it is reported and not relaunched.
- **Terminal name** is the one in the record, else `w-<task_id>` (the secretary template's launch line).
- **"Up" check.** Q4 leaves open how a wrong resume is detected. This skill checks only that the task reached the worker and a status appears. It does not tell that `--continue` resumed the wrong conversation; the printed git comparison is what a person or the secretary reads. A worktree that is missing is reported and still tried (`hc` decides).
- Only the worker side is rebuilt. The secretary comes back with [org-start](../org-start/SKILL.md) and its handover.

## Exit codes

0 plan printed or workers resumed, 2 bad argument, 3 `hc` not found, 4 run inside an agent, 5 core unreachable or `hc rm` failed, 9 no suspend record and no work in the work list, 13 a worker could not be relaunched.

## Measured

The no-record path was measured once on a real core (hc 0.1.18, Claude Code 2.1.322) with `scripts/probes/org-resume-no-record.sh`: a worker in progress, `hc server stop` with no `org-suspend`, then `org-resume` and `org-resume --apply`. All checks passed:

- `org-state` survived the core stop, so the work list was there to read.
- The worker's terminal record remained after the stop, without a status (`exit_code` null). `org-resume` treats that as gone, as designed.
- The plan said "no suspend record; resuming from the work list" and what it could not restore, and launched nothing.
- `--apply`: `worker-continue` did not come up; the fresh-worker fallback did, and the terminal reported a status. So the fallback ran end to end. Why `--continue` did not come up was not read from the output (the probe stops the first turn after 5 s; no conversation may have been saved).

## Not measured

Real `hc` behaviour, and the fallback end to end (a failed `--continue` followed by a fresh worker), are not measured; tested only against a stubbed `hc` (`tests/org-resume.test.sh`).
