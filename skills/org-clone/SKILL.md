---
name: org-clone
description: Clone the GitHub repository a request names (OWNER/NAME or a github.com URL) into the paddock projects folder with the secretary's own login and add it to projects.md, so org-delegate can run on it. Run it from the secretary, before org-delegate, when the named repository is not on the machine. A fresh clone's first folder-trust dialog is held for the person.
when_to_use: A request names a repository (OWNER/NAME or a github.com URL) that is not in projects.md and not on the machine; or the first worker on a freshly cloned repository stopped at the folder-trust dialog (org-delegate exit 10, or org-escalation prompt printed PROMPT= and exited 3).
---

# org-clone

Clones the repository a request names, then prints the `projects.md` name to give `org-delegate --project`. Why it is built this way: [references/rationale.md](references/rationale.md). The secretary runs it from a shell in its own terminal, when [org-delegate](../org-delegate/SKILL.md) is given a repository that is not in `projects.md` and not on the machine. Usually you do not run it yourself: `org-delegate --repo OWNER/NAME` runs it, and passes its exit code and its `next:` line through. Run it alone to clone without delegating.

```sh
bash skills/org-clone/scripts/org-clone.sh OWNER/NAME
bash skills/org-clone/scripts/org-clone.sh "<a github.com URL of the repository>"    # https or ssh form
```

Bash, awk and `git` only; the GitHub CLI (`gh repo clone`) does the clone when it is on PATH, otherwise a plain `git clone` of the repository on github.com. Either way it is the login of whoever runs the script, which is the secretary's own; no token is passed to a worker, written in a task text or stored.

`PADDOCK_PROJECTS_DIR` (an absolute path; default `$HOME/paddock-projects`) holds the clones as `<owner>/<name>`. `PADDOCK_PROJECTS_FILE` is `projects.md`, as for `org-delegate`.

## What it does

1. **Parses the argument.** `OWNER/NAME` or a github.com URL (https, ssh). A bare `NAME` is not guessed: it exits 2 and the secretary asks the person for `OWNER/NAME`. Any other host exits 2. All of this happens before any network call.
2. **Skips the clone** when a row of `projects.md` is already a clone with the same `origin` (any spelling, any case): it prints that row's name and exits 0.
3. **Never overwrites a row.** `NAME` already naming a different row exits 7; the secretary asks the person for another name and registers it by hand (`scripts/org config project add <name> <path>`).
4. **Never reuses a foreign folder.** `<dir>/<owner>/<name>` existing and not a clone of that origin exits 6, untouched. An existing clone of the same origin that is not in `projects.md` is registered as it is.
5. **Clones into `<dir>/<owner>/.<name>.partial`**, checks it with `git rev-parse --git-dir`, writes the trust marker, and renames it to `<name>` only then. Any failure removes the partial folder.
6. **Adds the row** `| <name> | <path> | <base> |` with `scripts/org config project add`, `base` from `origin/HEAD`, else `main`. Only after the rename.

Nothing is recorded and no worker starts unless every step passed. There is no retry and no second credential.

## When it fails

In `--help`. Every non-zero exit ends with one `next:` line saying what to do; nothing is recorded and nothing is delegated on any of them (4 no access or not found, 5 network, 6 a folder is in the way, 7 the name is taken: ask the person for another).

## The first worker and the trust card

A fresh clone has `.git/paddock-trust-pending`. The first worker on it stops at Claude Code's folder-trust dialog, because the repository's own `.claude/settings.json` can carry hooks that run once it is trusted, and the person never looked at this code. So [org-escalation](../org-escalation/SKILL.md) `prompt` does **not** answer that dialog for such a clone: it prints `PROMPT=<the dialog>` and exits 3 (org-delegate then exits 10 with the first message and the `work` entry saved).

1. Ask the person once, on an approval card: `ask --task <task_id> --question "<one sentence: trust the folder of OWNER/NAME?>" --prompt "<that text>"`, in the conversation language, with the background (the repository is one the request named and its code has not been looked at), what yes and no lead to, and a recommendation.
2. On yes, run `answer --id <id> --text yes` and nothing else: it moves the cursor to "Yes, I trust this folder", presses enter once, deletes the marker (later workers on this clone are not held), sends the first message org-delegate saved and writes the `work` entry. It prints `RESENT w-<task_id>`. Do not send the brief or add the entry by hand.
3. If it exits 12 (message not sent) or 13 (sent, entry not written), a card tells the person and the terminal is kept: read it (`hc read w-<task_id>`); when the person says yes on that card, `answer` tries again (or run `bash skills/org-delegate/scripts/resend.sh <task_id>` once the worker shows a status, then `remove` that card).
4. On no, `answer` presses esc, drops the saved message and keeps the marker; the terminal stays, so tell the person, and end it with `org-close --task <task_id> --drop` if they want it gone.

Host probe: `scripts/probes/trust-resend.sh`. Nothing is written to `~/.claude.json`, and the answer is never given automatically.

## Upstream

The repository is cloned as named. If the person's login cannot push there, the secretary finds out at the pull-request step ([org-pull-request](../org-pull-request/SKILL.md)), reports it and stops; pull requests go to `origin` only.
