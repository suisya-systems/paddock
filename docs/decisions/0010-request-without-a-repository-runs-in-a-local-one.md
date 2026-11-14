# 0010. A request that names no repository runs in a local repository made for it

Status: **proposed** (2026-11-14). Refs #357. Nothing is decided until the owner answers the questions at the end. This file records options and a recommendation for each of the four points the Issue lists; it builds nothing.

## The question, in plain words

`org-delegate` starts a worker only inside a git repository: `--project` is a path or a `projects.md` name, an unknown name exits 2, a folder that is not a git repository exits 6 ([org-delegate](../../skills/org-delegate/SKILL.md)). A request that names no repository (research, a write-up, a one-off script) has nowhere to go. The predecessor runs it in a plain per-task folder with no git.

The owner's proposal (2026-11-14): when the request has no remote repository, `git init` a new one with an empty first commit and delegate to it as today. One path for every task, so the worktree, the per-task settings and the second-model review (which needs a recorded base) work unchanged.

## What exists today (checked in this repository)

| Fact | Where |
| --- | --- |
| The worktree is `git -C <project> worktree add -b <branch> $PADDOCK_WORKERS_DIR/<id> <base>`. `git fetch origin` runs only when the project has an `origin`; `--no-fetch` skips it and uses the local base. So a repository with no remote already works up to this point. | org-delegate step 2 |
| The review gate's base is the one the script recorded in `<state folder>/bases/<id>`. | org-delegate step 3 |
| Trust, measured once (hc 0.1.18, Claude Code 2.1.322): with the workers folder trusted, a worktree of a fresh scratch repository **still raised the dialog**, a worktree of an already trusted clone did not. Trust appears to follow the project the worktree belongs to, not the folder it sits in. | org-delegate step 2 |
| The script never answers the trust dialog; the secretary may answer it once from the screen, never with a blind Enter (the default is "No, exit"). | org-delegate "What it does not do" |
| `org-close` leaves the worktree and branch; `org-pull-request` works from them. | [org-close](../../skills/org-close/SKILL.md) |
| `org-pull-request` pushes `origin`, runs `gh pr create`, watches CI. `--repo` comes from a GitHub `origin` URL and is never guessed (exit 2). With no `origin` it cannot run. | [org-pull-request](../../skills/org-pull-request/SKILL.md) |
| `acceptance` mode merges only on a green required `acceptance` CI job; there is no local gate. A repository with no CI has no acceptance mode. | org-pull-request step 6; [acceptance-check](../design/acceptance-check.md) |

## Decide 1. Where the local repositories live, and the unit

### Place

- **(a) One folder, `$PADDOCK_LOCAL_DIR`, default `~/paddock-local`, one repository per entry.** Next to `~/paddock-workers`, outside any other repository, easy to find and back up.
- **(b) Inside the workers folder.** Rejected: `~/paddock-workers` holds worktrees; a repository there would nest worktrees inside the repository they belong to.
- **(c) The state folder.** Rejected: that folder is paddock's records; a person's results do not belong there.

### Unit

- **(a) One repository per task**, named by the task id. Simple, nothing leaks between unrelated requests, and the worktree already is one per task, so the repository adds one more folder per task.
- **(b) One per topic**, reused. Results of related requests sit together and trust is asked once per topic. Costs: the secretary has to decide what "same topic" means, and two tasks share one history.
- **(c) One per task by default; a topic is an ordinary `projects.md` row.** A person who wants reuse adds the row and names it, and everything after is the path that exists today.

**Recommend: place (a), unit (c).** The secretary does not have to judge topics, and reuse needs no new mechanism.

## Decide 2. How the result reaches the person with no PR

The work is committed on the worker's branch in its worktree. Options for what the person gets:

1. **The folder and a summary.** The worker's `report done` carries a short summary and the path of the worktree; the secretary tells the person both.
2. **Merge into the local `main` when the person agrees.** The secretary runs `git merge --ff-only` of the worker branch into the repository's `main`, so the repository itself holds the result, and the worktree can be dropped later.
3. **A push to a new remote, later.** Only on the person's request, never by default: creating a remote is an outward action and paddock holds no token for it (README; workers have no GitHub access).

**Recommend 1 + 2, and 3 only when asked.** The result is then reachable three ways (summary in the message, files in the worktree, `main` of the repository) with no hand step, which is the Issue's "done when". A `gh repo create` helper is a possible follow-up, not part of this.

## Decide 3. Trust

A fresh repository raises the folder-trust dialog for its worktree, and the measurement above says trusting the workers folder does not cover it. The repository is made by the secretary, so the question is who answers and when.

- **(a) The secretary answers once, from the screen, when it makes the repository** (the existing rule: never a blind Enter). Needs the secretary to run a probe worker or a trust-only start before the real one. No change to what paddock writes.
- **(b) The person pre-trusts `$PADDOCK_LOCAL_DIR` once per machine.** One step like the workers folder today, but **unmeasured**: it is not known whether trusting a parent folder covers a repository made later inside it. The measurement above suggests the project, not the folder, decides. If it does not cover them, (b) is not available.
- **(c) paddock writes the trust flag into Claude Code's own configuration for the new path.** No dialog, no hand step. But it edits the person's tool configuration from a script, and the file's shape is Claude Code's, not ours (not measured here).

**Recommend (a), and measure (b) first** (one probe: trust the folder, make a repository inside it, start a worker, see whether the dialog appears). If (b) works it replaces (a), because it asks the person once per machine instead of once per task. (c) only if the owner accepts a script editing that configuration.

## Decide 4. The acceptance and PR steps

There is no `origin`, no CI and no PR. Proposed handling:

- **PR step: skipped.** The secretary does not call `org-pull-request`; it has nothing to push to and exits 2 without a GitHub `origin`. The worker still commits on its branch.
- **Second-model review: kept.** Its base is the recorded base (the empty first commit's branch, `main`), so the gate works as for any task.
- **Acceptance mode: not available.** It needs a required CI job. A task with no repository is closed in `human` mode, whatever `merge_approval_mode` says. A task that declares acceptance tests ("Acceptance-Test:" trailers) has no gate to check them; the secretary should not accept such a declaration for this kind of task (or the worker is told it does not apply).
- **Closing:** the worker reports done; the secretary tells the person the summary and the path; when the person agrees, the secretary fast-forwards `main` (Decide 2) and closes with `org-close`. When the person wants it dropped, `org-close --drop`.

**Recommend this as written.** It adds one rule (no origin means no PR step and `human` only) and no new gate.

## Costs of the proposal itself

- One more folder tree per task (`$PADDOCK_LOCAL_DIR/<id>` plus the worktree), never cleaned up by paddock. A person or a later task removes them.
- `git init` needs a first commit before `worktree add` can work: an empty commit with a fixed author. A machine with no `user.name` / `user.email` fails there; the script must pass them with `-c`.
- A new entry point in `org-delegate` or a new small skill (the Issue says "delegate as today"): which, is for the build task.

## What is not measured

- Nothing here was run: this work was done in a sandbox with no running core. The trust behaviour is the one measurement already recorded in org-delegate; whether a parent folder's trust covers a repository made later is **unmeasured** (Decide 3 (b)).
- Whether a repository made with `git init` plus one empty commit works through every `org-delegate` step (worktree, settings, review gate base) with no `origin`: expected from the code, **not run**.
- How the `acceptance` declaration behaves on a repository with no CI: by reading `acceptance-check.sh` it never runs there, **not run**.

## Questions for the owner

1. **Place and unit.** `~/paddock-local`, one repository per task, reuse through `projects.md`? (recommended)
2. **Result.** Summary and path in the report, plus a fast-forward into the repository's `main` when the person agrees; a remote only when asked? (recommended)
3. **Trust.** The secretary answers once per repository from the screen, after one probe of whether trusting the folder is enough? Or may a script write the trust flag into Claude Code's configuration (c)?
4. **Acceptance and PR.** Skipped, `human` only, no acceptance declarations for such a task? (recommended)
5. **Scope of the build.** One task covering `git init` + delegate + close, or the repository creation first and the close path after?
