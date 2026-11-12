# Prototype 1

Status: prototype. This is the first runnable piece of paddock. It shows, in herdr-app, what the secretary is waiting on the person for and the work in progress, read from the core document `org-state`. It follows [decision 0003](../decisions/0003-screen-as-app-mods.md) (the screen is app mods) and [decision 0004](../decisions/0004-records-documents-and-jsonl.md) (in-progress state in fixed-name core documents).

## What is in it

| Path | What it is |
| --- | --- |
| [`templates/secretary.md`](../../templates/secretary.md) | The secretary as an `hc` template. The header starts Claude Code; the body is the role's instructions, in English, with the conversation language as a setting. |
| [`mods/org-agents/`](../../mods/org-agents/) | A herdr-app mod, started as `mod.clone` of the shipped `agents` mod. It reads `org-state` and draws the approvals as cards and the work in progress as a list. |

Not in it: the events bridge. (The `org` mailbox commands and the history files came after this prototype, as [`scripts/org`](../../scripts/org); see the README.) The mod opens as a dialog. The [screen](architecture.md#7-the-screen) itself (worker tiles on the left, the secretary in the centre, the secretary's questions floating, one approval card bottom right) came after this prototype, as the layout [`layouts/paddock.json`](../../layouts/paddock.json) with the mod [`mods/org-cockpit/`](../../mods/org-cockpit/); it reads the same `org-state` (see the [README](../../README.md#the-screen)).

Also built after this prototype: the delegation skill [`skills/org-delegate`](../../skills/org-delegate/SKILL.md), which makes a task's worktree and starts a worker from `templates/worker.md`. A real worker started by the skill has since been measured: [prototype 2](prototype-2.md) (2026-11-10) and [prototype 3](prototype-3.md) (2026-11-11, 20 of 21 steps pass) started workers with `org-delegate` on a host.

## The `org-state` document

`org-state` is a core document (`doc.get` / `doc.set`). The secretary is its only writer. Its value, for this prototype:

```json
{
  "updated_at": "2026-11-09T03:40:00Z",
  "work": [
    { "task_id": "demo-working", "title": "Draft the worker template", "since": "2026-11-09T02:58:00Z" }
  ],
  "approvals": [
    { "id": "a1", "task_id": "demo-blocked", "question": "Let demo-blocked run npm publish to the internal registry?", "asked_at": "2026-11-09T03:31:00Z", "answer_in": "secretary" }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `updated_at` | When the secretary last wrote the document. |
| `work[]` | One entry per task in progress. `task_id` is the same value as the worker terminal's `task_id` label; `title` is a few words for people; `since` is when the task started. |
| `approvals[]` | One entry per decision waiting for the person. `id` is unique within the document; `task_id` names the task it belongs to; `question` is one sentence that can be answered yes or no; `asked_at` is when it was asked; Every entry is answered through the secretary (the card's Yes / No, or words in its pane). A worker's prompt also keeps `prompt` (the prompt text the secretary read) and `prompt_sum` (its checksum), so the relay presses a key only while the same prompt is on the screen ([architecture 7.1](architecture.md#71-approvals), Issue #260). `answer_in` (Issue #127) is no longer written; an old entry's `answer_in` is ignored. The context the person decides with, written by the secretary (Issue #258), each optional: `background` (why it is asked), `if_yes` and `if_no` (what each answer leads to), `recommend` (`"yes"` or `"no"`) and `why` (the reason). The card names the ones missing. |

Times are UTC in ISO 8601. The cap is 64 KiB. A task leaves `work` when it finishes or is dropped, and an approval leaves `approvals` when it is answered ([decision 0004](../decisions/0004-records-documents-and-jsonl.md)). A value of `null`, or a document never written (version 0), means there is nothing to show yet.

## What the mod shows

- **Waiting for you**: one card per approval, oldest first, at most two, then "and N more". A card shows the question (at most two lines), then the task and how long it has waited.
- **In progress**: one row per task: a status glyph, the title, and how long it has been running. Blocked tasks come first, then working ones, then the rest by start time. The status is the live status of the terminal labelled with that `task_id` (`terminals()`, as herdr-core reports it). A task with no live terminal shows a ring in the theme's `unknown` color.
- When `org-state` has not been written: "The secretary has not written anything yet." When `hc` cannot be reached: "Can't reach hc." and the first line of the error.

There are no tables, counts or borders. Only theme colors are used, so the mod follows the person's theme.

The mod reads `org-state` every 5 seconds. `hc` has no CLI verb for documents and a mod's `exec` has no stdin, so it runs one shell that pipes a `doc.get` line into `hc connect`: `sh` on Linux and macOS, and `pwsh` on Windows, where neither `sh` nor `hc` is usually on `PATH` (it uses `hc` from `PATH` if present, else herdr-core's default install folder).

`hc connect` (hc 0.1.18, Windows) can end at the end of its input before it writes the answer. Measured on 2026-11-09: `hc connect < file` printed nothing, while the same line followed by keeping input open for 2 seconds (`{ printf '%s\n' "$req"; sleep 2; } | hc connect`) answered every time. The mod therefore keeps input open for 1 second after its request, and any script that writes `org-state` should do the same. The report to herdr-core is drafted in [`upstream/hc-connect-stdin-eof.md`](upstream/hc-connect-stdin-eof.md); re-measured on 2026-11-10: Windows (hc 0.1.19) answers 0/20 without the hold and 20/20 with it, Linux (hc 0.1.18) answers 20/20 either way. The hold stays on Windows; the Linux one can go once herdr-core confirms the Windows behaviour.

## Start it

1. Copy `mods/org-agents/main.js` and `mods/org-agents/mod.json` into herdr-app's `mods/org-agents/` folder (create the folder with `herdr-app do mod.clone '{"name":"agents","as":"org-agents"}'` the first time, so it gets the type files).
2. `herdr-app check <herdr-app folder>/mods/org-agents` must pass.
3. Copy `templates/secretary.md` into herdr-core's `templates/` folder (on Windows, under `%APPDATA%\herdr-core\templates`). Start the secretary with `hc run --bg --keep --name secretary --cwd <absolute path of the paddock folder> secretary` (`--cwd` is where it finds `scripts/org` and the skill scripts). Templates run their command through `sh`, so on Windows `sh` must be on `PATH`.
4. Open the mod: `herdr-app do mod.open '{"name":"org-agents"}'`. Running it again closes it.

## Check it

1. With `org-state` unwritten, open the mod and take `herdr-app shot`. It shows "The secretary has not written anything yet."
2. Write a value like the example above with `doc.set` through `hc connect`, keeping its input open as described above (get the version with `doc.get` first). Start one or two terminals labelled with a `task_id` from `work` whose program reports an OSC 7501 status, for example `hc run --bg --no-parent --label task_id=demo-working -- <a program that prints ESC ] 7501 ; state=working:app=demo BEL and stays>`.
3. Within 5 seconds the mod redraws. Take `herdr-app shot`. The approvals appear as cards above the list, and the list shows the working spinner, the "Needs you" pill for a blocked task, and the ring for a task with no terminal.
   The demo terminals do not appear in herdr-app's own Agents sidebar (it stays at "No agent status yet", the footer at 0 agents); the mod finds them through the `task_id` label in `terminals()`, so this does not affect it.
4. `check` does not lay out the mod, so the shot is the check that the list and cards have height ([measurement](architecture.md#8-facts-this-design-relies-on)). `shot` returns the last frame the window drew: while the window is not being drawn (minimized or in the background), two shots are identical and miss the dialog. Check by looking at the window, or take the shot right after the window has redrawn.
5. Clean up: close the dialog, `hc kill` and `hc rm` the demo terminals, and set `org-state` back to `null`.

The prototype is done when `check` passes and the shot shows both the approvals and the work in progress.

## Open after this prototype

- The conversation language is a line in the template body (`Conversation language: auto`). That is one option of [Q9](open-questions.md#q9-where-does-the-conversation-language-setting-live), used here to have something runnable. Q9 is decided (2026-11-11): the value lives in `org-config.md` and is added to the secretary's launch task.
- The template tells the secretary to use the `org` commands (`scripts/org`, built in Issue #60) and not to fall back to `hc send` ([decision 0002](../decisions/0002-org-mailbox-not-hc-send.md)). Missing from them: the sender id is taken on trust (`--as`), and the document helper's `doc.set` parameters are not measured against a real core.
- The secretary writes `org-state` with `scripts/org doc update` (re-read, reapply, set on a version conflict). Its `doc.set` request shape is an assumption until a host probe runs.
- The mod polls. Core sends doc events in `hc events`; following them needs a reader that outlives one `exec` call (30 seconds).
- On Windows, `pwsh` must be installed (PowerShell 7). Windows PowerShell 5 is not tried.
