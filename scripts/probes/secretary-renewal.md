# Probe: a secretary renewal end to end (Issue #116, Q16, HND-2)

Question: the secretary writes the `secretary-handover` document; [`secretary-handover.sh`](../../skills/secretary-handover/scripts/secretary-handover.sh) ends its terminal and launches a fresh secretary with "resume from the handover" as the task; does the new secretary find the running worker by label and clear the document, with the layout showing it?

## Run

From the repo root, in your own login shell (no agent above it), on a host where `hc` and `claude` run:

```sh
sh scripts/probes/secretary-renewal.sh
```

About 3 to 8 minutes. It starts its own core and a real Claude Code secretary in default permission mode, so it will ask before running `hc`: answer in that terminal (`HC_SESSION=<printed> hc attach secretary`). Add `KEEP=1` to hold the core open at the end for looking at herdr-app. `--dry-run` runs the same steps against a stubbed `hc` (used by CI; no core, no Claude Code). Paste the whole output back.

## Observations to record

Each `RESULT` line in the output is one row. "By eye" rows are not scripted.

| # | Observation | Source | Answers |
| --- | --- | --- | --- |
| 1 | `runner-env` is `clean` (otherwise the handover script exits 4 and nothing below is a result) | `RESULT runner-env` | precondition |
| 2 | The secretary started with its first message sent | `RESULT secretary-start` | #61 launch path |
| 3 | The real secretary wrote `secretary-handover` (document holds the marker) and how long it took, and which permission prompts it hit | `RESULT handover-written`, prompts by eye | "the secretary writes the document" |
| 4 | The secretary started the worker with `--outlive-parent` and the label `task_id=p116-w` | `RESULT worker-started` | Q19 in use |
| 5 | The old secretary was idle before the renewal | `RESULT old-secretary-idle` | [Q18](../../docs/design/open-questions.md#q18-how-does-anything-reach-an-idle-agent) |
| 6 | The handover script's exit code and its messages (exit 8, 9, 10, 11 are findings) | `RESULT handover-exit` | "the script ends its terminal and launches" |
| 7 | A different terminal now holds the name `secretary` | `RESULT new-terminal` | relaunch |
| 8 | The new secretary cleared the document, and how long it took | `RESULT document-cleared` | "clears the document" |
| 9 | The worker is the same terminal and keeps its label | `RESULT worker-survived`, `worker-label` | Q19 across a renewal |
| 10 | The new secretary said it is back and named the worker (screen tail) | `RESULT new-secretary-names-worker`, by eye | "finds the running workers by label" |
| 11 | Whether `hc run` rejects a name held by a finished terminal | not exercised: the script removes the old terminal first. Record it only if the handover output shows `hc rm` or `hc run` failing | Q16 consequence, order |
| 12 | Layout: with herdr-app attached to the probe's core, the worker tile stayed on the left and the new secretary took the centre block with no second empty block; or "not observed" | by eye; `KEEP=1` | #64 re-adoption by labels |
| 13 | Anything the new secretary did that the template does not say (extra prompts, `hc send`, a second document) | screen tail, by eye | defects, to report separately |

A defect in the handover script is reported, not fixed here.

Row 12 depends on how herdr-app attaches to a core other than the default one; that is not measured. If it cannot be attached, write "not observed" and keep the other rows.

## Docs edits prepared (fill the `<<...>>` after the run)

[`docs/design/open-questions.md`](../../docs/design/open-questions.md) Q16, replace the "Not measured" bullet:

```text
- **Measured <<date>> (hc <<version>>, Claude Code <<version>>, `scripts/probes/secretary-renewal.sh`, Issue #116):** a real secretary <<wrote the handover document / did not; prompts it hit>>; `secretary-handover.sh` exited <<code>>, <<ended and relaunched / refused>>; the new secretary <<resumed, found the worker `p116-w` by its label, and cleared the document after about N s / what happened>>; the worker <<stayed the same terminal with its label>>; the layout <<showed it / was not observed>>. <<Findings: a name held by a finished terminal (not exercised, the script removes it first); defects reported as #N.>> Not measured: <<what the run did not cover, for example the layout without an attached app, and idle detection beyond `hc get` status, Q18>>.
```

[`docs/design/predecessor-inventory.md`](../../docs/design/predecessor-inventory.md) row HND-2: in the Status column replace `Unverified (end to end)` with `<<Measured | Measured, with limits>>`, and replace the sentence "Tested only with a stubbed `hc` ... the end-to-end run is the probe ... not yet run." with:

```text
Tested with a stubbed `hc` (`tests/secretary-handover.test.sh`) and measured end to end <<date>> (`scripts/probes/secretary-renewal.sh`, Issue #116): <<the result in two or three sentences, as in Q16>>.
```

Also update the "Not measured" section of [`skills/secretary-handover/SKILL.md`](../../skills/secretary-handover/SKILL.md) in the same change, so the three places agree.
