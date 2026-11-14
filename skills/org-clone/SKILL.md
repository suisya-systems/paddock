---
name: org-clone
description: Clone the GitHub repository a request names (OWNER/NAME or a github.com URL) into the paddock projects folder with the secretary's own login and add it to projects.md, so org-delegate can run on it. Run it from the secretary, before org-delegate, when the named repository is not on the machine. A fresh clone's first folder-trust dialog is held for the person.
---

# org-clone

Clones the repository a request names, then prints the `projects.md` name to give `org-delegate --project`. Why it is built this way: [references/rationale.md](references/rationale.md). The secretary runs it from a shell in its own terminal, when [org-delegate](../org-delegate/SKILL.md) would exit 2 because the named repository is not in `projects.md` and not on the machine; `org-delegate` itself does not change.

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

## Exit codes

| Code | Meaning | What the secretary does |
| --- | --- | --- |
| 0 | Cloned and recorded, or already recorded. The name is on stdout. | `org-delegate --project <name>`; when its first worker stops at the folder-trust dialog, ask for the trust card (below). |
| 2 | Bad argument, bare name, other host, relative `PADDOCK_PROJECTS_DIR`. | Ask the person for `OWNER/NAME`. |
| 3 | `git` not found. | Report to the person. |
| 4 | Not found, or the login has no access (stderr has the cause). | Tell the person; if they must act (`gh auth login`), add an approval entry. Do not delegate. |
| 5 | Network failure. | Tell the person. Do not delegate; no retry. |
| 6 | The target path exists and is not a clone of that origin. | Tell the person the path. |
| 7 | `NAME` is already another row. | Ask the person for another name. |
| 8 | Another failure, or the clone is there but the row was not written. | Read stderr; after fixing the cause, run it again (it registers the clone). |

## The first worker and the trust card

A fresh clone has `.git/paddock-trust-pending`. The first worker on it stops at Claude Code's folder-trust dialog, because the repository's own `.claude/settings.json` can carry hooks that run once it is trusted, and the person never looked at this code. So [org-escalation](../org-escalation/SKILL.md) `prompt` does **not** answer that dialog for such a clone: it prints `PROMPT=<the dialog>` and exits 3. The secretary then asks the person once, on an approval card: `ask --task <task_id> --question "<one sentence: trust the folder of OWNER/NAME?>" --prompt "<that text>"` with the background, what yes and no lead to, and a recommendation, in the conversation language. On yes, `answer --id <id> --text yes --then-send "<brief>"` (the brief is the first message org-delegate sent: its two id lines, a blank line, then the task text) moves the cursor to "Yes, I trust this folder", presses enter once, deletes the marker (later workers on this clone are not held) and sends the first message the dialog stopped. On no it presses esc and keeps the marker. Nothing is written to `~/.claude.json`, and the answer is never given automatically.

## Upstream

The repository is cloned as named. If the person's login cannot push there, the secretary finds out at the pull-request step ([org-pull-request](../org-pull-request/SKILL.md)), reports it and stops; pull requests go to `origin` only.
