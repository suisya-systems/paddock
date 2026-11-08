# 0003. The screen is built as herdr-app mods

Status: accepted (2026-11-09)

## Context

[Open question Q1](../design/open-questions.md#q1-app-mod-or-our-own-client) asked whether paddock's window is a set of herdr-app mods or a client of our own (a TUI, a native app, or a web client) that uses only herdr-core.

What was known:

- Mods are JavaScript describing native GPUI elements, with live `agents()`, `terminals()`, `spaces()`, `exec`, file access, overlays that can hold a live terminal, notifications and shared state.
- The mod loop was measured on herdr-app 0.1.13: duplicate the shipped `agents` mod, change one line, `herdr-app check`, save to redraw, `herdr-app shot`. About 1.7 seconds from saving to the PNG.
- Every own-client option means building what herdr-app already does (attaching terminals, laying out panes, following status) before showing anything paddock-specific.

## Decision

The window is herdr-app with paddock's own mods. paddock keeps its mods in this repository under `mods/org-*/`, each started as a `mod.clone` of a shipped mod so it records `cloned_from`. They are installed by copying them into herdr-app's `mods/` folder.

The organization layer (templates, the `org` tools, the record store, skills) still does not depend on the window ([architecture §2](../design/architecture.md#2-design-principles), principle 5). A mod reads it the same way any other client would: through `hc` and its documents.

## Consequences

- paddock follows herdr-app's release cadence and its type files (`herdr.d.ts`, `gpui-kit.d.ts`), which are rewritten on every start. A mod may need changes when the app updates.
- The window needs a GPU (Vulkan on Linux).
- `herdr-app check` does not lay out a mod, so every change to a mod is also looked at with `herdr-app shot`. The first prototype is checked this way ([prototype 1](../design/prototype-1.md)).
- Mods are trusted code. Who may change them is still [open question Q5](../design/open-questions.md#q5-does-the-secretary-write-mods).
- Our own TUI, native app and web client are not pursued now. A web client for reaching the cockpit from a phone can be reconsidered later; it would read the same organization layer.
