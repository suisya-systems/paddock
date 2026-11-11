# 0006. Where a remote (`--on`) worker's history file lands

Status: accepted (2026-11-11, owner): B. Closes #75; depends on [0005](0005-history-log-settings.md), whose Folder row carries the sentence below.

## Context

0004 keeps history in `events/<YYYY-MM>/<writer-id>.jsonl` on the primary, one writer per file. `hc run --on <machine>` starts the worker on another machine, and a `file.write` there lands on that machine ([Q8](../design/open-questions.md) point 5). Today `scripts/org` appends with the shell to the local `$PADDOCK_STATE_DIR` (`scripts/org:109`, `put` with its per-id lock), so a remote worker's `org send_message` or `report` would write a file the primary never sees. The mailbox ([0002](0002-org-mailbox-not-hc-send.md)) is these files, so this is not only about history: a remote worker's report would not reach the secretary.

## Options

| | A. Write through the primary's file API | B. Write locally, the reader pulls |
| --- | --- | --- |
| How | The remote worker's `org` calls `file.write` on the primary (no `--on`, or `--on <primary>`) instead of `>>`. | Unchanged: the worker appends to its own `events/<YYYY-MM>/w-<task>.jsonl` on its machine. `org` readers (`window()`, `check_messages`, `list_runs`, `wait`) also `file.read --on <machine>` for each remote id and merge by `seq` and `ts`. |
| Fits 0004 / 0005 | Files stay on the primary; the layout is exactly 0005. | One file per writer stays; the folder exists on each machine, the merge is by the reader. |
| Cost | `file.write` replaces the whole file and has no append or offset (`hc schema` 0.1.18, [Q8](../design/open-questions.md) point 1), so each line is read, joined and written whole through the network; the 8 MB `file.read` cap applies to every append. The per-id lock (`scripts/org:109`) has to move to the primary. | Reader work grows with the number of machines; a message is seen only when the reader polls. `file.read` is by line offset, so a reader can keep a cursor per remote id. |
| Failure | Network down means the worker cannot record or report. | Network down means the primary does not see lines yet; they are not lost and arrive on the next pull. |
| Needs | The remote worker can reach the primary's core and its `hc` (or `org`) from that machine. | The primary can `file.read` the remote path, which means knowing that machine's state folder. |

Sources: `hc schema` for `file.write` (`cwd`, `data`, `on`, `path`; swapped in whole) and `file.read` (`cwd`, `limit`, `offset`, `on`, `path`; lines from offset, 8 MB) in [open-questions.md](../design/open-questions.md) line 274; `scripts/org:95`, `scripts/org:109`; [0004](0004-records-documents-and-jsonl.md) one writer per file; Q8 point 3 / the owner's decision of 2026-11-11, no events bridge.

## Decision: B, with the pull inside the readers (the secretary pulls)

- It keeps the append local and the one-writer rule as 0004 states it; A turns every append into a whole-file read and write across machines, which is the lost-update shape 0004 avoided.
- It needs no bridge process (decided: Q8, no events bridge); the pull is part of the reader that already merges files.
- A failed link delays lines instead of blocking the worker.

0005's Folder row gained one sentence: "On a remote machine the same folder name under that machine's `$PADDOCK_STATE_DIR`; readers pull it with `file.read --on`." The remote worker's id stays `w-<task_id>`, so ids stay unique across machines.

## Not measured (a probe, not a guess)

No second machine is planned for now, so nothing below is measured. These 5 points are measured when a second machine is first used.

Both options depend on something not run on a second machine. A probe on one registered machine (`hc machine add`, then `hc run --on`) has to show:

1. The worker started with `--on` has `org` and its shell on that machine and which `$HOME` / state folder it gets. (B needs the path; A needs nothing here.)
2. `hc file.read --on <machine> --path <state>/events/...` from the primary returns lines by `offset` and `limit` for a file a remote process appended with `>>`. (B.)
3. From the remote worker, whether an `hc` call reaches the primary core at all and whether `file.write` without `on` lands on the primary or on the worker's machine. (A.)
4. Whether core serializes two `file.write` calls on one path (also open in Q8 point 1). (A.)
5. The remote file's `ts` against the primary's clock: the same UTC format is used, but skew is not measured. (Both; order is by `seq` per writer, so only cross-writer order is affected.)

## Consequences

- 0005: the Folder row has the sentence above.
- The way to move to A later (if the probe shows B does not hold) is recorded in Issue #230.
- A follow-up Issue for the chosen reader or writer change in `scripts/org`; no code is changed by this draft.
