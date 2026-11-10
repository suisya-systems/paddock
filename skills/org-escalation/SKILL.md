---
name: org-escalation
description: Record a worker's question or blocked status as an org-state.approvals entry, and when the person answers (from the card or in conversation) forward the answer to the worker through the mailbox and remove the entry. Run it from the secretary.
---

# org-escalation

Implements inventory row [SK-5](../../docs/design/predecessor-inventory.md) and Issue #66. The secretary runs it from a shell in its own terminal. Bash only, plus `awk`, `sed`, `tr` and `scripts/org` (which needs `hc` for documents).

```sh
bash skills/org-escalation/scripts/org-escalation.sh ask    --task <task_id> --question "<one sentence>"
bash skills/org-escalation/scripts/org-escalation.sh answer --id <approval_id> --text "<answer>"
bash skills/org-escalation/scripts/org-escalation.sh remove --id <approval_id>
bash skills/org-escalation/scripts/org-escalation.sh list
```

## The flow

1. A worker reports a question, or a `blocked` status, to the secretary through the mailbox. The secretary answers what it can itself. What it cannot decide goes on:
2. `ask` adds `{"id","task_id","question","asked_at"}` to `org-state.approvals` ([shape](../../docs/design/prototype-1.md)). The id is `<task_id>-<UTC yyyymmddThhmmssZ>`; the script prints `APPROVAL_ID=<id>`. The mod shows the entry as a card. `question` is one sentence, at most 400 bytes; control characters become spaces.
3. The person answers, in conversation with the secretary or from the card.
4. `answer` sends `Answer to your question (<approval_id>): <text>` to `w-<task_id>` with `scripts/org send_message`, then removes the entry. Nothing is typed into the worker ([decision 0002](../../docs/decisions/0002-org-mailbox-not-hc-send.md)).

A worker whose terminal is `blocked` on a permission prompt or dialog is different: nobody types the answer for the person (L-N3). Record it with `ask`, let the person answer in the worker's own terminal, and when the terminal is no longer blocked use `remove`.

## The answer message (shared with the card)

A card (or any agent) that carries the person's answer sends one line to the secretary's mailbox:

```
ANSWER <approval_id> <text>
```

`<approval_id>` is the `id` of an entry in `org-state.approvals`; `<text>` is `yes`, `no` or free text, to the end of the line. The card sends it with `bash scripts/org --as <id> send_message secretary "ANSWER <approval_id> <text>"`. When the secretary reads such a line in `check_messages`, it runs `answer --id <approval_id> --text "<text>"`. An id that is in no entry exits 6: tell the person, never guess a task.

## What it does

`ask`, `answer` and `remove` read `org-state` first and refuse (exit 5) a value that is not a JSON object (`null` counts as empty for `ask`). They write through `scripts/org doc update org-state`, which reads, applies, sets with the version it read, and retries on a conflict. A small awk scanner (aware of strings, escapes and nesting) finds the top-level `approvals` array and edits only it; every other key stays byte for byte, so a word like `approvals` inside a question cannot confuse it.

`answer` sends first and removes second. A failed send keeps the entry (exit 8); a failed removal after the send exits 9 and says to run `remove`, so the worker is never left without its answer.

## Exit codes

| Code | Meaning | What the secretary does |
| --- | --- | --- |
| 0 | Done. | Continue. |
| 2 | Bad argument. | Fix the call. |
| 5 | `org-state` cannot be read or written, or is not an object. | Report to the person. |
| 6 | No entry with that id. | Run `list`; tell the person. |
| 7 | An entry with that id exists (same task, same second). | Run `list`; use it. |
| 8 | The answer could not be put in the mailbox; entry kept. | Fix the cause and run `answer` again. |
| 9 | Answer sent, entry not removed. | Run `remove --id <id>`; do not send again. |

## Assumptions (open points left open)

- One worker id convention: `w-<task_id>` ([org-delegate](../org-delegate/SKILL.md)).
- `updated_at` in `org-state` is not touched by this skill; `org doc update` enforces the 64 KiB cap.
- The skill does not read the mailbox. The secretary reads it at the end of every turn (its template) and calls the skill.
- `list` prints the question with `\"` and `\\` undone; other JSON escapes (`\n`, `\uXXXX`) are shown as written. `ask` never writes them.

## Not measured

Tested against a stubbed `hc` (documents only) and the real `scripts/org` in a throwaway state folder (`tests/org-escalation.test.sh`). Not run on a host: a real `doc.get` / `doc.set` of an `org-state` that the mod is displaying, the card (Issue #65) sending `ANSWER ...`, and a worker reading the answer from its mailbox.
