# Why org-curate is built this way

- **The secretary saves the note, the worker does not.** A worker writes only its worktree; a note file would need a new write path that was never measured. The note rides in the done report, which the mailbox keeps, so a lost file can be rebuilt.
- **Notes are private, per machine.** Lessons name internal paths and hosts. Only a merged skill, through a pull request, is shared.
- **A count at close, no resident process.** Notes arrive only when a task ends, so counting then is enough. The count is `find -newer` against a file the curator touches, so it needs no database.
- **The gates are shell, the rest is judgment.** "3 different tasks name the pattern" and "one sentence says when" can be checked without a model. The curator lists the notes under a pattern in `curated/<pattern>.md`; the script counts distinct `Task:` lines over the listed notes that exist, so a made-up file name adds nothing.
- **The whole pile is read every time.** 5 notes start a cycle; they may be too few. A note that did not qualify stays in `raw/`, and the gate counts `raw/archive/` too, so a pattern that needs 10 or 20 notes is found when it does.
- **Nothing becomes a skill without the owner.** `chain` fails at link 3 while the entry is not `approved` with a date.
- **`chain` repeats two rules of the self-containment test** (no Issue number, no URL) so a fixture can be checked; the full test still runs over the real skills.
