# Prototype 3

Status: prototype, a host run (Issue #243). The runbook is ready; the run is not recorded yet ([Result](#result)). [Prototype 2](prototype-2.md) ran the loop once on 2026-11-10. Since then most parts of that loop were replaced, each tested and measured alone. This prototype runs the same loop again on a clean checkout of today's `main`, with all of them together: a person types one request to the secretary, a worker does one small task with an acceptance test first, asks one question that the person answers on the card, has its diff reviewed by a second model through the gate, and finishes; a pull request exists at the end and passes the acceptance job. Its goal clause is G1 (ledger, 2026-11-12): a request alone gets a worker going, approvals on screen, and a PR, with today's `main`.

Nothing in the product changes for this prototype. It adds this document, the host runbook [`scripts/probes/prototype-3.sh`](../../scripts/probes/prototype-3.sh), the fixture workflow [`scripts/probes/prototype-3-acceptance.yml`](../../scripts/probes/prototype-3-acceptance.yml) and the runbook's guard test. Every stop found by the run becomes an Issue.

## What changed since Prototype 2

| Change | Where | What the run checks |
| --- | --- | --- |
| The worker writes only its own files in the state folder; `org-delegate` writes a per-task settings file, `<state>/settings/<task_id>.json`, which the worker template passes with `--settings`; readers take the sender from the file name (#160, #241) | [`skills/org-delegate`](../../skills/org-delegate/SKILL.md), [`templates/worker.md`](../../templates/worker.md), [`scripts/org`](../../scripts/org) | `3-own-settings`; every mailbox step reads the writer from the file name, not from the line's `from` |
| The secretary starts with its own settings file and the premise reminder hook (#219, #223) | [`templates/secretary.md`](../../templates/secretary.md), [`templates/secretary-settings.json`](../../templates/secretary-settings.json) | `1-placed-files` (org-start placed today's files); the hook's line by eye (a note, not a step) |
| `org-start` places the cockpit mod and the layout itself (#195, #207) | [`skills/org-start`](../../skills/org-start/SKILL.md) | Setup has no copy step any more |
| The acceptance gate is a CI job: the first own commit declares tests with `Acceptance-Test:`, they fail there and pass at head (#115, #240) | [acceptance check](acceptance-check.md) | `8-test-commit`, `9-acceptance` (the job's log says `ACCEPTANCE: pass`, not `none`) |
| The worker asks for a review by a second model through the gate; its two calls run outside the sandbox as exact `excludedCommands` strings; rounds are counted by `codex-gate` and capped (#177, #225, #242) | [`scripts/second-model-review.sh`](../../scripts/second-model-review.sh), [`templates/worker-rules.md`](../../templates/worker-rules.md) | `8-review` |
| The history follows [decision 0005](../decisions/0005-history-log-settings.md): `work_added`, `approval_asked`, `approval_removed` are history lines | [`scripts/org`](../../scripts/org), [`skills/org-escalation`](../../skills/org-escalation/SKILL.md) | `4-work-entry`, `5-approval`, `7-approval-removed` are read from the history, so they hold even for what happened while `watch` was not running |
| The worker waits for an answer with `org wait` (#201) | [`templates/worker.md`](../../templates/worker.md) | The request no longer tells the worker how to wait |

## The pass line

The run passes when every step below holds and the person acts in only two places: the secretary's conversation (typing the request) and the card (clicking Yes). Every other time a person types into a terminal, answers a prompt or nudges an agent is a finding. A finding does not hide a step: the step is recorded as it happened, with the touch, its cause and the Issue that covers it.

## Host rules

The secretary of the organization that runs the runbook does every host step. On that host:

- Never change `~/.local/bin/claude`. `watch` saves and restores its link ([`claude-link.sh`](../../scripts/probes/claude-link.sh), Issue #213) and prints `RESULT claude-link: FAIL` if it moved.
- Never set `XDG_DATA_HOME`. `prepare` refuses when it is set.
- The paddock folder is a clean checkout of `main` at `origin/main`. `prepare` refuses otherwise and records the commit.
- Nobody answers a folder-trust dialog by keys. If one shows, it is a stop: record it and end the run.

## The fixture

- **Repository.** The throwaway repository used for Prototype 2, given as `--repo OWNER/NAME`, cloned on the host under the workers folder and already trusted by Claude Code (`--project`). Its `origin` must be that repository for fetch and push. `prepare` refuses paddock's own repository.
- **The acceptance job in it.** Its `main` must hold [`scripts/acceptance-check.sh`](../../scripts/acceptance-check.sh), equal to the paddock checkout's, and `.github/workflows/acceptance.yml`, equal to [`scripts/probes/prototype-3-acceptance.yml`](../../scripts/probes/prototype-3-acceptance.yml), and no other workflow (`org-pull-request` watches one run per commit). The job is paddock's own `acceptance` job alone, on `pull_request` only. `prepare` compares both files byte for byte against `origin/<base>`.
- **Task id.** `p3-<UTC yyyymmddhhmm>` unless given.
- **The task.** The worker (1) adds `tests/paddock-proto3.test.sh`, which passes only when `paddock-proto3.txt` at the root holds the one line `paddock prototype 3, task <task_id>`, and commits it alone as its first commit with the trailer `Acceptance-Test: tests/paddock-proto3.test.sh`; (2) before it creates the file, reports `blocked` with "May I add paddock-proto3.txt at the repository root?" and waits; (3) on yes adds the file in a second commit; (4) asks for the review through the gate; (5) reports done with both SHAs, the test result and the gate's last line.
- **The request.** One paragraph `prepare` prints with the paths and ids filled in, and keeps in `steps.txt`. It tells the secretary to delegate with `org-delegate`, to put the worker's question on the card with `org-escalation ask --answer-in secretary` rather than answer it, to forward the card's `ANSWER` with `org-escalation answer`, and to open the PR with `org-pull-request --mode human`, then to say the URL and the skill's exit code. The request is in English.
- **Organization to itself.** No terminal `secretary`, no `w-<task_id>`, nothing in `org-state` before the run.

### Seed the throwaway repository

Once, before the first run, from the clone (`<clone>`) with the clean paddock checkout at `<paddock>` and the checkout that holds the runbook at `<runbook>` (the same folder once this is merged); the host's own `gh` login pushes (a workflow file needs the `workflow` scope):

```sh
git -C <clone> switch main && git -C <clone> pull --ff-only
mkdir -p <clone>/scripts <clone>/.github/workflows
cp <paddock>/scripts/acceptance-check.sh <clone>/scripts/acceptance-check.sh
cp <runbook>/scripts/probes/prototype-3-acceptance.yml <clone>/.github/workflows/acceptance.yml
git -C <clone> add scripts/acceptance-check.sh .github/workflows/acceptance.yml
git -C <clone> commit -m "Add the acceptance job (paddock prototype 3 fixture)"
git -C <clone> push origin main
```

If the clone already holds other workflows, remove them in the same commit. When paddock's checker changes later, copy it again before the next run; `prepare` says so.

## Steps

Who acts: **P** is the person (on this host, the secretary of the organization that runs the runbook, acting for the owner), **S** the paddock secretary, **W** the worker, **R** the runbook. Each line `RESULT <step>: PASS | FAIL | NO DATA (detail)` in the runbook's output is one row. Every step after 2 must happen without a person.

| # | Step | Actor | What the screen shows | Pass when (`RESULT` name) |
| --- | --- | --- | --- | --- |
| 0 | Preconditions | P runs `prepare` in a login shell | `prepare` prints `RESULT` lines and the steps | `preconditions`: paddock on clean `main` at `origin/main`; origin is the named repository for fetch and push; `origin/<base>` has the seeded checker and workflow, no `.claude` files, no `paddock-proto3.txt` and no test; no worktree, branch or terminal of this task; `org-state` holds no task. `notes-off`, `worker-token` as in Prototype 2. `codex-cli`: `codex` on `PATH` and its login file exists (never read). |
| 1 | Start the organization and the screen | P, login shell | `org-start: ready`; after `layout.switch` the paddock layout with the secretary in the centre (P records it with `note`) | `1-secretary`: the terminal `secretary` reports a status. `1-placed-files`: the two templates and the six bin files (`org`, `second-model-review.sh`, `premise-reminder.sh`, `secretary-settings.json`, `worker-rules.md`, `worker-settings.json`) equal this checkout's. |
| 2 | Type the request | P, in the secretary's pane | The request in the secretary's conversation. The premise reminder may show as hook output (the request names `--mode` and other flags); P notes what it saw. | (none) |
| 3 | Worktree and settings | S, `org-delegate` | A worker tile appears on the left | `3-worktree`: the worktree on `work/<task_id>` with `.claude/settings.local.json`. `3-own-settings`: `<state>/settings/<task_id>.json` names the worker's own history file and the gate's calls in `excludedCommands`. |
| 4 | Worker started | S, W | The tile shows `working` | `4-worker`: `w-<task_id>` with the label `task_id=<task_id>`. `4-worker-report`: `run_started` in the worker's own file (only the template's command sets `$PADDOCK_ORG`). `4-work-entry`: `work_added` for the task in the secretary's history. |
| 5 | The question on the screen | W, S | The card at the bottom right: "The secretary is asking you", the question, Yes and No | `5-blocked`: the worker's `run_blocked`. `5-approval`: `approval_asked` for the task in the secretary's history (the id is read from it). |
| 6 | Answered on the screen | P clicks Yes | The card goes away | `6-card-answer`: `ANSWER <id> yes` in the person's file, to `secretary`. |
| 7 | The answer reaches the worker | S | The secretary's pane shows it read and forwarded the answer; the tile stays `working` | `7-secretary-read`: the secretary's `ack` covers the `ANSWER`. `7-forwarded`: `Answer to your question (<id>)` to the worker. `7-approval-removed`: `approval_removed <id>` in the history. |
| 8 | Test first, review, completion | W, S | The tile stays `working` through the review (minutes); then `done` | `8-test-commit`: the branch's first own commit declares `tests/paddock-proto3.test.sh` and changes only it. `8-review`: at least one `codex_round_started` for the task from `codex-gate`, and the done report quotes `CODEX_GATE: passed`. `8-done`: `run_completed`, and the branch has the commit with `paddock-proto3.txt`. `8-secretary-read`: the secretary's `ack` covers it. |
| 9 | A pull request that passes the acceptance job | S, `org-pull-request` | The secretary says the PR URL and exit 0 | `9-pull-request`: a PR with head `work/<task_id>` (read with `gh`, read only). `9-ci-record`: `ci_completed` for the task with exit code 0. `9-acceptance`: that run's log has `ACCEPTANCE: pass`. |
| 10 | Nobody touched a terminal | R | | `10-no-touch`: no `note --touch`, and neither terminal showed `blocked` (a Claude Code prompt or dialog) during the watch. |

The history files last, so steps 4 to 9 are read back even if `watch` was restarted. The terminals' status and `org-state` are seen only while `watch` runs (every 5 s), so `watch` starts before the request is typed. A step it did not see is NO DATA, never PASS. `watch` also keeps `hc events --json` in the run folder.

## Expected findings

Known before the run. The runbook prints a `NOW:` line when the person must act.

- **The review gate's calls must match `excludedCommands` exactly (#242).** The worker must write the gate's path out (`bash "<path>"`); a variable, `cd` or pipe keeps the call inside the sandbox, and the reviewing CLI cannot reach its host: the gate ends `not-established`. Then `8-review` fails; record the worker's command from its screen and the gate's last line.
- **A permission prompt for the gate call.** The same strings are in `permissions.allow`; a prompt in the worker's terminal anyway is a touch (cause to find; it would be a new Issue).
- **Codex rounds (#225).** Up to 3 diff rounds per task. `CODEX_ROUND_DENIED` stops the worker's reviews; it reports the open findings. A finding about the test cannot be fixed without failing the acceptance job's rule 4; the task tells the worker to leave it and say so.
- **`.codex-home/` in the worktree.** The gate makes it for the reviewer's login (links, not copies). It must not be committed; the task says to commit only the two files. A commit holding it is a finding.
- **The card answers a question; a prompt is answered in its terminal (#127).** As in Prototype 2: each answer in a terminal is a touch.
- **The answer reaches a waiting secretary (#140).** The click-to-`ack` delay shows it. Known gap: an answer while the secretary is in `org-pull-request`'s CI wait waits for that call; it cannot happen here, the only answer comes before the PR.
- **Project trust (#133) and the workers folder's first trust dialog (Q13).** The clone is trusted before the run; a dialog is a stop, never answered by keys.
- **Child notes.** If `notes-off` fails, a note typed into the secretary is a touch, cause [Q2](open-questions.md#q2-how-much-of-a-childs-reporting-goes-through-the-mailbox).

## Run it

From the paddock repository root (clean `main`; the runbook may be called by absolute path from another checkout, and reads its fixture from its own folder) on the host where `hc`, `herdr-app`, `claude`, `codex` and `gh` run:

1. Seed the throwaway repository once ([above](#seed-the-throwaway-repository)).
2. In a login shell (no agent above it; its first `hc` call may start the core): `sh scripts/probes/prototype-3.sh prepare --project <clone> --repo OWNER/NAME [--base main]`. Expect `RESULT preconditions: PASS`, `notes-off`, `worker-token` and `codex-cli` PASS, then the steps and the request. The run is saved under `${XDG_STATE_HOME:-~/.local/state}/paddock-proto3/<task_id>/`. It starts nothing.
3. Do the printed setup: `bash skills/org-start/scripts/org-start.sh` from that login shell (expect `org-start: ready`, exit 0), then `herdr-app do layout.switch '{"name":"paddock"}'`. Record the screen with `note`.
4. Start `sh scripts/probes/prototype-3.sh watch --task-id <task_id>` and keep it running. An agent may run it.
5. Type the printed request into the secretary's pane. Click Yes on the card when `watch` says so. Answer nothing else; if you must, record it: `note --task-id <task_id> --touch "<what and why>"`.
6. When `watch` ends (the acceptance result, or 15 minutes after the PR with no CI record, or `--timeout`, default 90 minutes), run `collect`, then `cleanup`. `collect` writes `evidence/summary.txt`: versions (herdr-app's only where it runs; record a Windows herdr-app by hand), the paddock commit, every `RESULT`, the notes, `hc ls`, both terminals, `list_runs`, the history lines of the secretary, the person, the worker and `codex-gate` since the run started, `org-state` and its changes, the status log, the placed files, the task's settings file, the branch's own commits with their trailers and files, the PR and its checks, and the acceptance job's lines. `cleanup` ends only the terminals `watch` recorded, removes the worktree and the local branch, puts `org-state` back when only this task is in it, and prints the `gh pr close ... --delete-branch` command for the person.

## What to record

In [Result](#result), from `evidence/summary.txt` and the notes:

- Date, the paddock commit, and the versions of `hc`, herdr-app, Claude Code, `codex` and `gh`.
- Each step's `RESULT`.
- The pull request as "PR #N in the throwaway repository".
- Delays: request to `4-worker`, `run_blocked` to the card, click to the secretary's `ack`, answer to `run_completed` (the review's share from the `codex_round_started` times), `run_completed` to the PR, PR to `ci_completed`.
- A table of every touch and every failed step: step, what happened, cause, Issue. Name an existing Issue where it fits; every other stop is a proposed new Issue, listed with a title and one line for the secretary to file.

No local paths and no company matters go into this document.

## Result

Not run yet.
