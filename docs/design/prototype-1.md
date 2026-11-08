# Prototype 1

Status: prototype. This is the first runnable piece of paddock. It shows, in herdr-app, what the secretary is waiting on the person for and the work in progress, read from the core document `org-state`. It follows [decision 0003](../decisions/0003-screen-as-app-mods.md) (the screen is app mods) and [decision 0004](../decisions/0004-records-documents-and-jsonl.md) (in-progress state in fixed-name core documents).

## What is in it

| Path | What it is |
| --- | --- |
| [`templates/secretary.md`](../../templates/secretary.md) | The secretary as an `hc` template. The header starts Claude Code; the body is the role's instructions, in English, with the conversation language as a setting. |
| [`mods/org-agents/`](../../mods/org-agents/) | A herdr-app mod, started as `mod.clone` of the shipped `agents` mod. It reads `org-state` and draws the approvals as cards and the work in progress as a list. |

Not in it: the `org` mailbox server, the events bridge, the worker template, any history file, and the left-hand worker tiles and centered secretary of the [screen](architecture.md#7-the-screen). The mod opens as a dialog; it is not placed in a layout yet.

## The `org-state` document

`org-state` is a core document (`doc.get` / `doc.set`). The secretary is its only writer. Its value, for this prototype:

```json
{
  "updated_at": "2026-11-09T03:40:00Z",
  "work": [
    { "task_id": "demo-working", "title": "Draft the worker template", "since": "2026-11-09T02:58:00Z" }
  ],
  "approvals": [
    { "id": "a1", "task_id": "demo-blocked", "question": "Let demo-blocked run npm publish to the internal registry?", "asked_at": "2026-11-09T03:31:00Z" }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `updated_at` | When the secretary last wrote the document. |
| `work[]` | One entry per task in progress. `task_id` is the same value as the worker terminal's `task_id` label; `title` is a few words for people; `since` is when the task started. |
| `approvals[]` | One entry per decision waiting for the person. `id` is unique within the document; `task_id` names the task it belongs to; `question` is one sentence that can be answered yes or no; `asked_at` is when it was asked. |

Times are UTC in ISO 8601. The cap is 64 KiB. A task leaves `work` when it finishes or is dropped, and an approval leaves `approvals` when it is answered ([decision 0004](../decisions/0004-records-documents-and-jsonl.md)). A value of `null`, or a document never written (version 0), means there is nothing to show yet.

## What the mod shows

- **Waiting for you**: one card per approval, oldest first, at most two, then "and N more". A card shows the question (at most two lines), then the task and how long it has waited.
- **In progress**: one row per task: a status glyph, the title, and how long it has been running. Blocked tasks come first, then working ones, then the rest by start time. The status is the live status of the terminal labelled with that `task_id` (`terminals()`, as herdr-core reports it). A task with no live terminal shows a ring in the theme's `unknown` color.
- When `org-state` has not been written: "The secretary has not written anything yet." When `hc` cannot be reached: "Can't reach hc." and the first line of the error.

There are no tables, counts or borders. Only theme colors are used, so the mod follows the person's theme.

The mod reads `org-state` every 5 seconds. `hc` has no CLI verb for documents and a mod's `exec` has no stdin, so it runs one shell that pipes a `doc.get` line into `hc connect`: `sh` on Linux and macOS, and `pwsh` on Windows, where neither `sh` nor `hc` is usually on `PATH` (it uses `hc` from `PATH` if present, else herdr-core's default install folder).

`hc connect` (hc 0.1.18, Windows) can end at the end of its input before it writes the answer. Measured on 2026-11-09: `hc connect < file` printed nothing, while the same line followed by keeping input open for 2 seconds (`{ printf '%s\n' "$req"; sleep 2; } | hc connect`) answered every time. The mod therefore keeps input open for 1 second after its request, and any script that writes `org-state` should do the same.

## Start it

1. Copy `mods/org-agents/main.js` and `mods/org-agents/mod.json` into herdr-app's `mods/org-agents/` folder (create the folder with `herdr-app do mod.clone '{"name":"agents","as":"org-agents"}'` the first time, so it gets the type files).
2. `herdr-app check <herdr-app folder>/mods/org-agents` must pass.
3. Copy `templates/secretary.md` into herdr-core's `templates/` folder (on Windows, under `%APPDATA%\herdr-core\templates`). Start the secretary with `hc run --bg --keep --name secretary secretary`. Templates run their command through `sh`, so on Windows `sh` must be on `PATH`.
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

- The conversation language is a line in the template body (`Conversation language: auto`). That is one option of [Q9](open-questions.md#q9-where-does-the-conversation-language-setting-live), used here to have something runnable; Q9 stays open.
- The template tells the secretary to use the `org` tools, which do not exist yet, and not to fall back to `hc send` ([decision 0002](../decisions/0002-org-mailbox-not-hc-send.md)).
- The secretary writes `org-state` by hand through `hc connect`; a helper that reapplies a change on a version conflict comes with the `org` server.
- The mod polls. Core sends doc events in `hc events`; following them needs a reader that outlives one `exec` call (30 seconds).
- On Windows, `pwsh` must be installed (PowerShell 7). Windows PowerShell 5 is not tried.
