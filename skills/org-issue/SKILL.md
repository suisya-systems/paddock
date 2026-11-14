---
name: org-issue
description: Open a GitHub issue from sections and a goal clause, with the dependency written as one "Depends on #N #M" line at the end of the body. Run it from the secretary.
---

# org-issue

Opens an issue whose body the triage parser can read. The parser reads dependency references only from the same line as the keyword (`Blocked by` / `Depends on` / `Requires`); references under a heading were silently treated as unblocked. This script builds the body, so the line is always right. The secretary runs it from a shell in its own terminal. Bash only, plus `gh`.

```sh
bash skills/org-issue/scripts/org-issue.sh --repo OWNER/NAME --kind build --title "<English title>" \
  --why "<why>" --done "<definition of done>" --goal "G2 Permissions and hooks are distributed at delegation time and take effect" \
  --depends 60 --depends 61
```

`--repo` is always given; it is never guessed. Prints the issue URL.

## Kinds and sections

| Kind | Options (all required) | Headings written, in order |
| --- | --- | --- |
| `decide` | `--question` `--known` `--options` `--done` | Question, What we know (with sources), Options, Definition of done, Goal clause |
| `build` | `--why` `--done` | Why, Definition of done, Goal clause |
| `followup` | `--seen` `--ask` | What was seen, Ask, Goal clause |

`--goal` is the Goal clause, one line: the clause number and its heading. The issue template in `.github/ISSUE_TEMPLATE/issue.md` carries the same headings for a person who writes an issue on GitHub; `tests/org-issue.test.sh` checks they match.

## Dependencies

`--depends N`, zero or more times. If there is any, the last line of the body is `Depends on #N #M`, one line. A number must be an issue that exists in `--repo` (`gh issue view`) and may be given once. An issue cannot depend on itself: it has no number before it is created.

## Exit codes

| Code | Meaning | What the secretary does |
| --- | --- | --- |
| 0 | Opened. | Use the printed URL. |
| 2 | Bad argument, a section missing, or a section option of another kind. Nothing was created. | Fix the call. |
| 3 | `gh` not found. | Report to the person. |
| 4 | A dependency does not exist in the repository. Nothing was created. | Fix the number. |
| 6 | `gh issue create` failed. | Report. |

## Not measured

Tested only against a stubbed `gh` (`tests/org-issue.test.sh`). Not run on a host: a real `gh issue create`, and the real triage parser reading the body (it is not in this repository).
