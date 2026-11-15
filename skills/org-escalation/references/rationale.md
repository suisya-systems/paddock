# Why org-escalation is built this way

- **Every question is answered through the secretary.** A card never types into a worker; it sends one `ANSWER <id> <text>` line to the secretary's mailbox, and the secretary runs `answer`. The person's optional note rides on the same line (`; note: <note>`), so it stays tied to the question; on a worker's prompt it goes to the secretary only, since a prompt takes one key and never text. An earlier way of letting a card answer a worker's prompt directly was removed (`--answer-in` exits 2): keys reach a worker only after a fresh screen read matched a known dialog.
- **Only the person's file answers.** A worker can read an approval id from the history and write `ANSWER <id> yes` in its own file, and the mailbox shows it to the secretary like any line. The script, not the secretary's reading, checks that the line is in the person's file and newer than the question. An answer typed in the secretary's terminal has no such file line, so it takes an explicit flag that writes the typed line down. Hiding or randomising the approval id was not needed: knowing it gives a worker nothing once its own file does not count. `remove` checks only with `--text`, since removing a card grants nothing; what a forged answer could gain is the secretary's own act (a merge), and that is what `remove --text` guards.
- **The card carries the context.** The person sees only the card when deciding, so `ask` takes the background, what Yes and what No lead to, and a recommendation with its reason, and the card names every one left out ("Not written: ..."). A decision made on a bare question was the failure this prevents.
- **A short, fixed policy list for prompts.** Only folder-trust and the auto-mode setup dialog are answered without the person, each recognised by whole option lines, re-read before every key, with the cursor checked before `enter`. Anything else is asked, never guessed. The folder-trust answer matches what org-start does for the secretary.
- **`answer` sends first and removes second.** A failed send keeps the entry; a failed removal after the send says to run `remove`, so the worker is never left without its answer.
- **The worker is woken by the watcher, not by `answer`.** A worker that ended its turn does not read its mailbox on its own; [org-watch](../../org-watch/SKILL.md) wakes an idle or done worker with unread mail on its next pass (decision 0013), so `answer` only writes the mail.

## How it writes

`ask`, `answer` and `remove` read `org-state` first and refuse (exit 5) a value that is not a JSON object (`null` counts as empty for `ask`). They write through `scripts/org doc update org-state`, which reads, applies, sets with the version it read, and retries on a conflict. A small awk scanner (aware of strings, escapes and nesting) finds the top-level `approvals` array and edits only it; every other key stays byte for byte, so a word like `approvals` inside a question cannot confuse it.

`answer` sends first and removes second. A failed send keeps the entry (exit 8); a failed removal after the send exits 9 and says to run `remove`, so the worker is never left without its answer.

`answer` types nothing into the worker. A worker that ended its turn idle or done with this unread mail is woken by [org-watch](../../org-watch/SKILL.md) (decision 0013), with the same guards as for the secretary.

## Assumptions (open points left open)

- One worker id convention: `w-<task_id>` ([org-delegate](../../org-delegate/SKILL.md)).
- `updated_at` in `org-state` is not touched by this skill; `org doc update` enforces the 64 KiB cap.
- The skill does not read the mailbox. The secretary reads it at the end of every turn (its template) and calls the skill.
- `list` prints the question with `\"` and `\\` undone; other JSON escapes (`\n`, `\uXXXX`) are shown as written. `ask` never writes them.

## Not measured

Tested against a stubbed `hc` (documents only) and the real `scripts/org` in a throwaway state folder (`tests/org-escalation.test.sh`). Not run on a host: a real `doc.get` / `doc.set` of an `org-state` that the mod is displaying, the card sending `ANSWER ...` (with or without a note), and a worker reading the answer from its mailbox. The person-file check is tested with real history files only; a real worker sending `ANSWER <id> yes` from its own sandboxed terminal was not run on a host.
