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

1. Reads the `suspend.record` that [org-suspend](../org-suspend/SKILL.md) wrote. No record: exit 9, nothing launched.
2. Per worker (`work` entry), finds its terminal by the `task_id` label and prints: the git comparison (`HEAD` unchanged or changed, uncommitted files, worktree missing) and whether the terminal is alive (it reports a status) or gone.
3. Prints the plan and stops. Without `--apply` it runs no `hc run`, `hc kill` or `hc rm`.
4. With `--apply`, for each worker whose terminal is gone:
   1. If a labelled terminal with that name remains without a status, it is ended first (`hc kill`, `hc rm`, only when its label is that task's).
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

0 plan printed or workers resumed, 2 bad argument, 3 `hc` not found, 4 run inside an agent, 5 core unreachable or `hc rm` failed, 9 no suspend record, 13 a worker could not be relaunched.

## Not measured

Real `hc` behaviour, and the fallback end to end (a failed `--continue` followed by a fresh worker), are not measured; tested only against a stubbed `hc` (`tests/org-resume.test.sh`).
