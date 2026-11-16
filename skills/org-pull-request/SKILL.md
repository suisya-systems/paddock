---
name: org-pull-request
description: Push a finished worker branch, open the PR and record ci_requested so the watcher watches its CI; rerun with --pr to act on the watcher's result for the current head (stop for the person, or merge on that exact head), and to place the changed files again after a landing in the paddock repository.
when_to_use: A worker reports done and its branch must become a PR; the watcher's CI line (`CI success|failure on PR <n>`, or `CI watch failed`) arrives; the person says a PR is merged; a PR needs a CI rerun on the same commit (`--recheck`).
allowed-tools: Bash(bash ${CLAUDE_SKILL_DIR}/scripts/org-pull-request.sh *) Bash(bash "$PADDOCK_HOME/skills/org-pull-request/scripts/org-pull-request.sh" *)
---

# org-pull-request

Pushes a finished worker branch, opens its PR, and acts on the watcher's CI result. Why it is built this way: [references/rationale.md](references/rationale.md). The secretary runs it from its own shell (unlike [org-start](../org-start/SKILL.md), it is meant to run inside an agent).

```sh
bash "$PADDOCK_HOME/skills/org-pull-request/scripts/org-pull-request.sh" \
  --worktree <worker worktree> --title "<English title>" --body-file <file> --task-id <id>   # first run
bash "$PADDOCK_HOME/skills/org-pull-request/scripts/org-pull-request.sh" --pr <n> --worktree <worker worktree>  # every rerun
```

Flags are in `--help`. **Every exit prints one line `next: ...`: do exactly that.** It names the rerun, the person to ask, or the worker to send back, so no exit-code table is kept here.

## When to use

- **A worker reported done.** First run (above). The script pushes, opens the PR and writes `ci_requested` for its head; then end the turn. The watcher watches CI and mails `CI success|failure on PR <n>, head <sha7>, run <id>. Runs read: ...` (success only when every run of the head is green) or `CI watch failed on PR <n> ...`; that line wakes you.
- **The watcher's line arrived.** Rerun with `--pr <n>` (same `--worktree`). It reads the record for the current head and acts by the approval mode (`merge_approval_mode` in `org-config.md`, read with `org config get`, default `human`; `--mode` overrides). A `CI watch failed` line: rerun the same way (it requests the head again); if it fails again, tell the person the reason and log path from the line.
- **The person merged the PR.** Rerun with `--pr <n>` once more: it sees the PR is merged and places the changed files (below). You do not run `gh pr merge` or `org-start --place-only` yourself.
- **CI was rerun on the same commit** after a failure (a flaky job): rerun with `--pr <n> --recheck`.

## Judgment that stays with you

- **`human` mode** (the default): on CI green it prints the PR URL and stops. Tell the person the URL and quote the watcher's CI line (the `ci_completed` conclusion), never a worker's local test run; then wait and never merge.
- **`acceptance` mode:** there is no local gate. The check is the repository's required status check. The script merges only on the exact head the watcher watched (`--match-head-commit`, no `--admin`, no `--auto`). Then close the worker (the `org-close` skill).
- **The gate line.** Read the second-model review line in the worker's report. Unless it is `CODEX_GATE: passed` (a report with no gate line counts as not passed), write in the PR body (`--body-file`) and in your own report to the person that the second-model review did not run, with that line verbatim. The script also appends the fact to the body it sends when the task's history has no passed diff review.
- **CI is watched only by the watcher.** Never `gh pr checks --watch`, `gh run watch`, a sleep loop or any watch of your own: while a shell call runs you take no input.
- **On a failure** (exit 9): send the worker back with the failure. Do not merge by hand to get around any refusal (a moved head, required checks not green, an unwritten request).
- **When main moved under a pushed branch**, take it in with [org-update-branch](../org-update-branch/SKILL.md) (a merge, never a rebase or a force), then rerun this skill with `--pr <n>`.

## The landing places files, in both modes

A landing in the paddock repository itself may change the files `org-start` placed (templates, `secretary-settings.json`, the scripts in the bin folder, skills). The script places them again from the fetched base by running `org-start.sh --place-only --from-origin <base>` (it starts nothing; see [org-start](../org-start/SKILL.md)): in `acceptance` mode right after its own merge, in `human` mode on the rerun that finds the PR merged. Only a worktree that shares the paddock folder's git store counts; a landing in any other repository places nothing.

Read what it prints. `org-start`'s own lines come through, and the `next:` line adapts: a `RENEWAL NEEDED` line (`secretary.md` changed, which only a new secretary reads) makes it ask the person to renew you (the `secretary-handover` skill); a `left alone` line (the checkout is dirty, on another branch, or diverged) makes it ask the person to run the command that line gives; a placing failure is exit 13 with the command to run (the PR is merged either way). A changed `SKILL.md` reaches a running secretary only after `/reload-plugins`; the `skill changed` lines `org-start` prints say which, and the watcher types `/reload-plugins` into you once you are idle (do not ask the person for it).

## What to check afterwards

The PR URL is printed as `PR_URL=...`. After a merge: `Merged PR ... at <sha>` (acceptance) or `PR ... is merged.` (human rerun), then the placing output. The records the script reads and writes are in [references/rationale.md](references/rationale.md).

## Not measured

Everything is tested against a stubbed `gh`, records written with `scripts/org --as watcher` as `ci-watch.sh` writes them, a stubbed `org-start.sh`, and a local bare repository as origin (`tests/org-pull-request.test.sh`, `tests/org-pull-request-landing.test.sh`). Not run on a host: a real push, `gh pr create`, `gh pr checks --required` with branch protection, `gh pr merge --match-head-commit`, a real `merge_approval_mode`, and the rerun that finds a PR merged by the person. The CI watch itself is `ci-watch.sh`'s (see org-watch).
