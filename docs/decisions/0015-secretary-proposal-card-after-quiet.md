# 0015. A proposal of the secretary's own goes on the card only after the person is quiet for N minutes

Status: **accepted** (2026-11-16, owner: option B). Refs #444. Built with this record: `org-escalation ask --self`, its `sweep`, the person's chat-line token in the secretary's `UserPromptSubmit` hook, one watcher line, and the cockpit's filter (see [The mechanism](#the-mechanism)).

## The question, in plain words

The cockpit's approval card and the watcher's toast exist only for a worker's question: `org-escalation ask` needs `--task`, and `answer` forwards the reply to `w-<task>`. When the secretary itself proposes something (a merge, a queue order, closing a task), it asks in chat. That gets no card and no toast, so a person who stepped away never hears of it. Should such a proposal go on the card too?

## What exists today (checked in this repository)

| Fact | Where |
| --- | --- |
| `ask` needs `--task <task_id>`; the id is `<task_id>-<UTC time>`. `answer` sends `Answer to your question (<id>): <text>` to `w-<task_id>`. | [org-escalation.sh](../../skills/org-escalation/scripts/org-escalation.sh), `ask` and `answer` |
| A card answer counts only when the person's own history file holds `ANSWER <id> <text>` at or after `asked_at` (`vouch`); a line the person typed in chat is passed with `--from-conversation`. | org-escalation.sh, `heard` and `vouch` |
| Only the secretary writes `org-state`; `scripts/org doc set\|update` refuses any other id. | [scripts/org](../../scripts/org), `doc` |
| The watcher writes recorded facts into the secretary's mailbox and wakes it; it decides nothing. | [decision 0013](0013-watcher-wakes-the-secretary.md) |
| The secretary has a `UserPromptSubmit` hook (`premise-reminder.sh`), which sees every prompt the secretary receives: the person's lines, the watcher's constant wake line and a template's first message. | [templates/secretary-settings.json](../../templates/secretary-settings.json), [scripts/hooks/premise-reminder.sh](../../scripts/hooks/premise-reminder.sh) |

## Options

- **A. Always a card.** Every proposal of the secretary's own also goes on the card at once.
- **B. A card only after the person is quiet.** While the person is in the conversation the proposal stays in chat; it goes on the card only when the person has written no line for N minutes after it was asked.
- **C. Cards for workers only.** Keep today's rule: the secretary asks its own proposals in chat only.

## Decision

**B** (owner, 2026-11-16).

## Why

- **A doubles the question while the person is there.** The person reads the proposal in chat and answers it there; the same question on a card beside it is noise, and an answer on one leaves the other to clean up.
- **C loses the question when the person is away.** A chat line raises no toast; the proposal waits until the person happens to look at the secretary's terminal, which is what the card and the toast exist to prevent.
- **B asks where the person is.** In the conversation, chat; away, the card and its toast, as for a worker's question.

## The mechanism

The watcher decides nothing (decision 0013) and the person's word is checked against the person's own file, as for every card.

1. **The record.** In the turn the secretary asks a yes/no proposal of its own in chat, it runs `org-escalation ask --self` with the card fields. The entry is `secretary-<UTC time>` with `task_id` `secretary`, `origin` `secretary`, `show_at` (asked + `PADDOCK_SELF_CARD_N` minutes, default 10, written once into the entry so no one reads two settings) and `seen` (the person's chat-line token at the time of the ask). An entry with `show_at` is hidden: the cockpit and the watcher's toast leave it out.
2. **The marker.** The secretary's `UserPromptSubmit` hook writes a new token (time in ns and pid) to `<state>/secretary/person-line` for every prompt that is neither the watcher's wake line nor a secretary's first message. A token, not a time: a line in the same second as the ask is still a later line, and a clock step changes nothing.
3. **The decision, in a script.** `org-escalation sweep`, which the secretary runs on each wake: if the token differs from `seen`, the person wrote in chat since the ask, and the entry is removed (`WITHDRAWN`); else at or after `show_at` it is rewritten without `show_at` (`SHOWN`, recorded as `approval_asked` again, so `org rebuild` keeps the later form).
4. **The watcher.** For a hidden entry whose `show_at` has come, one line to the secretary's mailbox (`proposal <id> reached its show time: run org-escalation sweep`), then its usual wake. It reads no marker and writes no document. Once shown, the entry is an ordinary card and toast.
5. **The answer.** On the card, `ANSWER <id> ...` from `person` to the secretary's mailbox as for any card; in chat, `--from-conversation`. `answer` checks it as for any card, removes the entry and prints `ANSWERED <id> -> secretary: <text>`. Nothing is sent to any worker.

## Costs accepted

- A proposal becomes a card only once the secretary has run `sweep` after the watcher's line: one wake later than its `show_at`.
- Any other text sent into the secretary with `hc send` counts as the person and withdraws a hidden proposal. Today only a secretary's first message is sent that way, and it is excluded.
- A shown card is not withdrawn by a later chat line; the person answers it on the card or in chat.
- The secretary must remember to record the proposal (a rule line in its `AGENTS.md`); one it forgets stays in chat only, as before this decision.

## Revisit when

The person wants a proposal on the card at once (A) for some kinds of decision, or another sender starts typing into the secretary.
