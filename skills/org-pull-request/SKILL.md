---
name: org-pull-request
description: Push a finished worker branch, open the PR, watch its CI as a background child terminal, record ci_completed, then stop for the person (human) or merge on the exact watched head (acceptance). Run it from the secretary.
---

# org-pull-request

Implements inventory row [SK-6](../../docs/design/predecessor-inventory.md). The secretary runs it once a worker has reported done, from a shell in its own terminal (unlike [org-start](../org-start/SKILL.md), it is meant to run inside an agent).

```sh
bash skills/org-pull-request/scripts/org-pull-request.sh \
  --worktree <worker worktree> --title "<English title>" --body-file <file> [--task-id <id>] [--mode human|acceptance] [--project <name>]
```

Bash only, plus `git`, `gh` and `hc`. `--repo OWNER/NAME` is taken from a GitHub `origin` URL when it is not given, and is never guessed otherwise (exit 2).

## What it does

1. Pushes: `git push origin <branch>` from the worktree.
2. Opens the PR: `gh pr create --repo <r> --head <branch> --base main --title ... --body-file ...` (or `--body`). `--pr N` reuses an open PR instead (a rerun after a failure).
3. Finds the CI run of the pushed head: `gh run list --commit <sha>`, retrying while none exists yet (`PADDOCK_RUN_TRIES`, default 10, every `PADDOCK_RUN_SLEEP`, default 6 s; exit 7 when none appears).
4. Watches it as measured in [MON-12](../../docs/design/predecessor-inventory.md) ([probe](../../scripts/probes/ci-watch-child.sh)): `hc run --bg --rm --no-notify --name ci-<pr> -- gh run watch <run-id> --repo <r> --exit-status`, then `hc wait ci-<pr>`, and reads the integer `exit_code` from its one JSON line. A line without one (a kill sets `signal`) exits 8.
5. Appends one `ci_completed` line to `events/<YYYY-MM>/secretary.jsonl` through `bash scripts/org --as secretary ci_completed` (Issue #168: the secretary's folder, sequence and lock) ([decision 0004](../../docs/decisions/0004-records-documents-and-jsonl.md)), for a failed run too:
   `{"seq":1,"ts":"2026-11-10T01:02:03Z","kind":"ci_completed","writer":"secretary","task_id":"t1","pr":42,"sha":"<head>","run_id":777,"exit_code":0,"conclusion":"success"}`
6. Acts by the approval mode, then prints the outcome.
   - `human`: prints `PR_URL=...` and that the person decides; merges nothing. Exit 0.
   - `acceptance`: there is no local gate ([Q11](../../docs/design/open-questions.md#q11-what-happens-to-the-predecessors-python-gates-and-generators), decided (d); inventory [GT-1](../../docs/design/predecessor-inventory.md)). The check is the repository's CI as a required status check. The script only checks that the PR head (`gh pr view --json headRefOid`) still equals the watched sha and that `gh pr checks --required --watch` (it waits for other workflows of the head still running) is green, then runs `gh pr merge <n> --squash --match-head-commit <sha>`. No `--admin`, no `--auto`.

The mode is `--mode`, else `merge_approval_mode` in the `org-state` document (read with `doc.get` through `hc connect`), else `human`. Any other value means `human`.

## Exit codes

| Code | Meaning | What the secretary does |
| --- | --- | --- |
| 0 | `human`: CI green, the person decides. `acceptance`: merged. | Tell the person the PR URL (human) or close the worker (merged). |
| 2 | Bad argument. | Fix the call. |
| 3 | `git`, `gh` or `hc` not found. | Report to the person. |
| 5 | Push failed. | Report; nothing was opened. |
| 6 | PR could not be created. | Report; the branch is pushed. |
| 7 | No CI run for the head. | Check the repository has a workflow; rerun with `--pr`. |
| 8 | Watch result unreadable (no `exit_code`). | Rerun with `--pr`. |
| 9 | CI failed on the head (recorded). | Send the worker back with the failure; never merge. |
| 10 | Merge refused: head moved after the watched run, or required checks not green. | Rerun with `--pr` so the new head is watched. |
| 11 | `gh pr merge` failed. | Report. |
| 12 | The events line could not be written. | Report; the CI result is in the output. |

## Assumptions (open points left open)

- Approval mode lives in `org-state` as a top-level `merge_approval_mode` string. The prototype-1 shape has no such field yet; this is the smallest reading of "read from org-state or an argument".
- The events folder is `scripts/org`'s: `$PADDOCK_STATE_DIR/events`, default `${XDG_STATE_HOME:-~/.local/state}/paddock/events`. The writer id is `secretary`, and `seq` is `scripts/org`'s for that id: one more than the highest so far, taken under the per-id lock, so it never repeats a number a reader has acknowledged. Lines carry `kind`, `writer`, `task_id` (when given), `pr`, `sha`, `run_id`, `exit_code` and `conclusion` beyond `seq` and `ts` (`ts` follows `$PADDOCK_NOW` when set).
- The base branch is `--base`, else the base in the `--project <name>` row of `projects.md` (same file and columns as [org-delegate](../org-delegate/SKILL.md); only the base is read, since `--worktree` is the worker's), else `main`. An unknown name or a missing file exits 2 before the branch is sent anywhere. The title and body are written by the secretary in English.
- `--task-id` may hold only letters, digits, `.`, `_` and `-` (it goes into a JSON line); anything else exits 2 before the push.
- Known limit: when a head has several runs (for example both `push` and `pull_request` workflows), only the newest one found is watched and recorded. In `human` mode "CI green" means that run; in `acceptance` mode the required checks cover the rest.
- Known limit: the final line "Merged" means `gh pr merge` succeeded. On a branch with a merge queue that only enqueues the PR; the script does not query the merge state afterwards. This repository has no merge queue.
- `gh pr checks --required` exits non-zero when a required check fails, is pending, or none is configured; all of those refuse the merge.
- Reviews are not handled here. The row's "handles review" and "closes the worker" stay with the secretary template.

## Not measured

Everything is tested against stubbed `hc` and `gh` and a local bare repository as origin (`tests/org-pull-request.test.sh`). Not run on a host: a real push, `gh pr create`, `gh run list --commit` right after a push (how long until a run exists), a failed `gh run watch` through `hc wait` (expect `exit_code` 1, not measured in MON-12 either), `gh pr checks --required` with branch protection, `gh pr merge --match-head-commit`, and a real `merge_approval_mode` in `org-state`. A host probe follows separately.
