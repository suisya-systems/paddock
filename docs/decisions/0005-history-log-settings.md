# 0005. History log: folder, writer ids, line fields and kept event kinds

Status: proposed (draft for the owner, 2026-11-11). Nothing here is decided until the owner marks it accepted. Settles the points [0004](0004-records-documents-and-jsonl.md) left open (Issue #15).

## Context

0004 fixes the shape: `events/<YYYY-MM>/<writer-id>.jsonl`, UTC month, one writer per file, `seq` and `ts` on every line, files on the primary. The first writer (Issue #60) already chose values for the folder, the ids and the fields; the kinds are the open part ([Q8](../design/open-questions.md#q8-what-is-each-component-written-in) point 7). Each row below gives a recommendation and its source. The owner may change any of them.

## Proposal

| Point | Recommendation | Source |
| --- | --- | --- |
| Folder on the primary | `$PADDOCK_STATE_DIR/events/`, default `${XDG_STATE_HOME:-~/.local/state}/paddock`. Keep. | `scripts/org:40`, `scripts/org:72` |
| Writer ids | The agent's `--as` id: `secretary`, `w-<task_id>`; lowercase letters, digits, `_`, `-`. Keep. (A hook that writes `hook_denied` would need an id; not settled, see the kinds table.) | `scripts/org:65`, `scripts/org:70` |
| Line fields | `seq`, `ts`, `from`, `kind`, `to`, `task_id`, `text` for mailbox and run lines. Keep. `ci_completed` is the one other shape (`ts`, `kind`, `writer`, `task_id`, `pr`, `sha`, `run_id`, `exit_code`, `conclusion`). Recommend it use `from` instead of `writer`, so every line has `seq`, `ts`, `from`, `kind` and the rest is per kind. Today the reader's pattern skips a line without `to` and `text`, so `ci_completed` is never read as mail (that is wanted; the rename would keep it so). | `scripts/org:109`, `scripts/org:152`, `scripts/org:215` |
| Kept kinds | See the next table. | below |

### Kinds

Counts are the predecessor's last 30 days (secretary's count from its state DB, 2026-11-11). The predecessor's mix is a planning input, not a forecast.

| Kind (paddock) | Predecessor rows / 30 d | Recommendation | Why |
| --- | --- | --- | --- |
| `message`, `ack`, `summary` | `delegate_sent` 351, `worker_reported` 191, `worker_escalation` 81 (about 620 messages; one `ack` each) | Keep | They are the mailbox itself ([0002](0002-org-mailbox-not-hc-send.md)), not a copy of anything. |
| `run_started`, `run_completed`, `run_blocked` | `worker_completed` 141, `pr_merged` 297 | Keep | `list_runs` reads them. |
| `ci_completed` | 414 | Keep | A GitHub fact `hc` does not have; the secretary reads it. |
| `secretary_handover`, `suspend`, `self_edit_approval_sent` | 13, 16, 41 | Keep | Audit of a person-facing step. Small. |
| `worker_spawned`, `worker_spawn_verified`, `pane_closed`, `worker_pane_closed`, `pr_watch_pane_started` | 360, 350, 127, 2, 399 | Drop | Copies of herdr facts, available from `hc get` and `hc events` (inventory REC-3). |
| `codex_round_started`, `acceptance_gate`, `worker_model_set`, `fix_pushed`, `pr_opened`, `notify_sent`, `work_discovery_scanned` | 553, 256, 315, 215, 208, 448, 241 | Drop | The tool's own measurements or facts on the PR. If wanted later, a counter (Q8 point 7). |
| `hook_denied` | 1,212 (21% of rows, 527 KB payload) | **Owner's call.** Recommend drop. | Q11 dropped the defense report for now (inventory REC-10), so nothing reads it; HK-16 is open. If kept: a worker's hook appends to that worker's own file, and the count is an `awk` over the month. |

The remaining predecessor kinds (30 or fewer rows each) are not kept unless a reader asks for them.

### Size

Line size is the payload plus about 110 bytes of `seq`, `ts`, `from`, `kind`, `to`, `task_id` (my estimate from `scripts/org:109`); `ack` lines are about 170 bytes. All numbers are for the predecessor's last 30 days; "10x" multiplies row counts as Q8 point 6 asks. Estimates, not measurements of paddock.

| Set | Rows / 30 d | Bytes / 30 d | At 10x, per month | p95 day, now | p95 day, 10x |
| --- | --- | --- | --- | --- | --- |
| Everything the predecessor wrote | about 5,800 | about 1.7 MB | about 17 MB | 772 rows, 175 KB | 7,700 rows, 1.7 MB |
| Recommended set (no `hook_denied`) | about 2,200 | about 0.6 MB | about 6 MB | about 290 rows, 60 KB (set share of all rows, 0.37) | about 2,900 rows, 0.6 MB |
| Recommended set plus `hook_denied` | about 3,400 | about 1.3 MB | about 13 MB | about 480 rows, 110 KB | about 4,800 rows, 1.1 MB |

Checks against the limits:

- `file.read` caps at 8 MB per call. Files are per writer, so a file is the share of one writer. At 10x the recommended set is about 6 MB for all writers together, under 8 MB even if one writer wrote all of it. The unfiltered set (17 MB) would not fit one file; by actor, `hook_denied` alone was 1,212 rows with a busiest day of 556 from one actor, and every other actor was far lower.
- Readers look at two months (0004), so at 10x about 12 MB of text for the recommended set, about 26 MB with `hook_denied`, scanned by `sed` in `window()` (`scripts/org:148`).
- One thing the numbers move: `next_seq` reads every month's file of the id on every append (`scripts/org:95`, with its `ponytail:` note). At 10x the secretary's file is a few MB per month, so a write reads tens of MB after a year. A high-water file per id would fix it; not part of this decision.

Sources: sizes and p95 from the secretary's read of the predecessor's state DB (rows by kind, daily p50 / p95 / maximum, 2026-11-11); the 30-day total, busiest day and 10x / p95 rule from Q8; the 8 MB cap from Q8 point 1.

## If accepted

- Fold the folder, ids and fields into 0004's last-but-one consequence, and the kinds into this record's table; list further kinds only by changing the table.
- Rename the `ci_completed` field `writer` to `from` (a small change in `scripts/org`, its own issue).
- Owner's call on `hook_denied` decides inventory HK-16 and the last line of REC-10.
