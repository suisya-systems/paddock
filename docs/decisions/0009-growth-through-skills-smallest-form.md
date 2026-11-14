# 0009. Growth through skills: the smallest form (raw notes, curator trigger, candidate queue, skill template) and what counts as "learned"

Status: **accepted** (2026-11-14, owner: all four questions as recommended, plus the rule that the curator judges candidates on all accumulated notes, see Part 4). Refs #336 (goal clause G8). This file records the decision only; the parts are built in separate tasks.

## The question, in plain words

One of the three founding ideas is "the organization grows by adding skills". Today nothing of it exists: no place where a worker's lessons are kept, nothing that notices lessons piling up, no list of skills worth writing, no starting shape for a new skill. The README lists this as not built (inventory rows SK-7, SK-8, REG-4, GT-11, all "Keep"). We need the **smallest** version that closes the loop once, and a test that says the loop closed.

## What exists today (checked in this repository)

| Fact | Where |
| --- | --- |
| The curator is a role on paper only: "a template the secretary starts when a threshold is reached". There is no curator template and no `knowledge/` folder. | [architecture §3](../design/architecture.md#3-roles), `templates/` |
| Records follow one rule: in-progress state in fixed-name core documents, history in per-writer monthly JSON lines, **one writer per file**, no new language, no SQLite. | [0004](0004-records-documents-and-jsonl.md) |
| Agents talk through the mailbox. A worker's last act is `report done`, a plain mailbox call whose text is free; the hook lets nothing else through. | [0002](0002-org-mailbox-not-hc-send.md), `templates/worker-rules.md` |
| A worker writes only its worktree and the files named for it in its per-task settings. A single-file `allowWrite` held for Bash; the Edit tool is not bounded by it; a file that did not exist at launch was **not measured**. `knowledge/raw/` has no assigned path. | inventory L-K4, REG-4 |
| Skills are folders: `skills/<name>/SKILL.md` (front matter `name`, `description`), `scripts/`, `references/rationale.md`. A test forbids Issue numbers and links out of the folder in skills. | `skills/org-close/`, `tests/skill-selfcontained.test.sh` |
| `org-close` already ends every task. The predecessor ran its "curate check" there (MON-9). | [org-close](../../skills/org-close/SKILL.md) |
| The predecessor's rules, to keep in shape if not in code: raw note with four headings (facts, judgment, grounds, where it applies); candidate queue with statuses; curator at 5 raw notes or 5 pending candidates; five-signal eligibility check. | REG-4, REG-5, SK-8, GT-11 |
| The ground rules say shell only, no Python or Node. Counting files is `ls` and `wc`. | README Assumptions, GT-11 |

## Part 1. Where raw notes come from and live

A raw note is one task's reusable lesson, four headings (`## Facts`, `## Judgment`, `## Grounds`, `## Where it applies`), only when it is reproducible, non-obvious and not in the docs.

### (A) The worker puts the note in its `report done` text; the secretary saves it as a file

The worker's rules say: if you learned something reusable, end your report with the four-heading note. The secretary (or `org-close`) writes it to `$PADDOCK_STATE_DIR/knowledge/raw/<date>-<topic>.md`.

- **Cost:** no new write surface for workers and nothing to measure; one writer per file stays true (0004). A step in `org-close` or the secretary's rules to save it. The report hook already allows multi-line text. The note is only as good as the worker's report; a worker killed before reporting leaves none.
- **Covers:** everything the loop needs. The mailbox history already keeps the report text, so a lost file can be rebuilt.

### (B) The worker writes its own note file

Org-delegate adds the one note path to the worker's `allowWrite` (like its history file).

- **Cost:** needs the unmeasured case (a file that does not exist at launch) measured first; the Edit tool is not bounded by the entry, so "its own file only" is by convention; one more per-task setting to build and test. The gain is a note written in the worker's own words at the moment of learning, and one path less through the secretary.

### (C) The worker commits the note in its pull request

- **Cost:** the lesson lands in the target repository, which may be public and is not ours; every task's diff grows by a file nobody asked for. Rejected, not recommended.

**Recommendation: (A).** It is the only form that adds no permission and no measurement. If notes prove too thin, (B) is a later change to one skill and one setting.

## Part 2. Where curated notes and the queue live

### (a) The state folder, per machine: `$PADDOCK_STATE_DIR/knowledge/{raw,curated}/` and `knowledge/skill-candidates.md`

- **Cost:** private by default (lessons often name internal paths and hosts, the reason the predecessor split private and public). Not versioned, not shared across machines, lost with the folder. Nothing to review.

### (b) A `knowledge/` folder in this repository, committed

- **Cost:** every note becomes a pull request or a direct commit; the owner reads and can correct it, and other machines see it. But raw notes are noisy, and this repository would carry private detail. Raw notes fit (a); curated notes might fit (b) later.

**Recommendation: (a) for raw notes, curated notes and the queue; (b) only for what is accepted: a new skill folder under `skills/`, through a pull request.** What is shared and reviewed is the skill, not the notes behind it.

## Part 3. What starts the curator

### (1) A count at `org-close`

After a worker is closed, `org-close` counts `knowledge/raw/*.md` and pending entries in the queue (`ls`, `grep -c`, `wc`). At 5 raw notes not yet reviewed (newer than the file `knowledge/last-curated`, which the curator touches at the end of a cycle; `find -newer`) or 5 pending candidates (the predecessor's numbers) it prints one line, and the secretary's rules say: start the curator. The count is shell, tested against a fake folder; no resident process.

- **Cost:** one function in `org-close` and a test; a person must also be able to ask for it on demand. The 20-work-skills threshold of the predecessor is dropped: there are no work skills yet.

### (2) Only when the person asks

- **Cost:** nothing to build; the loop never closes unless someone remembers. It is the state the organization is in now.

### (3) A watcher terminal that counts on a timer

- **Cost:** one more resident terminal, which [0008](0008-who-tells-the-person-outside-the-window.md) already builds for another job. Counting only at close is enough, because notes arrive only when a task ends.

**Recommendation: (1), plus on demand by the person.**

## Part 4. What the curator does, and the queue

The curator is a template (`templates/curator.md`, same front matter as the others, `check-templates.sh` covers it) started with `hc run --bg --name curator`. One cycle per start: read **all** accumulated notes in `raw/`, not only the new ones; merge into `curated/<topic>.md`; and for each pattern that passes the check below, append one entry to the queue. A note that is not yet a candidate is **kept in `raw/`**, not archived or deleted, and is read again at the next start: the count of 5 is the signal to start, and the judgment is made on the whole pile, so a pattern that needs 10 or 20 notes to show itself is found when it does. Only a note that a curated note has fully absorbed, or that a merged skill came from, moves to `raw/archive/` (still counted by the gate below). Finally the curator touches `knowledge/last-curated`. It reports to the secretary through the mailbox, never to the person. It writes only `knowledge/`; it creates no skill.

**Queue entry** (a line `- **status**: pending` is what the count matches): date and pattern name; the raw files it comes from; one line on when it applies; proposed skill name; status `pending | approved | rejected | merged-into-<skill>`; decision date; reason if rejected.

### Eligibility: when does a pattern become a candidate?

| Form | Cost |
| --- | --- |
| The predecessor's five signals, scored | Faithful, but five scores to define, explain and test; most of the predecessor's text is this. |
| **Two gates plus judgment** | Three or more notes in `raw/` or `raw/archive/`, from different tasks, name the same pattern (counted over everything accumulated, not one cycle), **and** the curator can write one sentence saying when to use it. Both are checkable by `grep`. Anything beyond is the curator's judgment, written into the entry. |
| No gate, the curator decides | Cheapest; nothing to check, and a one-off lesson can become a skill. |

**Recommendation: two gates.** They are the two signals that can be tested without judgment, and they keep the queue from filling with one-offs.

## Part 5. The template a new skill starts from

`templates/skill/` holds the shape, copied and filled in by whoever writes the skill (the secretary through a worker, in a pull request). It is a copy, so a skill stays self-contained.

```
skills/<name>/SKILL.md              front matter: name, description (when to use, one sentence, searchable words)
skills/<name>/references/rationale.md   why it is built this way; names the raw notes it came from
skills/<name>/scripts/<name>.sh     only if a step is a fixed procedure (principle 9); else omit
```

`SKILL.md` has three parts: when to use (the sentence from the queue entry), the steps (judgment stays in text, fixed steps go to a script), and what to check afterwards. It must pass `tests/skill-selfcontained.test.sh` (no Issue numbers, no links out). Source note file names go in `rationale.md`, **not** as links, so the test still passes.

A "work skill" is any skill without the `org-` prefix (the predecessor's rule). How a worker is told which work skills exist is **not decided here**; the smallest form is that the secretary reads the `description` lines when it writes a brief. It is a separate question.

## Acceptance: "the organization learned a skill from its own records"

The claim is true when one chain exists and each link can be checked by a shell test or by looking at a file. No link is "the model says it learned".

1. **Records.** At least 3 raw notes in `knowledge/raw/` (or `archive/`) from at least 3 different task ids name one pattern.
2. **Candidate.** The queue holds one entry for that pattern listing those files, with a one-sentence trigger.
3. **Decision.** The entry's status is `approved` with a decision date, set after the owner answered. A skill is never added without this.
4. **Skill.** A folder `skills/<name>/` merged by pull request, built from the template, passing `tests/skill-selfcontained.test.sh`; its `rationale.md` names the raw note files of link 1.
5. **Use.** A later task's history (its brief or its done report) names the skill, and its report records no new raw note on the same pattern.

A script check for 1 to 4 on a fixture folder (`tests/knowledge-chain.test.sh`, shell, fake notes and a fake queue) comes with the build. Link 5 is shown by one real run, written up like the earlier prototypes. **Not part of the acceptance:** how many skills are written, or that a skill saves time (not measured by any means paddock has).

## The owner's answers (2026-11-14)

1. **Where does a worker's lesson come from?** (A): it writes the note at the end of its report and the secretary saves it as a file.
2. **Where do the notes live?** (a): this machine's state folder, private; only an accepted skill goes into the repository, by pull request.
3. **What starts the curator?** (1): a count at the end of each task (5 unreviewed raw notes or 5 pending candidates), and the person can ask for it at any time.
4. **How does a pattern become a candidate, and who says yes?** Two gates (3 matching notes from different tasks, and a one-sentence trigger); nothing becomes a skill until the owner answers, in a batch.

Owner's addition: 5 notes can be thin, and some patterns will only reach skill level at 10 or 20 notes. So the curator reviews the whole pile at every start, keeps notes that did not qualify, and re-evaluates as the pile grows (Part 4).

## Consequences

- Build, each its own task: the raw-note step in the worker rules and `org-close`, the count in `org-close` (with `knowledge/last-curated`) and `templates/curator.md`, whose test covers a note that waits through two cycles and then qualifies, `templates/skill/`, `tests/knowledge-chain.test.sh`. README "Not built yet" keeps the line until the first of these lands, then points here.
- Inventory rows SK-7, SK-8, REG-4, REG-5 and GT-11 get this record as their decision. The privacy split of REG-4 becomes "state folder is private, `skills/` is the product".
- (B) was not chosen, so L-K4's unmeasured case (a file that does not exist at launch) stays unmeasured until a later change asks for it.
