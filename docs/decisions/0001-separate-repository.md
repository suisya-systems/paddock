# 0001. Build paddock in its own repository

Status: accepted (2026-11-08)

## Context

paddock rebuilds the ideas of claude-org-ja (talk to a secretary, grow through skills, keep your own records) on herdr-core and herdr-app. The base changes almost completely: terminals, status, monitoring, delegation and the window all move to herdr, and many of claude-org-ja's parts are retired (its transport stacks and terminal adapters, the dispatcher runner, the separate dashboard, pane layouts).

claude-org-ja is in daily use. Changing it in place would mean running two bases side by side in one tree, with every change to the new base risking the old one, until the old one could be removed.

The organization layer is meant to be independent of any one terminal or window. Starting clean is the simplest way to make sure nothing from the old base leaks in by habit.

## Decision

Implement paddock in a separate repository. claude-org-ja is a reference only: its designs and measurements are read and rewritten here, not imported. Decisions are recorded in this repository with their reasons, without depending on another repository's records.

## Consequences

- claude-org-ja keeps working unchanged while paddock is built.
- Parts worth keeping (role contracts, skills, `state.db`) are brought over deliberately and rewritten for herdr, not copied with their old dependencies.
- Fixes to shared ideas may need to be made twice until claude-org-ja is wound down (see [open question Q6](../design/open-questions.md#q6-how-the-predecessors-runtime-pieces-are-wound-down)).
- This repository has to state its own reasons in full, which also prepares it for being published later.
