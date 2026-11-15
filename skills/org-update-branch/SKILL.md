---
name: org-update-branch
description: Take origin/main into a pushed worker branch with a merge (so the push needs no force), and in a worker stop before the merge when the incoming range touches a path the sandbox protects.
when_to_use: Main moved under a branch that is already pushed (a PR is open or CI is waiting) and the branch must take main in; org-pull-request refuses a merge because the head moved or main changed under it.
allowed-tools: Bash(bash ${CLAUDE_SKILL_DIR}/scripts/org-update-branch.sh *) Bash(bash "$PADDOCK_HOME/skills/org-update-branch/scripts/org-update-branch.sh" *)
---

# org-update-branch

Brings main into a pushed worker branch. Why it is built this way: [references/rationale.md](references/rationale.md). Once a branch is pushed and main has moved, the secretary cannot force-push a rebase, so the branch takes main in as a merge commit and the next push is a fast-forward.

```sh
bash "$PADDOCK_HOME/skills/org-update-branch/scripts/org-update-branch.sh" --worktree <worker worktree> [--base main]
```

Bash and `git` only. **Every exit prints one line `next: ...`: do exactly that.** On success it is the [org-pull-request](../org-pull-request/SKILL.md) rerun that sends the branch (no force) and watches CI again for the new head. No exit-code table is kept here; `--help` lists the codes.

## When to use

Main moved under a branch that is pushed. A branch that is not pushed yet is the worker's to rebase (no force is needed, and its test commit stays first).

## What it does

1. `git fetch origin` (in a worker a failed fetch is not an error: the sandbox cannot reach GitHub, so it goes on with the `origin/<base>` the secretary fetched in the project clone); refuses when tracked files have uncommitted changes, with nothing touched.
2. Already contains `origin/<base>`: says so and stops.
3. In a worker (`PADDOCK_ORG` is set, which only the worker launch command does): if the incoming range touches `.claude/skills/**`, `.claude/hooks/**`, `.claude/settings.json` or `.claude/settings.local.json`, it names them and stops with the branch unchanged; the `next:` line is to run the same command from your own shell, outside the sandbox.
4. `git merge --no-edit origin/<base>`. On a conflict it runs `git merge --abort`, leaving the branch unchanged; the conflict is the worker's to resolve (or yours, by hand).

## What to check afterwards

`merged origin/<base> into <branch> at <sha>` (or `already up to date`), then the `next:` line. A merged branch whose PR is in `acceptance` mode may not ride the automatic merge: a person decides it (the rationale says why).
