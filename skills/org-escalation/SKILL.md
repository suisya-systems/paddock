---
name: org-escalation
description: Record a worker's question or blocked status as an org-state.approvals entry, and when the person answers (from the card or in conversation) forward the answer to the worker through the mailbox, or to its prompt as one key after a fresh screen read, and remove the entry. Answers a prompt in the policy list (folder-trust) itself. Run it from the secretary.
---

# org-escalation

Implements inventory row [SK-5](../../docs/design/predecessor-inventory.md) and Issue #66. The secretary runs it from a shell in its own terminal. Bash only, plus `awk`, `sed`, `tr` and `scripts/org` (which needs `hc` for documents).

```sh
bash skills/org-escalation/scripts/org-escalation.sh prompt --task <task_id> [--then-send "<text>"]
bash skills/org-escalation/scripts/org-escalation.sh ask    --task <task_id> --question "<one sentence>" [--prompt "<PROMPT= text>"] \
         --background "<why it is asked>" --if-yes "<what Yes does>" --if-no "<what No does>" \
         --recommend yes|no --why "<reason>"
bash skills/org-escalation/scripts/org-escalation.sh answer --id <approval_id> --text "<answer>"
bash skills/org-escalation/scripts/org-escalation.sh remove --id <approval_id>
bash skills/org-escalation/scripts/org-escalation.sh list
bash skills/org-escalation/scripts/org-escalation.sh sweep
```

## The flow

1. A worker reports a question, or a `blocked` status, to the secretary through the mailbox. The secretary answers what it can itself. What it cannot decide goes on:
2. `ask` adds `{"id","task_id","question","asked_at"}` to `org-state.approvals` ([shape](../../docs/design/prototype-1.md)). The id is `<task_id>-<UTC yyyymmddThhmmssZ>`; the script prints `APPROVAL_ID=<id>`. The mod shows the entry as a card. `question` is one sentence, at most 400 bytes; control characters become spaces. Every entry is answered through the secretary ([architecture 7.1](../../docs/design/architecture.md#71-approvals)); `--answer-in` is gone (Issue #260) and exits 2.
   The card is all the person sees when deciding, so write the context with it (Issue #258): `--background` (why this is asked, one or two sentences, at most 600 bytes), `--if-yes` and `--if-no` (what each answer leads to, at most 300 bytes each), and `--recommend yes|no` with `--why` (your recommendation and its reason, at most 400 bytes; one without the other exits 2). They are kept in the entry as `background`, `if_yes`, `if_no`, `recommend` and `why`. Each is optional to the script, but leave one out only when it truly does not apply: the card names every one that is missing ("Not written: ..."). An empty or too long value exits 2 and writes nothing; control characters become spaces.
3. The person answers, in conversation with the secretary or from the card.
4. `answer` sends `Answer to your question (<approval_id>): <text>` to `w-<task_id>` with `scripts/org send_message`, then removes the entry. Nothing is typed into the worker ([decision 0002](../../docs/decisions/0002-org-mailbox-not-hc-send.md)).

## A worker's prompt (L-N3, Issue #260)

A worker runs in auto mode, so few prompts appear. A prompt or dialog that does appear is answered only after a fresh read of the screen matched it; keys never go to a worker any other way (the secretary's hook refuses `hc keys` and a forced `hc send` typed by hand).

- `prompt --task <t>` reads `hc read w-<t>`. **The policy list** is what the secretary may answer without the person; it is fixed in the script and changes only by a reviewed commit. It holds two entries, each recognised by whole option lines and never with a "Do you want" question on the screen; the script moves the cursor with `down`, reads the screen after each move, and presses `enter` only with the cursor on the expected line:
  - `folder-trust`: Claude Code's folder-trust dialog, only on a terminal that reports no status yet (the dialog comes before any status; a tool prompt is `blocked`), with "No, exit" and "Yes, I trust this folder" as option lines (numbered or not; the host shows them unnumbered). Answer: "Yes, I trust this folder" (the default is "No, exit"), as org-start does for the secretary (#254).
  - `auto-mode-setup` (owner, 2026-11-12): Claude Code's "Teach auto mode about your environment?" dialog (options Yes / Not now / Don't show again; text from Claude Code 2.1.322, not yet seen on a host). Answer: "Don't show again".
  The script prints `POLICY <entry> w-<t>` and exits 0. With `--then-send <text>` it waits for the terminal to report a status and sends the text with `hc send` (org-delegate passes the brief, which the dialog stopped). Any other screen: `PROMPT=<the dialog's non-empty lines, on one line>`, exit 3, nothing pressed.
- `ask ... --prompt "<that text>"` records it as an ordinary question; the entry keeps `prompt` and `prompt_sum` (a checksum of the text). The card offers Yes / No as for any question.
- `answer --id <id> --text yes|no` on such an entry presses one key, only while `w-<t>` is `blocked` and the checksum of its dialog (from the last rule line `───` to the end of the screen; the whole screen when there is none) equals `prompt_sum` (a change in the dialog refuses; the transcript above it may change, as the host check showed; a request taller than the screen is compared only where it shows): yes = `enter` with the cursor on "1. Yes" (the one-time Yes, never "don't ask again"), no = `esc`. Anything else presses nothing and exits 10 (entry kept; run `prompt` again). Free text exits 2.
- `sweep` (on each return from the wait) removes every prompt entry whose terminal `w-<task_id>` shows `working`, `idle` or `done` in `hc get --json` (someone answered it, or it moved on), and prints `SWEPT <id>`. No status, a missing terminal or a failed lookup keeps it. Other entries are never touched; an old `answer_in: worker` entry has no `prompt` and is an ordinary question.

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
| 8 | The answer could not be put in the mailbox, or the key not pressed; entry kept. | Fix the cause and run `answer` again. |
| 9 | Answer sent (or key pressed), entry not removed. | Run `remove --id <id>`; do not send again. |
| 3 | `prompt`: not in the policy list; `PROMPT=` printed, nothing pressed. | `ask --prompt` it. |
| 10 | The screen did not show what was expected (cursor, prompt, `blocked`); nothing confirmed. | `prompt` again; tell the person if it repeats. |
| 11 | `prompt`: the screen could not be read. | `hc get` the worker. |
| 12 | `prompt --then-send`: the dialog was answered but the text was not sent. | Send the brief with `hc send`. |

## Assumptions (open points left open)

- One worker id convention: `w-<task_id>` ([org-delegate](../org-delegate/SKILL.md)).
- `updated_at` in `org-state` is not touched by this skill; `org doc update` enforces the 64 KiB cap.
- The skill does not read the mailbox. The secretary reads it at the end of every turn (its template) and calls the skill.
- `list` prints the question with `\"` and `\\` undone; other JSON escapes (`\n`, `\uXXXX`) are shown as written. `ask` never writes them.

## Not measured

Tested against a stubbed `hc` (documents only) and the real `scripts/org` in a throwaway state folder (`tests/org-escalation.test.sh`). Not run on a host: a real `doc.get` / `doc.set` of an `org-state` that the mod is displaying, the card (Issue #65) sending `ANSWER ...`, and a worker reading the answer from its mailbox.
