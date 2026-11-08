# 0004. Records: in-progress state in fixed-name core documents, history in per-writer monthly JSON lines, no SQLite

Status: accepted (2026-11-09)

## Context

[Open question Q8](../design/open-questions.md#q8-what-is-each-component-written-in) asked what the record store (`state.db`) is made of. It must hold what is in progress (runs, approvals, summaries) and the history (events, completed tasks), and it must be reachable from what herdr already brings: a mod's JavaScript, `hc`, and the shell.

The sizing in Q8 found:

- herdr-core's document store (`doc.get` / `doc.set`) caps each value at 1 MiB, keeps every name it has seen for good, and rewrites one `docs.json` on every write. One document per month or per task does not hold for events; a few fixed-name documents holding only current state do.
- Events as JSON lines are 1.7 MB per month now and 6.8 MB at 4x. No herdr API appends to a file, so several writers on one file lose updates.
- SQLite would need a `sqlite3` binary that herdr does not ship, and a mod cannot open a database itself.

## Decision

**In-progress state** lives in herdr-core's document store, in a few documents with fixed names. Only these names are used:

| Name | Writer | Holds | Cap | Pruning |
| --- | --- | --- | --- | --- |
| `org-state` | the secretary | the work in progress and the approvals waiting for the person | 64 KiB | a task leaves `work` when it finishes or is dropped; an approval leaves `approvals` when the person answers |

A new name is added by changing this table, with its writer, cap and pruning rule. No document is named after a task, a worker or a date. Each document has one writer, so a version conflict means a retry by that writer, never a merge between parties. The shape of `org-state` is in [prototype 1](../design/prototype-1.md#the-org-state-document).

**History** is JSON lines, one file per writer per month: `events/<YYYY-MM>/<writer-id>.jsonl`, the month in UTC. A writer only appends to its own file. Each line carries the writer's own sequence number and a UTC timestamp, and readers merge files by `ts`, then `seq`. The party that causes an event writes its line; nothing copies events out of `hc events` after the fact. The files live on one host, the primary.

The log is for audit. Questions about what is happening now are answered from the documents, not by scanning the log.

**No SQLite.**

## Consequences

- Nothing beyond herdr is installed for the records. A mod reads a document through `hc connect`; the shell and `hc` reach both forms.
- `docs.json` stays small and bounded: one entry per fixed name, each under its cap.
- Concurrent appends (Q8 point 1) do not arise, because every file has one writer. Order across machines (point 5) comes from per-writer `seq` plus `ts` on the primary.
- Monthly files are kept as they are; readers look at the last two months only. No roll-up job is defined (point 9). At 4x this is about 80 MB per year on disk.
- Searching across all history is a text scan. If that becomes daily work, this decision is revisited rather than worked around.
- Still open: where the `events/` folder sits on the primary, the writer ids, the line fields beyond `ts` and `seq`, and which event kinds are kept at all (point 7). They are settled when the first history writer is built.
- Prototype 1 uses only `org-state` and writes no history.
