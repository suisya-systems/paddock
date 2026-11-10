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
| `secretary-handover` | the secretary | what `org-state` lacks, for the next secretary: the last exchange with the person, decisions not yet recorded, open threads with workers ([Q16](../design/open-questions.md#q16-how-is-the-secretarys-context-renewed)) | 32 KiB | replaced whole on every write; set to `null` by the next secretary once it has resumed |

A new name is added by changing this table, with its writer, cap and pruning rule. No document is named after a task, a worker or a date. Each document has one writer, so a version conflict means a retry by that writer, never a merge between parties. The shape of `org-state` is in [prototype 1](../design/prototype-1.md#the-org-state-document); each `approvals` entry carries `answer_in` (`"worker"` or `"secretary"`), who the person answers, so the screen offers only the answer that works (Issue #127). `secretary-handover` is free-form JSON for one reader (the next secretary); its cap is half of `org-state`'s, so a fresh context starts small, and far under the 1 MiB store limit. A `null` value means no handover is pending, and the handover script refuses to end the secretary then.

**History** is JSON lines, one file per writer per month: `events/<YYYY-MM>/<writer-id>.jsonl`, the month in UTC. A writer only appends to its own file. Each line carries the writer's own sequence number and a UTC timestamp, and readers merge files by `ts`, then `seq`. The party that causes an event writes its line; nothing copies events out of `hc events` after the fact. The files live on one host, the primary.

The log is for audit. Questions about what is happening now are answered from the documents, not by scanning the log.

**No SQLite.**

## Consequences

- Nothing beyond herdr is installed for the records. A mod reads a document through `hc connect`; the shell and `hc` reach both forms.
- `docs.json` stays small and bounded: one entry per fixed name, each under its cap.
- Concurrent appends (Q8 point 1) do not arise, because every file has one writer. Order across machines (point 5) comes from per-writer `seq` plus `ts` on the primary.
- Monthly files are kept as they are; readers look at the last two months only. No roll-up job is defined (point 9). At 4x this is about 80 MB per year on disk.
- Searching across all history is a text scan. If that becomes daily work, this decision is revisited rather than worked around.
- Settled by the first history writer (Issue #60, `scripts/org`): the folder is `$PADDOCK_STATE_DIR/events/` (default `~/.local/state/paddock`); the writer id is the agent's `--as` id (`secretary`, `w-<task_id>`); a line is `{"seq","ts","from","kind","to","task_id","text"}`. The kinds written so far are `message`, `ack`, `summary`, `run_started`, `run_completed`, `run_blocked`, and `ci_completed` (from `org-pull-request` through `scripts/org ci_completed`, Issue #168: same file, `seq` and lock as the secretary's other lines, its own fields after `seq` and `ts`). Still open: which other event kinds are kept at all (point 7), and the events bridge.
- Prototype 1 uses only `org-state` and writes no history.
