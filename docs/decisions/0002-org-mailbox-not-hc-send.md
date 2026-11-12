# 0002. Agents message each other through the organization's mailbox, not `hc send`

Status: accepted (2026-11-08)

## Context

Agents in paddock need to talk to each other: a worker reports to the secretary, the secretary answers a worker's question.

herdr-core offers `hc send <t> "text"`. Its documentation describes it as pasting text into a terminal and pressing Enter, waiting for a person to pause. It is not a message box: the text becomes whatever the target's input field turns it into. Measured on hc 0.1.18 with Claude Code 2.1.319:

- Sent to an idle agent, the text became its next prompt.
- Sent while the agent had half-typed input, it was joined to that input with no separator and submitted as one prompt (`half typedMSG-C from child: ...`).
- It was refused while the target was still starting (exit 5), while it was `blocked` (exit 9), and with `--if idle` while it was working (exit 10). Nothing was queued for later.
- Delivery to an agent in the middle of a turn was not observed.

The predecessor, claude-org-ja, used a peer messaging design with three operations (`send_message`, `check_messages`, `set_summary`). Messages went into a box and the receiver read them when it chose, so a message never interrupted a turn, never mixed with someone's typing, and was not lost because the receiver was busy.

## Decision

Messages between agents go through the organization's mailbox: an `org` mailbox offering `send_message`, `check_messages`, `set_summary`, `report` and `list_runs`, with the box stored in `state.db`. It does not depend on any terminal.

`hc send` is used only to give an agent its first task (normally inside `hc run` itself) and for interrupts. No agent types into another agent's prompt to talk to it.

One more use (Issue #282): after `org-escalation answer`, an `idle` worker gets one `hc send --if idle` that only tells it to run `check_messages`. The answer itself still travels in the mailbox. A worker that has ended its turn starts no next turn without outside input, so a mailbox message alone never wakes it. A working worker is not touched, and a refused nudge does not fail the answer.

## Consequences

- Status, messages and signals stay on three separate channels (OSC 7501 status in herdr-core, the mailbox, and window notifications), as the [architecture](../design/architecture.md#2-design-principles) requires.
- Receivers must check the box. The secretary does so at the end of every turn. Completion raises no window notification and herdr-core's child notes are turned off (`notes = false`), as decided in [Q2](../design/open-questions.md#q2-how-much-of-a-childs-reporting-goes-through-the-mailbox) (2026-11-10).
- paddock must build and run the `org` commands and their storage. They are shell commands, as decided in [open question Q8](../design/open-questions.md#q8-what-is-each-component-written-in).
- Templates and skills must tell agents to report through the mailbox, replacing herdr-core's default advice to report with `hc send`.
