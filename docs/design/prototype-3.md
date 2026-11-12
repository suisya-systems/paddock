# Prototype 3

Status: prototype, a host run (Issue #243). Run 1 on 2026-11-11: the loop stopped at the worker's first report, before the card was answered; four stops are filed. Run 2, the same day after #244 to #247: 20 of 21 steps pass and the person's only action was Yes on the card; one step fails because the gate keeps no result record ([Result](#result)). Run 3 on 2026-11-12, on `main` at `31adf37`: stopped by the owner during setup, before the request was sent; G1 is not met ([Run 3](#run-3)). [Prototype 2](prototype-2.md) ran the loop once on 2026-11-10. Since then most parts of that loop were replaced, each tested and measured alone. This prototype runs the same loop again on a clean checkout of today's `main`, with all of them together: the runbook sends one request to the secretary, a worker does one small task with an acceptance test first, asks one question that the person answers on the card, has its diff reviewed by a second model through the gate, and finishes; a pull request exists at the end and passes the acceptance job. Its goal clause is G1 (ledger, 2026-11-12): a request alone (here sent by the runbook) gets a worker going, approvals on screen, and a PR, with today's `main`.

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

The run passes when every step below holds and the person acts in one place only: the card (clicking Yes). The request is test scaffolding (a fixed text, so the results can be checked), not what a person would write, so the runbook sends it. Every other time a person types into a terminal, answers a prompt or nudges an agent is a finding. A finding does not hide a step: the step is recorded as it happened, with the touch, its cause and the Issue that covers it.

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
- **The request.** One paragraph `prepare` fills in with the paths and ids and saves as `request.txt` in the run folder (`steps.txt` says where). `watch` sends it with `hc send` to the secretary once it reports a status that is not a prompt, once per run, and records that in the notes as `sent` (not a touch). It tells the secretary to delegate with `org-delegate`, to put the worker's question on the card with `org-escalation ask --answer-in secretary` rather than answer it, to forward the card's `ANSWER` with `org-escalation answer`, and to open the PR with `org-pull-request --mode human`, then to say the URL and the skill's exit code. The request is in English.
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

Who acts: **P** is the person (on this host, the secretary of the organization that runs the runbook, acting for the owner), **S** the paddock secretary, **W** the worker, **R** the runbook. Each line `RESULT <step>: PASS | FAIL | NO DATA (detail)` in the runbook's output is one row. Every step after 1 must happen without a person, except the click in step 6.

| # | Step | Actor | What the screen shows | Pass when (`RESULT` name) |
| --- | --- | --- | --- | --- |
| 0 | Preconditions | P runs `prepare` in a terminal inside herdr | `prepare` prints `RESULT` lines and the steps | `preconditions`: paddock on clean `main` at `origin/main`; origin is the named repository for fetch and push; `origin/<base>` has the seeded checker and workflow, no `.claude` files, no `paddock-proto3.txt` and no test; no worktree, branch or terminal of this task; `org-state` holds no task. `notes-off`, `worker-token` as in Prototype 2. `codex-cli`: `codex` on `PATH` and its login file exists (never read). |
| 1 | Start the organization and the screen | P, a terminal inside herdr | `org-start: ready`; after `layout.switch` the paddock layout with the secretary in the centre (P records it with `note`) | `1-secretary`: the terminal `secretary` reports a status. `1-placed-files`: the two templates and the six bin files (`org`, `second-model-review.sh`, `premise-reminder.sh`, `secretary-settings.json`, `worker-rules.md`, `worker-settings.json`) equal this checkout's. |
| 2 | Send the request | R, `hc send` from `watch` | The request in the secretary's conversation. The premise reminder may show as hook output (the request names `--mode` and other flags); P notes what it saw. | `2-request`: `watch` sent `request.txt` to the secretary and noted it (`sent`). |
| 3 | Worktree and settings | S, `org-delegate` | A worker tile appears on the left | `3-worktree`: the worktree on `work/<task_id>` with `.claude/settings.local.json`. `3-own-settings`: `<state>/settings/<task_id>.json` names the worker's own history file and the gate's calls in `excludedCommands`. |
| 4 | Worker started | S, W | The tile shows `working` | `4-worker`: `w-<task_id>` with the label `task_id=<task_id>`. `4-worker-report`: `run_started` in the worker's own file (only the template's command sets `$PADDOCK_ORG`). `4-work-entry`: `work_added` for the task in the secretary's history. |
| 5 | The question on the screen | W, S | The card at the bottom right: "The secretary is asking you", the question, Yes and No | `5-blocked`: the worker's `run_blocked`. `5-approval`: `approval_asked` for the task in the secretary's history (the id is read from it). |
| 6 | Answered on the screen | P clicks Yes | The card goes away | `6-card-answer`: `ANSWER <id> yes` in the person's file, to `secretary`. |
| 7 | The answer reaches the worker | S | The secretary's pane shows it read and forwarded the answer; the tile stays `working` | `7-secretary-read`: the secretary's `ack` covers the `ANSWER`. `7-forwarded`: `Answer to your question (<id>)` to the worker. `7-approval-removed`: `approval_removed <id>` in the history. |
| 8 | Test first, review, completion | W, S | The tile stays `working` through the review (minutes); then `done` | `8-test-commit`: the branch's first own commit declares `tests/paddock-proto3.test.sh` and changes only it. `8-review`: in the `codex-gate` history, the task's last diff round (its last `codex_round_started`, `codex_round_passed` or `codex_round_failed` line) is `codex_round_passed`, which the gate writes itself (#253); the worker's done text is not read. `8-done`: `run_completed`, and the branch has the commit with `paddock-proto3.txt`. `8-secretary-read`: the secretary's `ack` covers it. |
| 9 | A pull request that passes the acceptance job | S, `org-pull-request` | The secretary says the PR URL and exit 0 | `9-pull-request`: a PR with head `work/<task_id>` (read with `gh`, read only). `9-ci-record`: `ci_completed` for the task with exit code 0. `9-acceptance`: that run's log has `ACCEPTANCE: pass`. |
| 10 | Nobody touched a terminal | R | | `10-no-touch`: no `note --touch`, and neither terminal showed `blocked` (a Claude Code prompt or dialog) during the watch. |

The history files last, so steps 4 to 9 are read back even if `watch` was restarted. The terminals' status and `org-state` are seen only while `watch` runs (every 5 s), so `watch` starts before the request is sent (it sends it itself). A step it did not see is NO DATA, never PASS. `watch` also keeps `hc events --json` in the run folder.

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
2. Inside herdr, in a plain shell terminal (herdr's own terminals are the only shells the run needs). An agent already in herdr makes the terminal with `hc` and types into it; that set-up is not a touch of the run, because nobody at a keyboard does it. The core must already be running: `prepare` stops with exit 6 when `hc server status` fails and never starts the core, so the core's environment is never this terminal's or an agent's (the host rule behind `org-start`'s Q17 check, kept as a check). Then: `sh scripts/probes/prototype-3.sh prepare --project <clone> --repo OWNER/NAME [--base main]`. Expect `RESULT preconditions: PASS`, `notes-off`, `worker-token` and `codex-cli` PASS, then the steps and the request. The run is saved under `${XDG_STATE_HOME:-~/.local/state}/paddock-proto3/<task_id>/`. It starts nothing.
3. Do the printed setup: `bash skills/org-start/scripts/org-start.sh` from that terminal (expect `org-start: ready`, exit 0), then `layout.switch` with herdr-app (the printed command names it by its path: where the core runs in WSL, herdr-app is the Windows program and is not on `PATH`; the runbook finds it under `/mnt/c/Users/*/AppData/Local/Programs/herdr-app/`, or `PADDOCK_HERDR_APP`). Record the screen with `note`.
4. Start `sh scripts/probes/prototype-3.sh watch --task-id <task_id>` and keep it running. An agent may run it. It sends the request to the secretary itself.
5. Click Yes on the card when `watch` says so. Answer nothing else; if you must, record it: `note --task-id <task_id> --touch "<what and why>"`.
6. When `watch` ends (the acceptance result, or 15 minutes after the PR with no CI record, or `--timeout`, default 90 minutes), run `collect`, then `cleanup`. `collect` writes `evidence/summary.txt`: versions (herdr-app's, found by the same path), the paddock commit, every `RESULT`, the notes, `hc ls`, both terminals, `list_runs`, the history lines of the secretary, the person, the worker and `codex-gate` since the run started, `org-state` and its changes, the status log, the placed files, the task's settings file, the branch's own commits with their trailers and files, the PR and its checks, and the acceptance job's lines. `cleanup` ends only the terminals `watch` recorded, removes the worktree and the local branch, puts `org-state` back when only this task is in it, and prints the `gh pr close ... --delete-branch` command for the person.

## What to record

In [Result](#result), from `evidence/summary.txt` and the notes:

- Date, the paddock commit, and the versions of `hc`, herdr-app, Claude Code, `codex` and `gh`.
- Each step's `RESULT`.
- The pull request as "PR #N in the throwaway repository".
- Delays: request to `4-worker`, `run_blocked` to the card, click to the secretary's `ack`, answer to `run_completed` (the review's share from the `codex_round_started` times), `run_completed` to the PR, PR to `ci_completed`.
- A table of every touch and every failed step: step, what happened, cause, Issue. Name an existing Issue where it fits; every other stop is a proposed new Issue, listed with a title and one line for the secretary to file.

No local paths and no company matters go into this document.

## Result

### Run 1

Run 2026-11-11, task `p3-202611111622`, paddock `main` at `65f869a`, the runbook at this branch's head (called by its path from another checkout). Versions: hc 0.1.18, Claude Code 2.1.322, codex-cli 0.157.0, gh 2.96.0; herdr-app ran on Windows with the core in WSL, and its version was not recorded (`collect` runs in WSL, where `herdr-app` is not on `PATH`). The person was the secretary of the organization that ran the runbook.

**The loop did not hold.** It stopped at step 5: the worker's `report start` and `report blocked` failed, so nothing the worker wrote reached the mailbox, and the card was not shown on the screen although the approval was in `org-state`. The owner chose to stop and fix. G1 does not hold yet. Before the stop, three touches were already needed to get the organization and the screen up.

| Step | `RESULT` |
| --- | --- |
| 0 | `preconditions`, `worker-token`, `codex-cli`: PASS. `notes-off`: FAIL (no `notes = false` in the core's config at `prepare`; the operator reports it was set for the run and removed at cleanup). |
| 1 | `1-secretary`, `1-placed-files` (the 8 files equal the checkout): PASS. The secretary first stopped at a folder-trust dialog (touch 1). The layout did not put the secretary in the centre (touches 1 and 2). |
| 2 | The request was sent into the secretary's conversation with `hc send` by the operator's assistant, not typed in the window (note). |
| 3 | `3-worktree`, `3-own-settings`: PASS. The task's settings file named the worker's own files and the gate's four calls in `excludedCommands` and `permissions.allow`. |
| 4 | `4-worker`, `4-work-entry`: PASS. `4-worker-report`: NO DATA; the worker's `report start` exited 5. |
| 5 | `5-approval`: PASS (the secretary asked `p3-202611111622-20261111T170334Z` with `answer_in: secretary`). `5-blocked`: NO DATA; the worker's `report blocked` exited 5. The card did not show the approval. |
| 6 to 10 | Not reached: the run was stopped before Yes. The worker had made its test commit (the status text named it), so `8-test-commit` was not judged; no review round was taken (no `codex-gate` line). |

Times (UTC, from the status log, the history and the notes):

| What | When | Delay |
| --- | --- | --- |
| `prepare` | 16:22:40 | |
| Trust dialog answered and layout fixed by hand (touches 1, 2) | 16:53:08 to 16:56:44 | |
| Request sent | 16:58:13 | |
| `run_started` by the secretary (org-delegate), `work_added` | 16:58:28, 16:58:30 | 15 s, 17 s |
| Worker terminal `working` | 16:58:31 | 18 s |
| Worker status `done` with "test commit ... done; awaiting yes" (its turn ended, not in `org wait`) | 17:02:15 | 4 min 2 s |
| `approval_asked` | 17:03:35 | 1 min 20 s after the worker's turn ended |
| Secretary status `done`: it ended its turn to ask the person how to go on after the worker's failed reports | 17:03:52 | |
| Stopped | 17:05:40 | |

Touches and stops:

| Step | What happened | Cause | Issue |
| --- | --- | --- | --- |
| 4, 5 | The worker's `report start` and `report blocked` exited 5: "lock ... is held (pid not recorded)"; the lock folder `locks/w-<task_id>` was there and empty. No line of the worker reached the history, so the secretary had no `run_blocked` to act on. | The worker's own-files write surface (#241) and the per-id lock inside it: the worker could not take its lock. Root cause to be found under the Issue. | #245 |
| 1, 5 | herdr-app runs on Windows and reads `C:/Users/<user>/.config/herdr-app`; `org-start` placed the cockpit mod and the layout only under WSL's `~/.config`. The app ran an older cockpit with a `secretary` prop naming another machine's secretary, so the centre did not adopt the secretary and the card did not show the approval. The operator labelled the secretary by hand (`hc label`) and copied the new mod and layout to the Windows folder (touch 2); the card still did not show. | `org-start` places the screen files on the core's side only. | #246 |
| 1 | The secretary started from `org-start` stopped at the folder-trust dialog for the paddock folder; the operator answered it with `hc keys` (touch 1, against the host rule). | A secretary's working folder that is not yet trusted. | #244 |
| 2, collect | The runbook asks the person to type the request into the window, and runs `herdr-app` (`layout.switch`, `--version`) in WSL, where it is not on `PATH`; the request went in by `hc send`, `layout.switch` through the Windows program's path. | Runbook and setup assume herdr-app on the core's side. | #247 |
| 5 | The worker ended its turn idle ("awaiting yes") after its `report blocked` failed, instead of waiting in `org wait`; an answer by mail would not wake it. | The worker template's fallback for a failed `org` command ("say so once in your reply and wait") ends the turn. Follows from #245, but stands alone. | Proposed: "Worker: when an org command fails, the turn still ends in a state an answer can reach" |
| 5 | The secretary went `done` at its prompt 17 s after asking the approval, with work and an approval in `org-state`; the template says to end such a turn in `org wait --children` (Prototype 2 saw it stay `working`). The operator saw its pane: the secretary had found that the worker's `report start` and `report blocked` failed with exit 5, and ended its turn to ask the person whether to send the answer with `hc send` or to stop and fix. | A question to the person about the #245 stop, not a silent idle. | None |
| 0 | `notes-off` FAIL at `prepare`. | Host configuration, not the loop. | None |
| Runbook | `5-approval` passes on the history line alone; the card is checked only by eye, so a PASS there does not mean the card was on the screen. | By design (the runbook cannot see the window). Kept; the screen is a note. | None |
| Runbook | `evidence/summary.txt` held no step results: `watch` was stopped with Ctrl-C, which writes no summary, and `collect` read only the summary. The results above are from the run folder's per-step files. | Runbook gap. Fixed: `collect` prints each step's result file, then the summary if there is one. | None |

Not exercised by this run: the answer through the card, the review gate and its `excludedCommands` (#242), the round counter, the pull request and the acceptance job (#240).

New Issues for the secretary to file: the one marked "Proposed" above. #244, #245, #246 and #247 are filed. The run is to be repeated once #245 and #246 are fixed.

### Run 2

Run 2026-11-11 (after #244 to #247 were fixed), task `p3-202611111819`, paddock `main` at `63c8e54`. Versions: hc 0.1.18, herdr-app 0.1.15, Claude Code 2.1.322, codex-cli 0.157.0, gh 2.96.0. The fixture was the same throwaway repository; the person was the owner, acting through the card. The run is recorded from the run folder's evidence (`evidence/summary.txt`, `notes.tsv`, `watch.log`).

**The loop held, with one failed check.** The request reached a worker, the worker's question showed on the card and was answered there with Yes, the worker finished, and a pull request (PR #3 in the throwaway repository) passed the acceptance job. Of the 21 steps, 20 pass. The person's only action was Yes on the card: no `note --touch`, and neither terminal showed a prompt or dialog during the watch (`10-no-touch` PASS). G1 holds for this loop on `main` at `63c8e54`, except for the review record below.

| Step | `RESULT` |
| --- | --- |
| 0 | `preconditions`, `notes-off`, `worker-token`, `codex-cli`: PASS. |
| 1 | `1-secretary`, `1-placed-files` (the 8 files equal the checkout): PASS. No trust dialog (the folder was trusted in run 1). |
| 2 | `2-request`: PASS (sent by the runbook with `hc send`; the person typed nothing). |
| 3 | `3-worktree`, `3-own-settings`: PASS. |
| 4 | `4-worker`, `4-worker-report` (`run_started` in the worker's own file), `4-work-entry`: PASS. This is the step that failed in run 1 (#245). |
| 5 | `5-blocked`, `5-approval` (`p3-202611111819-20261111T182040Z`): PASS. |
| 6 | `6-card-answer`: PASS (`ANSWER ... yes` in the person's file). |
| 7 | `7-secretary-read`, `7-forwarded`, `7-approval-removed`: PASS. |
| 8 | `8-test-commit` (first own commit `f0d4c1f`, declares and changes only `tests/paddock-proto3.test.sh`), `8-done`, `8-secretary-read`: PASS. **`8-review`: FAIL**, see below. |
| 9 | `9-pull-request` (PR #3 on `work/p3-202611111819`), `9-ci-record` (run `43077301980`, exit 0), `9-acceptance` (`ACCEPTANCE: pass`): PASS. |
| 10 | `10-no-touch`: PASS. |

**`8-review` FAIL.** The runbook found one `codex_round_started` line from `codex-gate` ("diff round 1 of 3"), but the gate writes nothing when a round ends, so the history cannot say how the round ended. The check then falls back to the worker's done report, which says "Second-model review gate last line: passed (succeeded=2 failed=0 status=0), no findings" and does not quote the literal `CODEX_GATE: passed`. So the review very probably ran and passed, but nothing a reader can verify afterwards records that. The cause is in the gate, not the worker: Issue #253 (the gate keeps no result record).

Times (UTC, from the history, the status log and the pull request):

| What | When | Delay |
| --- | --- | --- |
| Request sent | 18:20:03 | |
| `run_started` by the secretary, `work_added` | 18:20:11, 18:20:13 | 8 s, 10 s |
| Worker terminal `working` | 18:20:14 | 11 s |
| `run_blocked` by the worker, `approval_asked` | 18:20:34, 18:20:41 | 20 s, 7 s later |
| `ANSWER yes` in the person's file (the click) | 18:22:27 | 1 min 46 s after `approval_asked` |
| Secretary's `ack` of the answer, answer forwarded, `approval_removed` | 18:22:32, 18:22:35, 18:22:35 | 5 s, 8 s |
| Worker's `ack` of the answer | 18:22:41 | 14 s |
| `codex_round_started` (diff round 1 of 3) | 18:22:45 | |
| `run_completed` | 18:23:06 | 31 s after the forward; 21 s after the round started (an upper bound for the review) |
| Pull request created | 18:23:20 | 14 s after `run_completed` |
| `ci_completed` (exit 0) | 18:23:35 | 15 s after the PR |

From the request to a passing acceptance job: 3 min 32 s, of which the person's wait on the card is 1 min 46 s. The note for the click reads 18:23:00 because the owner reported it in chat; the `ANSWER` line is the time used here.

Setup touches (not part of the loop, and not typed by the person): `org-start` and `layout.switch` were run by the operator's assistant from its shell, not by the person (note at 18:19:59). The core was already running. The folder-trust dialog did not show, because the folder was trusted in run 1.

Failed steps:

| Step | What happened | Cause | Issue |
| --- | --- | --- | --- |
| 8 | `8-review` FAIL: one round counted, no record of how it ended; the done report does not quote `CODEX_GATE: passed`. | The gate keeps no result record. | #253 |

Run 1's four stops (#244 to #247) did not recur. Not seen by this run: a round that ends with findings, `CODEX_ROUND_DENIED`, and a review that ends `not-established`. The gate's `excludedCommands` calls worked: the review ran without a permission prompt.

### Run 3

Run 2026-11-12 on `main` at `31adf37` (after #255 to #262), a clean checkout, with the same throwaway repository. **The owner stopped it during setup, before the request was sent.** No step from 2 on ran, so there is no evidence folder from `watch` or `collect`; this record is the operator's observations on the host. G1 is not met: the loop did not get as far as a worker. The times below are the host's local clock; the run ids are UTC (`prepare` names them), which is why `p3-202611120352` and the 12:50 holder start are the same hour.

| Step | What happened |
| --- | --- |
| 0 | First `prepare` (`p3-202611120352`): `notes-off` FAIL (the core's config folder did not exist) and `worker-token` FAIL. The person wrote the core's config by hand, created and saved a read-only token, and ran `prepare` again (`p3-202611120404`): all PASS. |
| 1 | `org-start` started the secretary's terminals (three tried) and each ended at once with `sh: 1: exec: claude: not found`, exit 127. The setup had to be restarted from outside herdr (stop 2 below). |
| 1 | The screen: `layout.switch` failed (stop 4). |
| 2 to 10 | Not reached. |

Not exercised by this run: everything the runbook checks from step 2 on. Run 2's result for those steps stands for `63c8e54`; #253's fix (#256) and the changes since (#257, #261, #262) were not run together.

Touches and stops (all before the request; each is a person acting by hand, which the pass line forbids):

| # | Step | What happened | Cause | Issue |
| --- | --- | --- | --- | --- |
| 1 | 0 | `notes-off` FAIL: the person wrote the core's `config.toml` by hand. | `prepare` only reports it; nothing sets `notes = false`. | #264 (in progress; not repeated here) |
| 2 | 0 | `worker-token` FAIL: the person created and saved a read-only token by hand. | Setup has no step that makes the worker's token. | #267 |
| 3 | 1 | The secretary's terminals exit 127: `claude: not found`. The template runs `sh -c 'exec claude --settings ...'`, and the terminal's `PATH` is the one the core's holder process had when it started. That holder (started 12:50) had `PATH` without `~/.local/bin`, where `claude` lives, because the core itself had been started at 12:24 as a systemd transient unit with a short `PATH`. `hc server restart` replaces only the server, not the holder, so it did not help; `hc server stop` then `hc server start` from a WSL shell outside herdr replaced the holder and fixed `PATH`. | A terminal inherits `PATH` from a process whose environment the person does not see and cannot change from inside herdr. | #268 |
| 4 | 1 | `org-start` does not say why: the terminal ended with 127, and `org-start` waited 15 s and printed only "secretary has no status". | `org-start` reads the status and not the terminal's exit. | #269 |
| 5 | 1 | `herdr-app do layout.switch` failed: "no Herdr window at `~/.config/herdr-app/herdr-app.sock`". The window is open in the Windows herdr and is not reachable from WSL. | Same split as #246 and #247 (herdr-app on Windows, the core in WSL), now for the socket path the command looks for. | #270 |
| 6 | Runbook | `prepare` and the Run it section (and the Expected findings, around line 84) assume a login shell outside herdr. The pass line wants nobody touching a terminal (G1) and everything running from herdr alone (G5); a login shell outside herdr is a terminal. The owner judged this a defect in the runbook's design. | The runbook's host steps were written for an operator at a shell. | #271 |
| 7 | 0 | Hand preparation before `prepare`: a clone of the throwaway repository, a clean clone of paddock at `origin/main`, the folder-trust check for the workers folder (the folder did not exist yet; the Q13 note), the config and the token (stops 1 and 2). | No setup step covers them. | #267 |

New Issues filed for these stops: #267 (stops 2 and 7, manual preparation), #268 (3, `claude` not on the terminal's `PATH`), #269 (4, `org-start` gives no reason), #270 (5, `layout.switch` and the Windows window), #271 (6, the runbook's shell outside herdr). Stop 1 is #264.

The run is to be repeated once these are fixed. #243 stays open.
