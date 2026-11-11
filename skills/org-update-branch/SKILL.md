---
name: org-update-branch
description: Take origin/main into a pushed worker branch with a merge (so the push needs no force), and in a worker stop before the merge when the incoming range touches a path the sandbox protects. Run it from the secretary.
---

# org-update-branch

Implements [routine row 10](../../docs/design/routine-procedures.md) (inventory [GT-3](../../docs/design/predecessor-inventory.md), "Keep (a preflight)"). Once a branch is pushed and main has moved, the secretary cannot force-push a rebase, so the branch takes main in as a merge commit and the next push is a fast-forward.

```sh
bash skills/org-update-branch/scripts/org-update-branch.sh --worktree <worker worktree> [--base main]
```

Bash and `git` only. Then `org-pull-request --pr <n> --worktree <worker worktree>` sends the branch (no force) and watches CI again.

## What it does

1. `git fetch origin`; refuses when tracked files have uncommitted changes (exit 7, nothing touched).
2. Already contains `origin/<base>`: prints that and exits 0.
3. In a worker (`PADDOCK_ORG` is set, which only the worker launch command does): lists the files of the incoming range (`merge-base..origin/<base>`); if any is `.claude/skills/**`, `.claude/hooks/**`, `.claude/settings.json` or `.claude/settings.local.json` (the four paths [GT-3](../../docs/design/predecessor-inventory.md) measured as stopping a rebase in a worker, and a merge writes them the same way), it names them and exits 4 with the branch unchanged. The secretary runs the same command outside the sandbox, where the check is off.
4. `git merge --no-edit origin/<base>`. On a conflict it runs `git merge --abort` and exits 6, branch unchanged; the conflict is resolved by hand.

## Exit codes

| Code | Meaning | What the secretary does |
| --- | --- | --- |
| 0 | Merged, or already up to date. | `org-pull-request --pr <n>`. |
| 2 | Bad argument, or no branch checked out. | Fix the call. |
| 3 | `git` not found. | Report to the person. |
| 4 | Worker: the range touches a protected path. | Run it again from the secretary's own shell. |
| 5 | Fetch failed, or no `origin/<base>`. | Report. |
| 6 | Merge conflict (aborted). | Send the worker back to resolve it, or resolve it by hand. |
| 7 | Uncommitted tracked changes. | Have the worker commit first. |

## The acceptance gate's rules

- Known limit: the predecessor's acceptance gate (`acceptance_gate.py`, `check_first`) refuses a branch that took main in after its test commit, because it requires the test commit's parent to equal `merge-base(base, head)` and a merge moves that to main's tip. So a merge made by this tool does not ride the automatic merge in `acceptance` mode today; a person decides that PR.
- Until paddock's own gate ([#115](https://github.com/suisya-systems/paddock/issues/115)) accepts base changes that arrive after the test commit, the rule is: while nothing is pushed, the worker rebases onto `origin/main` (no force is needed, and the test commit stays first); once pushed, run this tool only when a person will decide the merge.
- What #115 needs to accept for this tool to be useful: the test commit's parent is an ancestor of base (not equal to the merge-base); no join commit before the test commit on the first-parent line; declared-path and protected-path checks look only at the branch's own commits, not at changes that came in from base.

## Assumptions (open points left open)

- The protected list is fixed in the script, not read from what the sandbox places; GT-3 asked for the latter. It is the four measured paths. Add a path to the script's `grep` when a new one is measured.
- A worker is told apart by `PADDOCK_ORG`; a secretary shell with that variable set would be checked like a worker (harmless: exit 4 only refuses).
- Not measured: how the gate treats files that arrive through the merge (they are main's, not the branch's); a real push after the merge; `PADDOCK_ORG` in a real worker session. Tested against a local bare repository (`tests/org-update-branch.test.sh`).
