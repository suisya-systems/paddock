# Prototype 2

Status: prototype, a host run (Issue #59). [Prototype 1](prototype-1.md) showed `org-state` on the screen. This one runs the first full loop through the parts built since: a person types a request to the secretary, a worker does one small task in its own worktree, asks one question that the person answers on the screen, finishes, and a pull request exists at the end. Its goal clauses are G1 (start one worker from the secretary template and get its completion back to the secretary) and G3 (approvals appear on the screen and people answer from there).

Nothing in the product changes for this prototype. It adds this document and the host runbook [`scripts/probes/prototype-2.sh`](../../scripts/probes/prototype-2.sh). The result of the run is recorded below, under [Result](#result).

## What is in it

| Path | What it is |
| --- | --- |
| [`templates/secretary.md`](../../templates/secretary.md) | The secretary, started fresh from the template by [`org-start`](../../skills/org-start/SKILL.md). |
| [`skills/org-delegate`](../../skills/org-delegate/SKILL.md) | Makes the worktree, writes its settings file, starts the worker with `hc run --bg` and the `task_id` label. |
| [`templates/worker.md`](../../templates/worker.md) | The worker, with its role rules and settings files passed by the template's command. |
| [`scripts/org`](../../scripts/org) | The mailbox: the worker's reports, the card's `ANSWER`, the secretary's reply. |
| [`skills/org-escalation`](../../skills/org-escalation/SKILL.md) | Puts the worker's question into `org-state.approvals` and forwards the answer. |
| [`mods/org-cockpit/`](../../mods/org-cockpit/) and [`layouts/paddock.json`](../../layouts/paddock.json) | The screen: the card with Yes and No. |
| [`skills/org-pull-request`](../../skills/org-pull-request/SKILL.md) | Pushes the worker's branch and opens the PR, in `human` mode (no merge). |

## The pass line

The run passes when every step below holds and the person acts in only two places: the secretary's conversation (typing the request) and the card (clicking Yes). Every other time a person types into a terminal, answers a prompt or nudges an agent is a finding. A finding does not hide a step: the step is recorded as it happened, with the touch, its cause and the issue that covers it.

## The fixture

- **Project.** An existing git repository on the host, given to the runbook as `--project`. It is already trusted by Claude Code: the trust of a new project folder is not solved by paddock (Issue #133), so it is a precondition, not part of the loop. The worker's worktree lands under the workers folder (`PADDOCK_WORKERS_DIR`), which a person trusts once ([Q13](open-questions.md#q13-how-does-a-new-worktree-get-past-claude-codes-folder-trust-dialog)).
- **Repository.** A throwaway GitHub repository the person names at run time (`--repo OWNER/NAME`). The project's `origin` must point at it for both fetch and push; the runbook checks every URL of `origin` and refuses otherwise. It refuses paddock's own repository outright. The pull request goes to a new branch `work/<task_id>` against the base (default `main`), and nothing is merged. If that repository has no CI workflow, `org-pull-request` stops with exit 7 after the PR is open: "a PR exists" still holds, and the CI line is recorded as missing.
- **Task id.** `p2-<UTC yyyymmddhhmm>` unless given.
- **The task.** The worker adds `paddock-proto2.txt` at the repository root with one line and commits it. Before it creates the file it asks, with `report blocked`, "May I add paddock-proto2.txt at the repository root?", and waits for the answer by running `check_messages` every 15 seconds for up to 15 minutes, staying in its turn: a worker that goes idle is not woken by a mailbox message ([Q18](open-questions.md#q18-how-does-anything-reach-an-idle-agent), SK-4). It goes on only on yes.
- **The request.** One paragraph the runbook prints with the paths and ids filled in. It tells the secretary to delegate with `org-delegate`, not to answer the worker's question itself but to put it on the card with `org-escalation ask`, to forward the card's `ANSWER` with `org-escalation answer`, and to open the PR with `org-pull-request --mode human`, then to say the URL and the skill's exit code. The request is in English; the conversation language may differ.
- **Organization to itself.** No terminal named `secretary`, no `w-<task_id>`, and nothing in `org-state.work` or `org-state.approvals` before the run, so the one card on the screen is this run's and cleanup can put `org-state` back.

## Steps

Who acts: **P** is the person (on this organization's host, the secretary of the organization that runs the runbook, acting for the owner), **S** the paddock secretary, **W** the worker, **R** the runbook. Each line `RESULT <step>: PASS | FAIL | NO DATA (detail)` in the runbook's output is one row.

| # | Step | Actor | Must happen without a person | Pass when (`RESULT` name) |
| --- | --- | --- | --- | --- |
| 0 | Preconditions | P runs `prepare` in a login shell | | `preconditions`: origin is the named repository for fetch and push; the base exists and has no `.claude` files and no `paddock-proto2.txt`; no worktree, branch (local or on origin) or terminal of this task exists; `org-state` holds no task. `notes-off`: herdr-core's config says `notes = false` ([decision 0002](../decisions/0002-org-mailbox-not-hc-send.md)). `worker-token`: the read-only token file exists (never read). |
| 1 | Start the organization and the screen | P, login shell | | `1-secretary`: the terminal `secretary` reports a status. `1-role-files`: every file the placed worker template names with `--append-system-prompt-file` and `--settings` exists (paths are read from the template at run time, since Issue #129 moved them to the bin folder beside the org script; their checksums are recorded). The layout is open with the secretary in the centre (by eye, `note`). |
| 2 | Type the request | P, in the secretary's pane | | (none) |
| 3 | Worktree and settings | S, `org-delegate` | yes | `3-worktree`: the worktree is registered in the project on `work/<task_id>`, with `.claude/settings.local.json`. |
| 4 | Worker started | S, `org-delegate`; W | yes | `4-worker`: `w-<task_id>` exists with the label `task_id=<task_id>`. `4-worker-report`: the worker wrote its own `run_started` through `$PADDOCK_ORG`, which only the template's command sets, in the same command that passes the role files (this shows the command ran, not that Claude Code applied every rule). `4-work-entry`: `org-state.work` holds the task. |
| 5 | The question on the screen | W, S | yes | `5-blocked`: the worker's `run_blocked`. `5-approval`: `org-state.approvals` holds an entry for the task. The card shows it (by eye, `note`, or `herdr-app shot`). |
| 6 | Answered on the screen | P clicks Yes | | `6-card-answer`: `ANSWER <id> yes` from `person` to `secretary` in the mailbox. |
| 7 | The answer reaches the worker | S | yes | `7-secretary-read`: the secretary's read mark (`ack`) covers the `ANSWER`. `7-forwarded`: a message `Answer to your question (<id>)` from the secretary to the worker. `7-approval-removed`: the entry left `org-state`. |
| 8 | The worker finishes, the completion reaches the secretary | W, S | yes | `8-done`: the worker's `run_completed`, and `work/<task_id>` has a commit touching `paddock-proto2.txt`. `8-secretary-read`: the secretary's `ack` covers it. |
| 9 | A pull request exists | S, `org-pull-request` | yes | `9-pull-request`: a PR with head `work/<task_id>` on the named repository (the runbook reads it with `gh`, read only). `9-ci-record`: a `ci_completed` line for the task, or NO DATA with the exit code the secretary reported. |
| 10 | Nobody touched a terminal | R | | `10-no-touch`: no `note --touch`, and neither the worker nor the secretary showed the `blocked` status (a Claude Code prompt or dialog) during the watch. |

The runbook sees the mailbox from its files, which last; it sees `org-state` and the terminals' status only while `watch` runs, every 5 seconds, so `watch` starts before the request is typed. A step it did not see is NO DATA, never PASS. `watch` also keeps `hc events --json` in the run folder.

## Expected findings

These are known before the run. The runbook shows them as they happen, with a `NOW:` line saying what the person does and what to record.

- **An idle secretary is not woken by a mailbox message (Issue #140).** The card writes `ANSWER` into the secretary's mailbox; the secretary reads it at its next turn. While the worker works, the secretary should be waiting in `hc wait` on its children ([Q18](open-questions.md#q18-how-does-anything-reach-an-idle-agent), decided (c)), and whether that wait returns for a mailbox message is what the run shows. If the secretary sits `done` with the `ANSWER` unread, the person nudges it in its conversation, and that is a touch, cause #140. The delays (click to `ack`, `run_completed` to `ack`) are in the evidence.
- **The card answers a question, not a prompt (Issue #127).** The card answers a question the worker waits for in its mailbox. A worker blocked on its own Claude Code permission prompt or dialog is answered in its own terminal; each one is a touch, cause #127. The same holds for a prompt in the secretary's pane.
- **Role files moved (Issue #129).** org-start now places them beside the org script, not in the templates folder. The run reads their paths from the template org-start placed, and records which it found; a mismatch with an older placement is a finding under #129.
- **Project trust (Issue #133).** Outside the loop: the project is trusted before the run.
- **The workers folder's first trust dialog (Q13).** If this is the first worker under the workers folder, its trust dialog stops the first message (org-delegate exit 10). A person accepts it once; record it as a touch, cause Q13, not a defect of the loop.
- **Child notes.** If `notes-off` fails, hc types notes into the secretary's prompt; any progress that came from a note is a touch, cause [Q2](open-questions.md#q2-how-much-of-a-childs-reporting-goes-through-the-mailbox) configuration.

## Run it

From the paddock repository root on the host where `hc`, `herdr-app`, `claude` and `gh` run:

1. In a login shell (no agent above it; its first `hc` call may start the core, which inherits that shell's environment): `sh scripts/probes/prototype-2.sh prepare --project <repo> --repo OWNER/NAME [--base main]`. It checks step 0, saves the run under `${XDG_STATE_HOME:-~/.local/state}/paddock-proto2/<task_id>/`, and prints the setup commands and the request to type. It starts nothing itself.
2. Do the printed setup: `org-start` from that login shell, then the layout and the `org-cockpit` mod as in the [README](../../README.md#the-screen). Record the screen with `note`.
3. Start `sh scripts/probes/prototype-2.sh watch --task-id <task_id>` and keep it running. An agent may run it.
4. Type the printed request into the secretary's pane. Click Yes on the card when `watch` says so. Answer nothing else; if you must, record it: `note --task-id <task_id> --touch "<what and why>"`.
5. When `watch` ends (the CI record, or 10 minutes after the PR, or `--timeout`), run `collect`, then `cleanup`. `collect` writes `evidence/summary.txt`: versions, every `RESULT`, the notes, `hc ls`, both terminals' `hc get`, `list_runs`, the mailbox lines of the secretary, the person and the worker since the run started (read marks and the CI line included), `org-state` and its changes, the status log, the role files and checksums, the branch's commits and the PR. `cleanup` ends only the terminals whose `created_ms` `watch` recorded, removes the worktree and the local branch, puts `org-state` back when only this task is in it, and prints the `gh pr close ... --delete-branch` command for the person; it does not touch GitHub.

## What to record

In [Result](#result), from `evidence/summary.txt` and the notes:

- Date, and the versions of `hc`, herdr-app, Claude Code and `gh`.
- Each step's `RESULT`.
- The pull request as "PR #N in the throwaway repository"; its URL only if the owner agrees to publish the repository name.
- Delays: request to `4-worker`, `run_blocked` to the card, click to the secretary's `ack`, `run_completed` to the PR.
- A table of every touch and every failed step: step, what the person did or what failed, cause, issue. Name the existing issue (#127, #129, #133, #140) where it fits; list the ones that need a new issue for the secretary to file.

No local paths and no company matters go into this document.

## Result

Not run yet. The run fills this section: the steps that held, then the table of touches and failures.

| Step | What happened | Cause | Issue |
| --- | --- | --- | --- |
| | | | |
