# 0011. Clone a repository the request names when it is not on the machine yet

Status: **accepted** (2026-11-14, owner: Q1 ask the person on the first use of a fresh clone, Q2 `~/paddock-projects/<owner>/<name>`, Q3 GitHub only, Q4 ask back `OWNER/NAME`, Q5 clone what is named). Refs #356. This file records the decision only; the clone step is a follow-up task. It was drafted as 0010 and renumbered to 0011 because the parallel record (#357, PR #358) merged first. Related: a request that names no repository at all is [decision 0010](0010-request-without-a-repository-runs-in-a-local-one.md).

## The question, in plain words

`org-delegate --project` takes an existing local path or a name in `projects.md`; anything else exits 2 before anything is created. Nothing in paddock clones. So "fix X in OWNER/NAME" stops before any worker starts when OWNER/NAME is not on the machine, and a person clones it and edits `projects.md` by hand. That is a hand step against "a request alone reaches a PR" (Issue #356, done-when). Open: how the repository is identified, where the clone goes, which credential clones it, how the folder-trust dialog is passed, and what happens when any of that fails.

## What exists today (checked in this repository)

| Fact | Where |
| --- | --- |
| `--project <name>` is looked up in `projects.md` (`name`, `path`, `base` columns); a missing name exits 2. The secretary edits `projects.md`; the person never writes the format. | [org-delegate](../../skills/org-delegate/SKILL.md), [Q14](../design/open-questions.md#q14-where-do-organization-settings-and-registries-live) |
| A worker holds no GitHub credential (empty `GH_CONFIG_DIR`, token variables removed). The secretary fetches the base in the project clone and does the pushing. | [Q20 / worker-github-access](../design/worker-github-access.md), [secretary template](../../templates/secretary.md) line 21 |
| Trust follows the git repository: a worktree of a trusted clone raised no dialog, a worktree of a fresh clone did. | [Q13](../design/open-questions.md#q13-how-does-a-new-worktree-get-past-claude-codes-folder-trust-dialog), [org-delegate](../../skills/org-delegate/SKILL.md) step 2 |
| The folder-trust dialog is already the one prompt the secretary answers itself: when a worker's first message did not arrive, `org-escalation prompt --then-send` presses `down`, re-reads, and presses `enter` only with the cursor on "Yes, I trust this folder". Nothing is written to `~/.claude.json` (that route was rejected in Q13). | Q13 (#244, #260), [org-escalation](../../skills/org-escalation/SKILL.md) |
| Trust of a clone a person already made is only checked and reported by `org-start --check`, never granted by a script. | [decision 0007](0007-first-run-setup-outside-the-round.md) row 4 |
| Ground rules: shell only, no Python or Node; `git` and `hc` only for these skills. | README Assumptions |

## Decisions needed, with options

### 1. How the repository is identified

- **(a) `OWNER/NAME` or a URL, GitHub only (recommended).** Accepted forms: `OWNER/NAME`, `https://github.com/OWNER/NAME[.git]`, `git@github.com:OWNER/NAME.git`. All reduce to `OWNER/NAME`. A bare `NAME` that is not in `projects.md` is **not guessed**: the secretary asks the person for `OWNER/NAME`. Before cloning, the secretary looks for an existing row or folder with the same `origin` and uses it (no second clone).
- (b) Any host. Needs per-host credentials and a name rule per host; nothing in the brief asks for it. Add when a request names another host.
- (c) Search GitHub for a bare name. Guesses which of several repositories is meant, then runs code from it. Rejected.

### 2. Where clones live

- **(a) A fixed folder `PADDOCK_PROJECTS_DIR`, default `~/paddock-projects/<owner>/<name>` (recommended).** Absolute path required, as for `PADDOCK_WORKERS_DIR` (else exit 2). Separate from the workers folder: that folder holds throwaway worktrees and its trust is not what lets a worker start (Q13), so a clone does not belong in it. `<owner>/<name>` keeps two repositories with the same NAME apart.
- (b) Inside the workers folder. Mixes the permanent clone with per-task worktrees; `org-close` and clean-up rules for that folder would have to skip it.
- (c) Under the paddock config folder. That folder holds settings (Q14), and a clone is a working tree of foreign code; keep them apart.

The `projects.md` row is `| <name> | <path> | <base> |`: `name` is NAME, `path` the clone, `base` the remote's default branch (`git symbolic-ref refs/remotes/origin/HEAD`), else `main`. If NAME already names a different row, the script stops and the secretary asks the person for a name; it never overwrites a row.

### 3. Which credential clones

- **(a) The secretary clones, with the person's own login, and the worker still holds nothing (recommended).** The clone runs in the secretary's shell, where `gh` / `git` already work (that is how it fetches and pushes). The worker's rule is untouched: it reads the base from the clone's `origin/*` and commits. No token is passed to a worker, written in a task text, or stored by the script (`gh repo clone OWNER/NAME`, or `git clone` with the person's existing credential helper).
- (b) Give the worker a read-only credential to clone for itself. Reopens Q20, which was settled the other way (decision D, local mirror). Rejected.
- (c) Anonymous `git clone` only (public repositories). Simple, but a private repository then fails every time. Kept as the fallback when `gh` is missing, not as the design.

A repository the person's login cannot read fails at the clone (see 5); the script does not look for another credential.

### 4. Trust

- **(a) No new mechanism: the existing prompt path passes the dialog (recommended in the draft; the owner chose to ask the person first, see Decision item 4).** The first worker on a fresh clone stops on the folder-trust dialog, and the secretary's `org-escalation prompt --then-send` answers it from the screen (Q13, #260). So "trust once" is already automatic for the unattended case; the clone skill adds no key press and no write to `~/.claude.json`.
- (b) Open `claude` once in the clone right after cloning, to pass the dialog before any worker. Needs a throwaway Claude Code session per clone, with the same screen reading as (a), and gains nothing: the worker's first message is already resent after the answer.
- (c) Write `hasTrustDialogAccepted` into `~/.claude.json`. Rejected in Q13 (undocumented key, the person's own config).

One thing (a) makes explicit that was implicit for a clone a person made themselves: **answering "Yes, I trust this folder" for a repository the request merely named trusts code the person never looked at** (a repository's own `.claude/settings.json` can carry hooks that run once trusted). The worker's sandbox, deny list and `--settings` limit what that code can do, but trust is the vendor's gate, not paddock's. This is the first owner question below.

### 5. Failure

Order and rule: **nothing is registered and no worker starts unless the clone completed.**

1. Parse the argument; bad shape exits 2 before any network call.
2. Clone into `<projects dir>/<owner>/.<name>.partial`, then rename to `<name>` only on success. A failed clone removes its partial folder (the script's own, not a worker's, so `rm -r` is the script's to run) and leaves `projects.md` as it was.
3. Append the `projects.md` row only after the rename and a successful `git rev-parse --git-dir` check.
4. Distinct exit codes for "not found or no access", "target path exists", and "network", so the secretary can report the cause in one sentence.
5. No retries and no fallback credential. The secretary tells the person the cause (through the normal reply, and as an approval entry if the person must act, e.g. `gh auth login`), and the task is not delegated.
6. Target path exists but is not a clone of that `origin`: stop; never reuse or overwrite it.

## Decision

The owner took 1 (a), 2 (a), 3 (a) and 5 as recommended, and **changed 4**: trust is not answered automatically (2026-11-14):

1. **Identify.** `OWNER/NAME` or a GitHub URL; a bare `NAME` not in `projects.md` is asked back as `OWNER/NAME`, never searched. GitHub only in the first version.
2. **Where.** `PADDOCK_PROJECTS_DIR`, default `~/paddock-projects/<owner>/<name>`.
3. **Credential.** The secretary clones with the person's own login; a worker holds nothing.
4. **Trust.** On the first use of a fresh clone the secretary asks the person through an approval card (`org-escalation ask`); it does not answer "Yes, I trust this folder" by itself for a clone made because a request named it. After the person answers yes, the existing prompt path presses the one key (as `answer` does for any prompt). No write to `~/.claude.json`. The folder-trust entry in the secretary's automatic policy list stays for clones a person made; for a clone made by the clone script it is not applied until the card is answered.
5. **Failure.** As in section 5: nothing registered and no worker started unless the clone completed.
6. **Upstream.** A request naming an upstream repository clones that repository as named. If the person has no push right, the secretary reports it at the pull-request step and stops (PRs go to `origin` only).

Shape of the build: one new script `skills/org-delegate/scripts/org-clone.sh OWNER/NAME|URL` that prints the `projects.md` name on success; the secretary template says to run it when `org-delegate --project` would exit 2 for a named repository, then delegates by that name. `org-delegate` itself does not change (the clone is a separate step, so its exit codes and "nothing created before checks" rule stay as they are).

## Why

It is the smallest change that removes the hand step: one script, no new language, no credential for a worker, no new trust mechanism. It reuses the registry (`projects.md`, Q14), the secretary-owns-GitHub rule (Q20) and the dialog path (Q13) as they are.

## Costs accepted

- One more script and its test against a stubbed `git` / `gh`, and a line in the secretary template.
- The first worker on every fresh clone waits for a person's answer to the trust card, so "a request alone reaches a PR" does not hold for the first task on a new repository; the owner accepted this over trusting code the person never looked at.
- A push-less upstream is found at the pull-request step, after the work is done.

## What is not measured

- Nothing here was run: no core, no `hc`, no `gh` login in this sandbox. The `hc` and Claude Code facts are taken from the documents cited.
- That `gh repo clone` and a plain `git clone` pick up the person's login the same way in the secretary's terminal (kept terminal, no desktop session) is **unmeasured**; it is the build task's first probe.
- That a worktree of a clone made by the script behaves like a clone a person made (no dialog after the first answer) is the Q13 result, not re-measured for this layout.
- The base branch read from `origin/HEAD` on a repository whose default branch is not `main`.

## Owner's answers (2026-11-14)

1. Trust of a named-only repository: ask the person by approval card on the first use of each fresh clone; no automatic Yes.
2. Clone location: `~/paddock-projects/<owner>/<name>`.
3. Hosts: GitHub only for the first version.
4. Bare names: ask back `OWNER/NAME`.
5. Upstream or fork: clone what is named; with no push right the secretary reports at the pull-request step and stops.

Follow-up (not part of this record): the clone script, the secretary template line, the trust card, and their tests. The earlier draft's Why and trust options above are kept as the record of the comparison; where the Why says no new trust mechanism, the Decision's item 4 supersedes it.
