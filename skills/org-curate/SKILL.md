---
name: org-curate
description: Keep a worker's raw lesson note, count unreviewed notes and pending skill candidates to know when to start the curator, list the patterns that pass the two gates, and check the chain from notes to a new skill. Run it from the secretary.
---

# org-curate

The shell parts of growth through skills. Run it from the secretary, from the paddock folder. Why it is built this way: [references/rationale.md](references/rationale.md).

```sh
bash skills/org-curate/scripts/org-curate.sh save --task <task_id> --topic <kebab-topic>   # note on stdin
bash skills/org-curate/scripts/org-curate.sh count
bash skills/org-curate/scripts/org-curate.sh candidates
bash skills/org-curate/scripts/org-curate.sh finish
bash skills/org-curate/scripts/org-curate.sh settings
bash skills/org-curate/scripts/org-curate.sh start
bash skills/org-curate/scripts/org-curate.sh chain --pattern <p> --skill <s> [--repo <dir>]
```

Everything lives under `$PADDOCK_STATE_DIR/knowledge/` (private, per machine): `raw/`, `raw/archive/`, `curated/`, `skill-candidates.md`, `last-curated`.

## Commands

- `save`: a worker's done report may end with a note with the headings `## Facts`, `## Judgment`, `## Grounds`, `## Where it applies`. Pipe that text in. It writes `raw/<date>-<topic>.md` with a first line `Task: <task_id>`, refuses a note missing a heading, and never overwrites a file (exit 4).
- `count`: prints `N unreviewed raw notes, M pending candidates`. Unreviewed means a file directly in `raw/` newer than `last-curated` (all of them while it does not exist). At 5 of either it adds a line saying to start the curator; `org-close` ends with this line.
- `candidates`: for each `curated/<pattern>.md` that is not in the queue yet, prints `<pattern>`, the number of different tasks, and the raw files, when both gates hold: 3 or more different `Task:` values among the listed notes that exist in `raw/` or `raw/archive/`, and a `When:` line with one sentence. It reads and prints; it moves nothing.
- `finish`: touches `last-curated`. The curator runs it last.
- `settings`: writes the curator's per-run settings file, `<state>/settings/curator.json`, and prints its path. It is [curator-settings.json](curator-settings.json) with `sandbox.filesystem.allowWrite` naming `knowledge/` and the curator's own mail files (`scripts/org own_files curator`), the core's socket folder in `denyRead` and `denyWrite` (`PADDOCK_CORE_SOCKET_DIR`, else the folder of `HC_TERMINAL_SOCKET`; neither: exit 2, nothing written), and `PADDOCK_STATE_DIR` pinned in `env`. The shared part, as for a worker: the sandbox on, `failIfUnavailable`, no rerun outside it, the same deny rules, and a `PreToolUse` hook on the file tools that lets through only a path that resolves under `knowledge/` (the file tools run outside the sandbox). The file sits outside what it allows, so the curator cannot rewrite it.
- `start`: `settings`, then `hc run --bg --name curator curator` with the script's full path in the message. The curator template refuses to start without the file, passes it with `--settings` and runs in `knowledge/`, so the folder Claude Code always lets Bash write is `knowledge/` too.
- `chain`: checks links 1 to 4 of the acceptance chain: records, candidate entry, approved decision with a date, skill folder from `templates/skill/`. It names the first link that fails (exit 1).

## Queue entry

A block of lines in `skill-candidates.md`, written by the curator; the count matches the line `- **status**: pending`:

```
- **pattern**: <name>
- **date**: <YYYY-MM-DD>
- **notes**: <raw/ files, space separated>
- **when**: <one sentence>
- **skill**: <proposed skill name>
- **status**: pending | approved | rejected | merged-into-<skill>
- **decided**: <YYYY-MM-DD>
- **reason**:
```

A pattern already in the queue, whatever its status, is not proposed again.

## What to check afterwards

After `save`, the file is in `raw/`. After a curator run, `count` prints 0 unreviewed notes. After a skill is merged, `chain` prints `links 1 to 4 hold`; `tests/skill-selfcontained.test.sh` covers the real `skills/`.

## Write limit, measured on the host

`scripts/probes/curator-write-surface.sh` (run from the repo root on the host, decoys only) starts `claude -p` with the generated file in a decoy `knowledge/` and asks for Bash writes to `knowledge/`, the curator's own mail, a decoy repository, another id's mail and the settings file itself, and Write tool writes to `knowledge/` and the repository. Result: not run yet.

## Not measured

Tested against throwaway folders only (`tests/org-curate.test.sh`, `tests/knowledge-chain.test.sh`). No real curator has run, and link 5 (a later task uses the skill and records no new note on the pattern) needs one real run.
