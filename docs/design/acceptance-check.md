# Acceptance check in CI

Issue #115. Replaces the predecessor's acceptance gate and its head-pinning merge hook ([Q11](open-questions.md#q11-what-happens-to-the-predecessors-python-gates-and-generators) decided (d); inventory [GT-1, HK-15](predecessor-inventory.md)). Bash and git only.

## What runs

The `acceptance` job in [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) runs on every pull request:

```sh
bash scripts/acceptance-check.sh <base sha> <head sha>
```

[`scripts/acceptance-check.sh`](../../scripts/acceptance-check.sh) takes the branch's own commits: the head's first-parent line that the base cannot reach. The oldest of them is the test commit (its parent is in the base). If it carries `Acceptance-Test: <path>` trailers (files or directories), the check fails unless all of these hold:

1. The test commit is not a merge, and no other own commit declares. So no join commit comes before the test commit.
2. The test commit changes only declared paths and test helpers (files under `tests/` that are not `*.test.sh`).
3. Every declared `*.test.sh` (for a directory, every `*.test.sh` under it) fails at the test commit and passes at head, each run as `bash <path>` from the tree root.
4. The own commits after the test commit leave the declared paths, test helpers, `.github/` and the checker itself unchanged. New `*.test.sh` files may be added.

The base may be merged into the branch after the test commit (nobody can force-push, so a branch takes `main` by a merge); a merge that brings in anything not in the base fails, since that branch's commits are off the first-parent line and would not be checked. A base merge counts in rule 4 only for files it leaves different from every parent, that is its own conflict resolution; what it brings from the base does not count. Renames count as both paths.

No trailer: the job passes and prints `ACCEPTANCE: none`. The last line of the log is always `ACCEPTANCE: pass`, `none` or `fail`; tests are in [`tests/acceptance-check.test.sh`](../../tests/acceptance-check.test.sh).

## How it differs from the predecessor

- The job runs the declared tests at both commits itself, so one check on the head expresses "failed at the test commit, passed at head". The question Q11 left open (can required checks express a failure at another commit) does not arise, and the secretary no longer has to push the test commit alone first.
- A failure is any non-zero exit of the test file; an assertion failure and a crash are not told apart.

## Settings only the owner can make

Not set by this change; the job is advisory until they are:

1. Branch protection (or a ruleset) on `main`: require status checks to pass, with the check `acceptance` (and the existing `links` and `templates-and-mods`) as required.
2. Require branches to be up to date before merging, so the check ran against the current base. A required check counts only for the pull request's head commit, so a new push needs a new green run; together this replaces the single `gh pr merge --match-head-commit` form (HK-15); [org-pull-request](../../skills/org-pull-request/SKILL.md) keeps `--match-head-commit` and `gh pr checks --required` as a second guard.

## Known limits

- A pull request without a declaration passes (`none`). In `acceptance` mode, [org-pull-request](../../skills/org-pull-request/SKILL.md) would merge it on green required checks; the predecessor stopped it for the person. Whether to refuse an undeclared PR in `acceptance` mode (in the skill, or by a rule in the job) is open.
- The workflow and the checker are read from the pull request, so a PR can change them. Rule 4 fails a declared PR that does; an undeclared PR is not checked. Review of `.github/` changes stays with the person.
- The pull request that adds this check fails its own `acceptance` job: it must create the checker after its test commit. It is merged in `human` mode.
