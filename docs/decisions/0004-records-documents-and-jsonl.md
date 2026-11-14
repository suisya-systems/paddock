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
| `conveyor-contract` | the secretary | the approved scope, parallel count, deadline and merge handling of the conveyor ([Q15](../design/open-questions.md#q15-which-of-the-predecessors-optional-organization-features-carry-over)) | 16 KiB (proposed, not measured) | replaced whole when the owner approves a new scope; set to `null` when the scope ends. Progress is not held here: it is the kept history kinds |

A new name is added by changing this table, with its writer, cap and pruning rule. No document is named after a task, a worker or a date. Each document has one writer, so a version conflict means a retry by that writer, never a merge between parties. The shape of `org-state` is in [prototype 1](../design/prototype-1.md#the-org-state-document); each `approvals` entry carries `answer_in` (`"worker"` or `"secretary"`), who the person answers, so the screen offers only the answer that works (Issue #127). `secretary-handover` is free-form JSON for one reader (the next secretary); its cap is half of `org-state`'s, so a fresh context starts small, and far under the 1 MiB store limit. A `null` value means no handover is pending, and the handover script refuses to end the secretary then.

**History** is JSON lines, one file per writer per month: `events/<YYYY-MM>/<writer-id>.jsonl`, the month in UTC. A writer only appends to its own file. Each line carries the writer's own sequence number and a UTC timestamp, and readers merge files by `ts`, then `seq`. The party that causes an event writes its line; nothing copies events out of `hc events` after the fact. The files live on one host, the primary.

**Read bound.** The readers scan the two newest months, so their cost follows the lines in that window. Measured on a synthetic folder (Issue #332; `scripts/probes/record-growth-time.sh`, bash 5 on WSL2, median of 3, one process each, 9 writers):

| Reader | 1x: 20,000 lines, 3.5 MB | p95: 60,000 lines, 10.8 MB | 10x: 200,000 lines, 36 MB | Stops being fast |
| --- | --- | --- | --- | --- |
| `check_messages` | 0.22 s | 0.57 s | 1.79 s | 1 s at about 110,000 lines (19 MB) |
| `list_runs` | 0.28 s | 0.77 s | 2.62 s | 1 s at about 75,000 lines (13 MB) |
| `wait`, one poll | 0.22 s | 0.55 s | 1.71 s | 0.5 s (a quarter of the 2 s poll) at about 55,000 lines (10 MB) |

1x is 10,000 lines a month and p95 is assumed to be 3x the mean (Q8's sizing, 178 bytes a line in the synthetic folder). Cost is linear, about 9 ms per 1,000 lines in the window. "Fast" means under 1 s for a reader that runs once a turn, under 0.5 s for one poll of `wait`.

**Measured on the real folder** (2026-11-14, `record-growth-measure.sh`, read-only): 241 lines and 87 KB in the first 14 days of a month, with 59 runs started. The secretary wrote 68% of the lines (163 lines, 352 bytes each); the other writers one to six lines per task. A round (the lines that carry one task id, over all writers) is 3 lines and 1.8 KB on average, 10 lines and 5.4 KB at p95, 11 lines and 9.2 KB at most. The mean line is 360 bytes, twice the synthetic 178: `approval_asked`, `run_completed` and `work_added` lines are large. The real rate (about 500 lines a month) is far below 1x, so no reader is near its limit today. The line counts in the table stand; the byte columns are about half of what real lines would give.


**The bound is 50,000 lines in the two-month window (about 18 MB at the real 360 bytes a line), which is 2.5x the 1x window and below every row above.** p95 sits at 60,000, so a busy month already crosses it: past the bound the roll-up is due, and until it exists, `PADDOCK_WAIT_POLL` can be raised so `wait` polls less often. The roll-up keeps what readers use (the latest line of each run and summary, and each id's last ack) in one small file per month, so a reader scans that and the current month's unread tail, not every line. It is a separate Issue; this decision sets only when it is needed. One writer's file stays under the 8 MB `file.read` cap ([0006](0006-remote-worker-history-host.md)) until the secretary's file reaches about 23,000 lines at 352 bytes, which at its real 68% share is about 34,000 lines a month, or 3.4x the 1x month. That is earlier than the bound's byte size suggests, so a remote reader of the secretary's file needs the roll-up before the local readers do.

The log is for audit. Questions about what is happening now are answered from the documents, not by scanning the log.

**No SQLite.**

## Consequences

- Nothing beyond herdr is installed for the records. A mod reads a document through `hc connect`; the shell and `hc` reach both forms.
- `docs.json` stays small and bounded: one entry per fixed name, each under its cap.
- Concurrent appends (Q8 point 1) do not arise, because every file has one writer. Order across machines (point 5) comes from per-writer `seq` plus `ts` on the primary.
- Monthly files are kept as they are; readers look at the last two months only. No roll-up job exists yet (point 9); the read bound above says when it is needed (Issue #332). At 4x this is about 80 MB per year on disk.
- Searching across all history is a text scan. If that becomes daily work, this decision is revisited rather than worked around.
- Settled by the first history writer (Issue #60, `scripts/org`): the folder is `$PADDOCK_STATE_DIR/events/` (default `~/.local/state/paddock`); the writer id is the agent's `--as` id (`secretary`, `w-<task_id>`); a line is `{"seq","ts","from","kind","to","task_id","text"}`. The kinds written so far are `message`, `ack`, `summary`, `run_started`, `run_completed`, `run_blocked`, and `ci_completed` (from `org-pull-request` through `scripts/org ci_completed`, Issue #168: same file, `seq` and lock as the secretary's other lines, its own fields after `seq` and `ts`; the writer is named in `from`, as on every line). The next `seq` of an id is kept in `events/<id>.seq`, written under the same lock as the append (Issue #222), so a write does not read the id's history. Still open: which other event kinds are kept at all (point 7). There is no events bridge for now ([Q8](../design/open-questions.md#q8-what-is-each-component-written-in), decided 2026-11-11).
- Prototype 1 uses only `org-state` and writes no history.
