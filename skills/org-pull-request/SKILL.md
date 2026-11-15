---
name: org-pull-request
description: Push a finished worker branch, open the PR and record ci_requested so the watcher watches its CI; rerun with --pr to act on the watcher's ci_completed for the current head, stopping for the person (human) or merging on that exact head (acceptance). Run it from the secretary.
---

# org-pull-request

Pushes a finished worker branch and opens its PR. Why it is built this way: [references/rationale.md](references/rationale.md). The secretary runs it once a worker has reported done, from a shell in its own terminal (unlike [org-start](../org-start/SKILL.md), it is meant to run inside an agent).

```sh
bash skills/org-pull-request/scripts/org-pull-request.sh \
  --worktree <worker worktree> --title "<English title>" --body-file <file> [--task-id <id>] [--mode human|acceptance] [--project <name>]
```

Bash only, plus `git` and `gh`. `--repo OWNER/NAME` is taken from a GitHub `origin` URL when it is not given, and is never guessed otherwise (exit 2).

## What it does

1. Pushes: `git push origin <branch>` from the worktree.
2. Opens the PR: `gh pr create --repo <r> --head <branch> --base main --title ... --body-file ...` (or `--body`). `--pr N` reuses an open PR instead (the rerun that acts on CI).
3. Reads the CI state of the head from the records, this calendar month and the last ([decision 0004](../../docs/decisions/0004-records-documents-and-jsonl.md)): the secretary's latest `ci_requested` for the same `repo`, `pr` and `sha`, and [org-watch](../org-watch/SKILL.md)'s latest `ci_completed` or `ci_watch_failed` at or after it (decision 0013, `docs/decisions/0013-watcher-wakes-the-secretary.md`). A `ci_completed` the skill wrote itself before (`from: secretary`) does not count.
   - No request, or the watch failed: appends one `ci_requested` (`bash scripts/org --as secretary ci_requested --pr <n> --sha <head> --repo <r> [--task <id>]`); the watcher watches CI and mails its line. A request still open is never written twice, so a rerun does not make the watcher report a head twice. Exit 0 without `--pr` (PR opened), exit 4 with it.
   - A request with no result yet: exit 4 (nothing written).
   - `--recheck` (with `--pr`): a recorded result is set aside and the head is requested again, for CI rerun on the same commit after a failure; still never while a request is open.
   - The watcher's `ci_completed`: `failure` exits 9; `success` goes on to step 4.
   `{"seq":1,"ts":"2026-11-10T01:02:03Z","kind":"ci_requested","from":"secretary","task_id":"t1","pr":42,"sha":"<head>","repo":"o/r"}`
4. Acts by the approval mode, then prints the outcome.
   - `human`: prints `PR_URL=...` and that the person decides; merges nothing. Exit 0.
   - `acceptance`: there is no local gate. The check is the repository's CI as a required status check: the `acceptance` job. The script only checks that the PR head (`gh pr view --json headRefOid`) still equals the watched sha and that `gh pr checks --required --watch` (it waits for other workflows of the head still running) is green, then runs `gh pr merge <n> --squash --match-head-commit <sha>`. No `--admin`, no `--auto`.
5. After that merge, when the worktree shares the paddock folder's git store (a landing in paddock itself), it runs `bash skills/org-start/scripts/org-start.sh --place-only --from-origin <base>`, the base read from the PR (`gh pr view --json baseRefName`): the changed templates, `secretary-settings.json` and bin scripts are placed again from that fetched branch, and nothing is started (see [org-start](../org-start/SKILL.md)). Its output says what changed; a `RENEWAL NEEDED` line means `secretary.md` changed, which reaches only a new secretary: ask the person to renew it. If placing fails, exit 13 (the PR is merged).

The mode is `--mode`, else `merge_approval_mode` in `org-config.md` (read with `org config get merge_approval_mode`; change it with `org config set`), else `human`. Any other value means `human`.

## Exit codes

| Code | Meaning | What the secretary does |
| --- | --- | --- |
| 0 | No `--pr`: PR opened, CI requested. `--pr`, `human`: the watcher recorded CI green, the person decides. `--pr`, `acceptance`: merged. | End the turn; the watcher's line wakes you (first run). Tell the person the PR URL (human) or close the worker (merged). |
| 2 | Bad argument. | Fix the call. |
| 3 | `git` or `gh` not found. | Report to the person. |
| 4 | `--pr`: no CI result recorded for the head yet (requested now, again after a failed watch, or still watched). | End the turn; rerun with `--pr <n>` on the watcher's line. |
| 5 | Push failed. | Report; nothing was opened. |
| 6 | PR could not be created. | Report; the branch is pushed. |
| 9 | The watcher recorded CI failed on the head. | Send the worker back with the failure; never merge. If CI was rerun on the same commit instead, rerun with `--pr <n> --recheck`. |
| 10 | Merge refused: head moved after the watched run, or required checks not green. | Rerun with `--pr` so the new head is requested. |
| 11 | `gh pr merge` failed. | Report. |
| 12 | The `ci_requested` line could not be written; nothing watches the PR. | Report. |
| 13 | Merged, but placing the files again failed. | Run the printed `org-start.sh --place-only --from-origin <base>`; if it fails again, report. |

## CI is watched by the watcher

While a shell call runs, the secretary takes no input, so this script holds no watch: [org-watch](../org-watch/SKILL.md) runs `ci-watch.sh` for each open request and always writes one `ci_completed` or `ci_watch_failed` and one mailbox line. The secretary never watches CI with `gh pr checks --watch` or a sleep loop by hand. When it tells the person about the PR, it quotes the watcher's line (the `ci_completed` conclusion), never a worker's local test run.

## Assumptions (open points left open)

- Approval mode lives in `org-config.md`, not in `org-state`.
- The events folder is `scripts/org`'s: `$PADDOCK_STATE_DIR/events`, default `${XDG_STATE_HOME:-~/.local/state}/paddock/events`. The writer id is `secretary`, and `seq` is `scripts/org`'s for that id: one more than the highest so far, taken under the per-id lock, so it never repeats a number a reader has acknowledged. Its `ci_requested` lines carry `kind`, `from`, `task_id` (when given), `pr`, `sha` and `repo` beyond `seq` and `ts` (`ts` follows `$PADDOCK_NOW` when set). Request and result are matched by `ts`, which has whole seconds: a request is open only when it is later than the watcher's last line for that head, so a re-request in the same second as a `ci_watch_failed` waits for the next second.
- The base branch is `--base`, else the base in the `--project <name>` row of `projects.md` (same file and columns as [org-delegate](../org-delegate/SKILL.md); only the base is read, since `--worktree` is the worker's), else `main`. An unknown name or a missing file exits 2 before the branch is sent anywhere. The title and body are written by the secretary in English. With `--task-id` and no `--pr`, the script also reads the task's last diff-review record in the `codex-gate` history (`codex_round_passed` / `codex_round_failed`); unless it is passed, or there is none, it appends "Second-model review did not run" and that record to the body it sends (the body file is not changed), so a body written without it still says so. The secretary still writes the worker's gate line in the body and in its report.
- `--task-id` may hold only letters, digits, `.`, `_` and `-` (it goes into a JSON line); anything else exits 2 before the push.
- Known limit (of `ci-watch.sh`): when a head has several runs, only the newest one found is watched and recorded. In `human` mode "CI green" means that run; in `acceptance` mode the required checks cover the rest.
- Known limit: the final line "Merged" means `gh pr merge` succeeded. On a branch with a merge queue that only enqueues the PR; the script does not query the merge state afterwards. This repository has no merge queue.
- `gh pr checks --required` exits non-zero when a required check fails, is pending, or none is configured; all of those refuse the merge.
- Reviews are not handled here. The row's "handles review" and "closes the worker" stay with the secretary template.

## Not measured

Everything is tested against a stubbed `gh`, records written with `scripts/org --as watcher` as `ci-watch.sh` writes them, and a local bare repository as origin (`tests/org-pull-request.test.sh`). Not run on a host: a real push, `gh pr create`, `gh pr checks --required` with branch protection, `gh pr merge --match-head-commit`, and a real `merge_approval_mode`. The CI watch itself is `ci-watch.sh`'s (see org-watch).
