# 0013. A deterministic watcher wakes the secretary on unread mail and worker events

Status: **Proposed** (2026-11-15; all four open questions decided by the owner). Refs #391, #392. This file records the proposal only; nothing is built for it. The owner's answers to its open questions are in [Open questions](#open-questions).

## The question, in plain words

The secretary is a model. Today it is kept awake by rules it must follow itself (end every turn in `org wait --children`, read the mailbox before ending a turn), by a `Stop` hook that enforces them, and by a one-shot nudge typed after each mailbox write. The rules were broken or worked around (#334, rounds 3 and 5); the nudge never fired on the host (#388) and has a race. Should a small loop with no model in it, outside the secretary, notice what waits for the secretary and wake it, so that the secretary holds no wait and needs no hook to stay awake?

## What exists today (checked in this repository)

| Fact | Where |
| --- | --- |
| A resident loop already runs: `org-watch`, kept by `org-start` as the terminal `watcher` (`hc run --bg --keep --no-notify --label paddock_role=watcher`), ended by `org-down`. Each pass (30 s) it reads `hc ls`, `hc get`, `hc read --lines 0` and `org-state`, and tells the person by toast or bell. It types into nothing; its rationale says "a bug here can be noisy, never destructive". | [org-watch SKILL.md](../../skills/org-watch/SKILL.md), [org-watch.sh](../../skills/org-watch/scripts/org-watch.sh), [rationale](../../skills/org-watch/references/rationale.md), [org-start.sh](../../skills/org-start/scripts/org-start.sh) line 288 |
| It already sees a blocked worker with a still secretary ("Incident", Q3's rule) and a terminal that never reported a status ("No status"), and has a ledger (`watcher/told`: key, last told) that tells each item once and again after N minutes. | org-watch.sh `pass`, `tell` |
| Every write addressed to the secretary is followed by `nudge`: `hc send --if idle`, else (secretary `done`, read with `hc get`) a plain `hc send`, retried in the background 5 times every 2 s while the mail is unread. A worker's write cannot reach the core from its sandbox, so its `PostToolUse` hook runs `org nudge` outside it. | [scripts/org](../../scripts/org) `put`, `nudge`; [worker-settings.json](../../templates/worker-settings.json) line 51 |
| The nudge's race: hc 0.1.18's `--if` takes only `idle|working`, so `done` is read and then sent in two steps; a write that lands while the secretary works is refused (exit 10) and the 10 s of retries can run out before the turn ends. | scripts/org `nudge`; [decision 0002](0002-org-mailbox-not-hc-send.md) "Widened by Issue #385" |
| The `Stop` hook refuses an end with unread mail, and (TEMPORARY, #388) an idle end while `org-state` has `work` or `approvals`, telling the secretary to end the turn in `org wait --children`. | [secretary-stop-guard.sh](../../scripts/hooks/secretary-stop-guard.sh) |
| `org wait --children` returns on unread mail, a child ending, the person's typed line or a timeout, and on each return lists workers from `org-state.work` that are `gone`, `waiting` (blocked) or `unreported` (status `done`, no `run_completed` since the latest `run_started`). This check runs only inside the secretary's own wait. | scripts/org `wait`, `watch` |
| hc's notes to a parent are off (`notes = false`, Q2); workers start with `--outlive-parent`, so a renewed secretary is not their parent; the CI child starts with `--no-notify`. So no hc note reaches the secretary today, whatever comment 1 of #391 assumes. | [decision 0002](0002-org-mailbox-not-hc-send.md) Consequences, [Q19](../design/open-questions.md#q19-do-workers-outlive-the-secretary-that-started-them), [org-pull-request.sh](../../skills/org-pull-request/scripts/org-pull-request.sh) line 126 |
| CI: `org-pull-request` starts `hc run --bg --rm --no-notify --name ci-<pr> -- gh run watch ... --exit-status`, then `hc wait ci-<pr>` with no timeout, which checks in after about 180 s. If CI still runs then, the script exits 8 and nobody is left to write `ci_completed` when the child ends: the line is written only by the script that waited, and `--rm` removes the child and its exit code. The secretary must rerun `--pr <n>`. | org-pull-request.sh lines 124-137; [org-pull-request SKILL.md](../../skills/org-pull-request/SKILL.md) exit 8 |
| #392's watch was named `bg-ci-390`, not the skill's `ci-<pr>`, so it may not have been started by the skill; its exit code and output are lost (`--rm`). Why it ended is not known. | #392 body |
| Q18 decided (c), "nothing is typed into an agent", and rejected (b), a wake-up by `hc send --if idle`, partly because "it needs a resident process paddock does not have". `org-watch` is that process now. Architecture §3 says "No dispatcher"; §5 says "Nothing wakes agents". | [Q18](../design/open-questions.md#q18-how-does-anything-reach-an-idle-agent), [architecture §3, §5](../design/architecture.md#3-roles) |

## Proposal

### Who runs it

`org-watch` takes the job, not a separate dispatcher (owner, 2026-11-15, open question 1). It already polls the facts this needs, already has a ledger, and already starts and ends with the organization. A second resident loop would read the same `hc ls` and `org-state` on its own clock and need its own start, stop and ledger.

The cost is that `org-watch` stops being read-only: it types one fixed line into the secretary's or an idle worker's terminal (open question 4), and it runs CI watches (open question 2). The line is a constant per target (no text from a worker or a person is ever typed), and it is sent only on an exact status and never over typed input (open question 3).

### What it notices each pass

Each item becomes one line in the secretary's mailbox (written by the watcher as its own id, `--as watcher`), then a wake. Each line states a recorded fact; none suggests what to do beyond reading it. Each item is written once (ledger key `mail:<kind>:<item>`) and dropped from the ledger when it stops being true.

| Item | Fact it reads | Mailbox line |
| --- | --- | --- |
| Unread secretary mail | `check_messages --peek` for the secretary is not empty (card `ANSWER`, a worker's report or question, the watcher's CI line) | none: the mail is the line; only the wake |
| Unread worker mail | `check_messages --peek` for a `w-<task>` with a live terminal is not empty (an answer forwarded by `org-escalation answer`, a message from the secretary) | none: only the wake (open question 4) |
| Blocked worker | a `task_id` terminal is `blocked` (and, for the person's toast, Q3's still secretary as today) | `w-<task> is blocked` |
| Worker done without a report | status `done`, no `run_completed` to the secretary since its latest `run_started` (the rule `org wait` uses for `unreported`) | `w-<task> is done and sent no report` |
| Worker gone | a `work` entry whose terminal is not found or `finished`, with no done record (`gone`) | `w-<task> has no terminal and sent no done report` |
| No status | a `task_id` terminal with no status N minutes after creation (today's rule) | `w-<task> has reported no status for N minutes` |
| CI result | the watcher's own CI watch for a requested PR head ended ([CI watching](#ci-watching)) | `CI <success\|failure> on PR <n>, head <sha7>, run <id>.` or `CI watch failed on PR <n>, head <sha7>: <reason> (log <path>).` |

The worker checks (done without report, gone) are the ones `org wait`'s `watch` already computes; the build should move that function into an `org` subcommand both can call, not copy it.

### CI watching

The watcher, not the secretary, watches CI (owner, 2026-11-15, open question 2). The secretary holds no `ci-<pr>` child and no wait for CI. This is the predecessor's shape too: its CI watch ran in a dedicated script (the `pr-watch` pane, MON-12 in the [inventory](../design/predecessor-inventory.md)) that wrote the result to the record and notified.

- **How the watcher learns of a PR.** `org-pull-request` pushes, opens the PR and appends one record through `scripts/org --as secretary ci_requested`: `{"kind":"ci_requested","from":"secretary","task_id":"t1","pr":42,"sha":"<head>","repo":"OWNER/NAME"}`. It then exits 0 at once ("CI is watched by the watcher; the result comes as mail"). A rerun with `--pr <n>` on a moved head appends a new request. No `gh pr list`: the record is the list (principle 2).
- **One watch per open request.** Each pass, a request is open when no `ci_completed` or `ci_watch_failed` for the same `pr` and `sha` follows it. For each open request with no live watch (pid file `watcher/ci/<pr>.pid`), the watcher starts `skills/org-watch/scripts/ci-watch.sh --pr <n> --sha <sha> --repo <r> [--task <id>]` as a background process of its own shell, so the pass never blocks. A newer request for the same PR ends the older watch, which writes `superseded`. After a watcher restart, open requests are simply watched again (`gh run watch` on a finished run returns at once).
- **What the watch does.** Finds the run of the head (`gh run list --commit`, retried as today), `gh run watch <run> --exit-status --interval 30`, then reads the run's `conclusion` (`gh run view --json conclusion`) so a `gh` error is not taken for a CI failure. Its output goes to `watcher/ci/<pr>-<sha7>.log`, which keeps the exit code and last output (#392's "find why").
- **Never nothing.** The watch writes exactly one record and one mailbox message, whatever ends it: on a result, `ci_completed` (today's shape, `from: watcher`, written with `scripts/org --as watcher ci_completed`); otherwise `ci_watch_failed` with `reason` (`no_run`, `gh_error`, `signal`, `superseded`), `exit_code` and `log`, written from an `EXIT`/`TERM`/`HUP`/`INT` trap. A watch killed with no chance to trap (`SIGKILL`) leaves its pid gone and no line; the next pass writes `ci_watch_failed` with reason `vanished` for it. Then the message to the secretary, which the unread-mail rule wakes it for.
- **What stays with the secretary.** Reading the result and acting by the approval mode. On a `success` line in `acceptance` mode it reruns `org-pull-request --pr <n>`, which finds the `ci_completed` for the current head, skips watching, and does today's step 6 (head check, required checks, `gh pr merge --match-head-commit`). On `failure` it sends the worker back; on `ci_watch_failed` it reruns `--pr <n>` or tells the person. The watcher never merges.
- **Principle 1.** The watch runs in the watcher's terminal, outside every agent; `ci-watch.sh` is a static file the watcher runs. Nothing in the secretary has to stay awake for the result.

### How it wakes

- **Who is woken.** The secretary, and every `w-<task>` worker with unread mail (open question 4). The same rules below hold for each target.
- **One typed line, constant per target:** for the secretary `You have mail: run bash scripts/org --as secretary check_messages and act on it.` (the line `nudge` sends today); for a worker `You have mail: run bash "$PADDOCK_ORG" --as w-<task> check_messages and act on it.` No text from a worker or a person is ever typed.
- **Never into a working target.** `hc send --if idle`; for `done`, `hc get` and then a plain `hc send` (hc has no `--if done`). `working`, `blocked`, no status, or not found: no send this pass.
- **Never over typed input (open question 3).** Just before a send, the watcher reads the target's last screen line once (`hc read --lines 1`); when it holds typed input after the prompt marker, that pass sends nothing and the next pass tries again. One read per wake attempt, and only to decide not to type: the screen never says whether to wake or what the status is.
- **No race by retry, not by timing.** The loop looks again every pass while the mail stays unread, so a write during a working turn is announced on the first pass after the turn ends.
- **Rate limit per unread batch.** A batch is keyed by the highest unread `seq` per sender. At most one wake per batch per `PADDOCK_WATCH_WAKE` seconds (proposed default 60). New mail is a new batch and is woken on the next pass.
- **Log.** Each wake and each mailbox line is printed on the watcher's terminal and appended to `watcher/woke` in the state folder: time, target, batch key, the status read, whether typed input held it off, the send's exit code.

### What stays with the secretary

All judgment. Waking a worker is not answering it: the worker reads what the secretary sent. The watcher does not answer a worker, close one, press a key, rerun a skill, merge, or choose which item matters. It writes facts into the mailbox and types one constant line. The secretary reads the mailbox on its turn and decides, as today.

The secretary then ends its turns idle. `org wait` stays as a manual tool (a person or a skill may still call it); nothing requires it.

### Staged replacement

1. **Beside.** Build the watcher's wake, mailbox lines and CI watch; keep the secretary's wait, the `Stop` hook and the per-write nudge as they are. The secretary inside `org wait` is `working`, so the watcher does not type into it; the per-write nudge and the watcher may both announce the same mail to an idle secretary (harmless, one extra `check_messages`). `org-pull-request` writes `ci_requested` and still watches CI itself as today, so each head gets two results: the skill's (`from: secretary`) and the watcher's (`from: watcher`).
2. **Compare.** On the host, run the [host checks](#host-checks) and read `watcher/woke` against the secretary's `check_messages` acks: every unread batch must be read, and every worker event must have its mailbox line, within one pass of the secretary going idle. Every `ci_requested` must have exactly one watcher line, and where the skill also recorded one, the two agree.
3. **Remove.** In one change: the template's wait rule (it becomes a hint: "check the mailbox at the end of a turn"), the `Stop` hook's work hold and its unread-mail refusal, the per-write `nudge` in `scripts/org` and the worker's `PostToolUse` hook that calls it; the worker nudge after `org-escalation answer` (#282); once host check 8 has passed, the worker's own wait after `report blocked` becomes a hint (owner, 2026-11-15); and `org-pull-request`'s own watch (steps 3 to 5: run lookup, the `ci-<pr>` child, `hc wait`, its `ci_completed` write, exits 7, 8 and 12 for those). `org wait` and its `--children` stay as commands.

On acceptance, Q18 is reopened and amended toward a wake by a resident process; decision 0002's #385 paragraph is replaced by a pointer here; architecture §3 and §5 and `org-watch`'s "types into nothing" are corrected.

### Host checks

These are the "Done when" of #391, with nobody typing into the secretary:

1. A card answered while the secretary is idle is read within one pass.
2. A worker report arriving while the secretary is idle is read within one pass.
3. A write during a working turn is read after that turn ends, within one pass.
4. A worker that ends without a report is noticed and handed to an idle secretary within one pass, the secretary holding no wait.
5. The watcher never types into a working secretary (`watcher/woke` shows no send whose status read was `working`, and the secretary's screen shows no joined line mid-turn).
6. From #392: a normal host watch records `ci_completed` for the requested head and the secretary is woken with its line.
7. From #392: a watch that fails (no run for the head, `gh` error, the watch process killed) still leaves one `ci_watch_failed` line and a mailbox message.
8. An answer forwarded to an idle worker by `org-escalation answer` is read by it within one pass, with no #282 nudge.
9. With a half-typed line in the secretary's prompt, no wake is typed; once the line is sent or cleared, the next pass wakes it if mail is still unread.

## Why

- **Principle 1 (nothing runs inside the watched agents).** The wait is a rule the model must keep; the `Stop` hook and the worker's `PostToolUse` hook are moving parts on files an agent can reach. The watcher is outside both.
- **Principle 2 (recorded facts, not screens).** Every trigger above is the mailbox history or hc status. One stated exception (open question 3): the last screen line is read once per wake attempt, only to decide not to type over a person's input; it never stands in for a status or a reason to wake, and a skipped pass is simply retried on the next one.
- **Principle 3 (judgment with the secretary).** The watcher only notices and wakes.
- **Principle 4 (in stages).** Today's behaviour stays until the comparison shows the watcher covers it.
- **The race goes away.** A one-shot sender has to be right at the moment of the write; a loop only has to be right once in the minutes that follow.

## Costs accepted

- `org-watch` types into a terminal. A bug can now wake the secretary needlessly (a turn and its cost), bounded by the per-batch rate limit.
- Latency: up to one pass (30 s) plus the rate limit for a repeat. Today's per-write nudge is faster when it works.
- The input check reads a screen line, so it can misjudge: a false "input" delays a wake by a pass; a missed one joins the line to the person's input (decision 0002's measurement). Bounded to one read per attempt.
- The watcher lives in the core: if the core stops, nothing wakes the secretary (as in [0008](0008-who-tells-the-person-outside-the-window.md)). If the watcher terminal ends, the secretary is woken by nothing until `org-start` is rerun; stage 3 makes that a real loss, where today the secretary's own wait would still run.
- The watcher now uses `gh` and the network with the person's own login (the kept terminal's environment), and holds one `gh run watch` per open request (polling every 30 s). It is no longer a loop that only reads the core.
- While the watcher is down, no CI is watched; open requests are watched again when it comes back, so a result is late, not lost.
- Known limit kept from today: when a head has several runs, only the newest found is watched; `acceptance` still relies on the required checks at merge time.

## Text this decision makes stale

This record is Proposed and changes no file. The implementation PR fixes each place below in the same change (or says in its body why not). Lines are as of 3a04e71. "Stage 3" places change only with the removal; "watcher" places change when the watcher starts typing (stage 1).

| Place | What must change |
| --- | --- |
| [templates/secretary.md](../../templates/secretary.md):28 | Stage 3: drop "never end a turn idle ... end every such turn in `org wait --children`" and the `Stop`-hook sentence; keep the return-reason handling only for a manual `org wait`; say the watcher wakes it. |
| templates/secretary.md:29 | Stage 3: drop "while you wait, the person sees your Bash call running" (no routine wait). |
| templates/secretary.md:30 | Stage 3: "Only `org wait` may hold you ... await it with `org wait --children`" becomes: run it in a background terminal and end the turn; the watcher wakes you. |
| templates/secretary.md:31 | Stage 3: the per-write nudge paragraph becomes the watcher's wake line, and the `Stop`-hook and TEMPORARY sentences go. |
| templates/secretary.md:26 | Stage 3: "Check the mailbox at the end of every turn" stays as a hint only. |
| templates/secretary.md:79 | Stage 3: the Pull request lead says the skill "watches CI as a background child (`hc wait ci-<pr>`), records `ci_completed`, then acts": it pushes, opens the PR and writes `ci_requested`; the watcher's line wakes you; in `acceptance` mode `--pr <n>` then merges. |
| templates/secretary.md:81 | Stage 3: "Exit 0 in `human` mode ... Exit 0 in `acceptance` mode: it merged" now means "PR opened, CI requested"; the merge comes from the `--pr <n>` rerun after the success line. |
| templates/secretary.md:83 | Stage 3: "CI is watched only by the script's child and your `org wait --children`", the exit 8 timeout and `--pr` rerun text: the watcher watches CI; act on its `ci_completed` or `ci_watch_failed` message. |
| templates/secretary.md:84-85 | Stage 3: "quote the CI result the script printed" becomes the watcher's line; exit 9 and 10 move to the `--pr` rerun. |
| [templates/secretary-settings.json](../../templates/secretary-settings.json):10 | Stage 3: remove the `Stop` hook entry. |
| [scripts/hooks/secretary-stop-guard.sh](../../scripts/hooks/secretary-stop-guard.sh) (whole file) | Stage 3: delete. |
| [skills/org-start/scripts/org-start.sh](../../skills/org-start/scripts/org-start.sh):174 | Stage 3: stop copying `secretary-stop-guard.sh`. |
| [scripts/hooks/secretary-bash-guard.sh](../../scripts/hooks/secretary-bash-guard.sh):45 | Stage 3: `wait_hint` says "then end the turn in org wait --children"; it becomes "then end the turn". |
| [scripts/org](../../scripts/org):218 | Stage 3: remove the `nudge` call in `put`. |
| scripts/org:221-243 (`nudge()`) and :280-283 (`nudge` command), :116 (command list) | Stage 3: remove; the watcher's wake replaces it. |
| scripts/org:386-388 (`wait` comment "the secretary ends its turns here") and :26-35 (usage) | Stage 3: `wait` is a manual tool; its `watch` moves to a subcommand the watcher also calls. |
| [templates/worker-settings.json](../../templates/worker-settings.json):51 | Stage 3: remove the `PostToolUse` hook that runs `org nudge`. |
| [skills/org-watch/SKILL.md](../../skills/org-watch/SKILL.md):3, :26 | Watcher: "Read-only" and "It types into nothing" become: it writes mailbox lines as `watcher` and types one line into an idle or done secretary. Add the new items and `watcher/woke`. |
| [skills/org-watch/references/rationale.md](../../skills/org-watch/references/rationale.md):4 | Watcher: "read only ... nothing typed into a terminal ... never destructive" is replaced by why the one typed line is safe. |
| [skills/org-watch/scripts/org-watch.sh](../../skills/org-watch/scripts/org-watch.sh):17 | Watcher: the usage line "it never types into a terminal". |
| [README.md](../../README.md):18 | Watcher: "a read-only shell loop" and what it does. |
| [skills/org-pull-request/SKILL.md](../../skills/org-pull-request/SKILL.md):3 | Stage 3: description "watch its CI as a background child terminal, record ci_completed" becomes "write ci_requested; the watcher watches". |
| skills/org-pull-request/SKILL.md:21-24 | Stage 3: steps 3 to 5 (run lookup, `ci-<pr>` child with `hc wait`, the `ci_completed` write) move to `ci-watch.sh`; the skill writes `ci_requested` (stage 1 adds it beside them). |
| skills/org-pull-request/SKILL.md:25-27 | Stage 3: step 6 runs on `--pr <n>` once a `ci_completed` for the current head exists. |
| skills/org-pull-request/SKILL.md:35, :40, :41, :42, :45 | Stage 3: exit 0 meaning, exit 7 (no run), exit 8 (watch unreadable, timeout, `--pr` rerun), exit 9 (CI failed, now read from the record), exit 12 (the events line) change or go. |
| skills/org-pull-request/SKILL.md:47-49 | Stage 3: "Watching CI without holding the secretary" is replaced by a pointer to the watcher. |
| skills/org-pull-request/SKILL.md:57 and "Not measured" | Stage 3: the several-runs limit and the unmeasured `gh run watch` through `hc wait` move to `ci-watch.sh`. |
| [skills/org-pull-request/scripts/org-pull-request.sh](../../skills/org-pull-request/scripts/org-pull-request.sh):3, :13, :22, :114-139 | Stage 1: append `ci_requested`. Stage 3: remove the run lookup, the `ci-<pr>` child, `hc wait` and the `ci_completed` write; with `--pr`, read the recorded result for the current head instead. |
| [skills/org-pull-request/references/rationale.md](../../skills/org-pull-request/references/rationale.md):3, :4, :6 | Stage 3: "CI is watched as a background child terminal" and "the events line goes through the secretary's own writer" are replaced; "recorded for a failed run too" moves to `ci-watch.sh` and widens to `ci_watch_failed`. |
| [scripts/org](../../scripts/org):19, :352-371 | Stage 1: add `ci_requested` and `ci_watch_failed`; `ci_completed`'s comment ("org-pull-request records the watched CI run here") names the watcher. |
| [tests/org-pull-request.test.sh](../../tests/org-pull-request.test.sh), [tests/org-pull-request-gate-line.test.sh](../../tests/org-pull-request-gate-line.test.sh), [tests/org-pull-request-review.test.sh](../../tests/org-pull-request-review.test.sh) | Stage 3: the stubbed `hc wait`/`gh run watch` cases move to a `ci-watch` test. |
| [docs/design/open-questions.md](../design/open-questions.md):308, :324, :732 | On acceptance: `ci_completed` written by org-pull-request; "Waking on CI completion"; "a CI result becomes a child by being watched through a child terminal". |
| [docs/design/architecture.md](../design/architecture.md):68 | On acceptance: "CI watched as a background child with `hc wait`" becomes "CI watched by the watcher". |
| [docs/decisions/0002-org-mailbox-not-hc-send.md](0002-org-mailbox-not-hc-send.md):26, :31 | On acceptance: replace the #385 paragraph with a pointer here; "The secretary does so at the end of every turn" becomes "when the watcher wakes it". |
| [docs/decisions/0008-who-tells-the-person-outside-the-window.md](0008-who-tells-the-person-outside-the-window.md):63 | On acceptance: a note that the watcher now also wakes the secretary (0013). |
| [docs/design/open-questions.md](../design/open-questions.md):727-741 (Q18) | On acceptance: amend toward (b) by a resident process; the "needs a resident process paddock does not have" reason no longer holds. |
| docs/design/open-questions.md:61 (Q2), :322 | On acceptance: "may block on `hc wait --children`" and "learns of the exit from `org wait --children`" become the watcher's lines. |
| [docs/design/architecture.md](../design/architecture.md):34, :75, :87 | On acceptance: "No dispatcher", "Nothing wakes agents: the secretary waits with `org wait --children`", and step 5 "each time its `org wait` returns". |
| [docs/design/routine-procedures.md](../design/routine-procedures.md):15, :36, :44 | Stage 3: "On each return of `org wait`" becomes "on each wake". |
| [tests/org-nudge-secretary.test.sh](../../tests/org-nudge-secretary.test.sh), [tests/secretary-stop-guard.test.sh](../../tests/secretary-stop-guard.test.sh), [tests/org-wait.test.sh](../../tests/org-wait.test.sh):148-149, [tests/org-commands.test.sh](../../tests/org-commands.test.sh):142-143 | Stage 3: remove or rewrite with the code they test; the template's nudge line check follows the watcher's line. |

Worker wake (open question 4), stage 3:

| Place | What must change |
| --- | --- |
| [skills/org-escalation/SKILL.md](../../skills/org-escalation/SKILL.md):60 | The `hc send --if idle` to an idle worker after the send goes; the watcher wakes it. |
| [skills/org-escalation/scripts/org-escalation.sh](../../skills/org-escalation/scripts/org-escalation.sh):384-387 | Remove the #282 send. |
| [skills/org-escalation/references/rationale.md](../../skills/org-escalation/references/rationale.md):7 | "An idle worker is nudged once" is replaced by a pointer to the watcher. |
| [templates/worker-rules.md](../../templates/worker-rules.md):38 | "the secretary nudges an idle worker once after an answer, but a nudge can be refused" becomes the watcher's wake. |
| [docs/decisions/0002-org-mailbox-not-hc-send.md](0002-org-mailbox-not-hc-send.md):24 | On acceptance: the #282 paragraph is replaced by a pointer here. |
| [tests/org-answer-wakes-idle-worker.test.sh](../../tests/org-answer-wakes-idle-worker.test.sh) | Rewritten against the watcher's wake. |
| [templates/worker.md](../../templates/worker.md):23, [templates/worker-rules.md](../../templates/worker-rules.md):41-47 | Stage 3, gated on host check 8: the worker's own `wait` after `report blocked` (and after a failed `org` command) becomes a hint; it stays a rule until that check passes. |

The prototype reports in `docs/design/prototype-*.md` record past runs and stay as they are.

## Open questions

1. **Does `org-watch` take the wake job, rather than a separate dispatcher terminal?** **Decided (owner, 2026-11-15): Yes.** Recommended was Yes. It already reads every fact needed, has the ledger and the start/stop wiring; a second loop doubles that for one constant line. Yes: `org-watch` gains the mailbox lines and the wake, and loses its "types into nothing" property. No: a new kept terminal (for example `dispatcher`) with its own script, ledger and `org-start`/`org-down` wiring; `org-watch` stays read-only.
2. **Should the watcher also read CI state of open PRs from GitHub directly, instead of only noticing a `ci-<pr>` watch that ended without `ci_completed`?** **Decided (owner, 2026-11-15): Yes, and further: the watcher owns CI watching itself** (see [CI watching](#ci-watching)). The secretary no longer watches CI with a background terminal; #392 (a watch that vanishes without telling) is closed by this shape, since the watcher owns the watch and always writes a line. Recommended was No (no network or login in the loop); the owner chose the stronger shape, and its costs are listed above.
3. **Should the watcher hold off the wake while the person has typed something into the secretary's prompt?** **Decided (owner, 2026-11-15): Yes.** Recommended was No. Before each wake the watcher reads the target's last screen line and skips that pass when it holds typed input ([How it wakes](#how-it-wakes)). This is a stated exception to principle 2: the screen is read only to decide not to type, never to infer status, once per wake attempt, retried on the next pass.
4. **Should the watcher wake idle workers with unread mail too (and so replace the worker nudge after `org-escalation answer`, #282)?** **Decided (owner, 2026-11-15): Yes.** Recommended was No. Idle `w-*` workers with unread mail are woken with the same rule, the same rate limit and the same input check; the #282 nudge is removed in stage 3.

## What is not measured

- Nothing here was run. This record was written in a worker sandbox with no core reachable; every `hc` fact is from the code and documents cited.
- Whether `hc send` to a `done` secretary always lands (the #388 question) is still open; the build's first host probe must confirm it before stage 2.
- Why `bg-ci-390` ended without a line (#392).
