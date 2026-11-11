# 0005. History log: folder, writer ids, line fields and kept event kinds

Status: accepted (2026-11-11, owner). Settles the points [0004](0004-records-documents-and-jsonl.md) left open (Closes #15).

## Context

0004 fixes the shape: `events/<YYYY-MM>/<writer-id>.jsonl`, UTC month, one writer per file, `seq` and `ts` on every line, files on the primary. The first writer (Issue #60) already chose values for the folder, the ids and the fields; the kinds were the open part ([Q8](../design/open-questions.md#q8-what-is-each-component-written-in) point 7).

## Decision

| Point | Value | Source |
| --- | --- | --- |
| Folder on the primary | `$PADDOCK_STATE_DIR/events/`, default `${XDG_STATE_HOME:-~/.local/state}/paddock` | `scripts/org:40`, `scripts/org:72` |
| Writer ids | The agent's `--as` id: `secretary`, `w-<task_id>`; lowercase letters, digits, `_`, `-`. One more: `codex-gate`, the writer of the Codex gate's lines, never a worker's id | `scripts/org:65`, `scripts/org:70` |
| Line fields | `seq`, `ts`, `from`, `kind`, `to`, `task_id`, `text` for mailbox and run lines. `ci_completed` keeps its own fields after `seq` and `ts` (`kind`, `task_id`, `pr`, `sha`, `run_id`, `exit_code`, `conclusion`), but its writer field is `from`, not `writer` (a change in `scripts/org`, its own Issue; the reader's pattern skips such a line, which is wanted) | `scripts/org:109`, `scripts/org:152`, `scripts/org:215` |
| Kept kinds | The next table | below |

### Kinds

Counts are the predecessor's last 30 days (from its state DB, 2026-11-11). The predecessor's mix is a planning input, not a forecast.

| Kind (paddock) | Predecessor rows / 30 d | Kept? | Why |
| --- | --- | --- | --- |
| `message`, `ack`, `summary` | `delegate_sent` 351, `worker_reported` 191, `worker_escalation` 81 (about 620 messages; one `ack` each) | Keep | They are the mailbox itself ([0002](0002-org-mailbox-not-hc-send.md)), not a copy of anything. |
| `run_started`, `run_completed`, `run_blocked` | `worker_completed` 141, `pr_merged` 297 | Keep | `list_runs` reads them. |
| `ci_completed` | 414 | Keep | A GitHub fact `hc` does not have; the secretary reads it. |
| `secretary_handover`, `suspend`, `self_edit_approval_sent` | 13, 16, 41 | Keep | Audit of a person-facing step. Small. |
| `codex_round_started`, `codex_round_denied` | 553, 12 | Keep | The review-round cap is enforced by counting these. See below. |
| `worker_spawned`, `worker_spawn_verified`, `pane_closed`, `worker_pane_closed`, `pr_watch_pane_started` | 360, 350, 127, 2, 399 | Drop | Copies of herdr facts, available from `hc get` and `hc events` (inventory REC-3). |
| `acceptance_gate`, `worker_model_set`, `fix_pushed`, `pr_opened`, `notify_sent`, `work_discovery_scanned` | 256, 315, 215, 208, 448, 241 | Drop | The tool's own measurements or facts on the PR. If wanted later, a counter (Q8 point 7). |
| `hook_denied` | 1,212 (21% of rows) | Drop | Nothing reads it: the defense report is dropped for now (Q11, inventory REC-10). |

The remaining predecessor kinds (30 or fewer rows each) are not kept unless a reader asks for them; a new kind is added by changing this table.

### The Codex round record

The cap on Codex review rounds only holds if it is counted, not asked for in text: the predecessor counted rounds in `tools/codex_round_cap.py:466` and blocked over-cap calls in `.hooks/block-codex-over-cap.sh:21-23`, and a worker had run seven rounds unasked before that. Here:

- The gate hook writes `codex_round_started` and `codex_round_denied` only through a `scripts/org` subcommand, as writer `codex-gate`. Nobody appends such a line by hand.
- The limit check counts the same lines with the same tool.
- The counted file must be one the worker cannot rewrite from Bash. Today a worker's sandbox allows the whole state folder (`templates/worker-settings.json` lines 26 to 28), so this holds only by convention until the write surface is narrowed to the worker's own file (#160, inventory L-K4).
- This decision fixes the kinds and the writer. The counter itself is a separate Issue; inventory L-K10, GT-2 and HK-14 stay Open for that part.

### Size

Line size is the payload plus about 110 bytes of `seq`, `ts`, `from`, `kind`, `to`, `task_id` (my estimate from `scripts/org:109`); `ack` lines are about 170 bytes. All numbers start from the predecessor's last 30 days; "10x" multiplies row counts as Q8 point 6 asks. Estimates, not measurements of paddock. The kept set's share of all rows is about 0.48 (about 2,770 of 5,800).

| Set | Rows / 30 d | Bytes / 30 d | At 10x, per month | p95 day, now | p95 day, 10x |
| --- | --- | --- | --- | --- | --- |
| Everything the predecessor wrote | about 5,800 | about 1.7 MB | about 17 MB | 772 rows, 175 KB | 7,700 rows, 1.7 MB |
| Kept set | about 2,770 | about 0.76 MB | about 7.6 MB | about 370 rows, 80 KB | about 3,700 rows, 0.8 MB |

Of the kept set's 0.76 MB, `codex-gate` is about 0.16 MB (565 rows), which is 1.6 MB a month at 10x in its own file; the other writers together are about 6 MB at 10x.

Checks against the limits:

- `file.read` caps at 8 MB per call. Files are per writer. At 10x the kept set is 7.6 MB for all writers together, close to the cap if one writer wrote it all; the separate `codex-gate` id keeps the rest near 6 MB, and no single writer is expected to hold most of it. The unfiltered set (17 MB) would not fit one file.
- Readers look at two months (0004), so at 10x about 15 MB of text, scanned by `sed` in `window()` (`scripts/org:148`).
- `next_seq` reads every month's file of the id on every append (`scripts/org:95`, with its `ponytail:` note). At 10x the secretary's file is a few MB per month, so a write reads tens of MB after a year. A high-water file per id would fix it; not part of this decision.

Sources: rows by kind, daily p50 / p95 / maximum and per-actor counts from the predecessor's state DB (payload bytes only, 2026-11-11); the 30-day total, busiest day and the 10x / p95 rule from Q8; the 8 MB cap from Q8 point 1.

## Consequences

- 0004's last-but-one bullet is superseded by this table for the folder, ids, fields and kinds; the `ci_completed` field rename is its own Issue.
- Inventory HK-16 (`hook_denied`) is dropped; REC-3 and REC-10 point here; HK-14, GT-2 and L-K10 have their record and writer fixed and keep the counter Open.
- A Codex gate hook needs `scripts/org` subcommands for the two kinds (separate Issue).
