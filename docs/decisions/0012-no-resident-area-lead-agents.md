# 0012. No resident area-lead agents: the goal ledger and triage take that role

Status: **accepted** (2026-11-15, owner: deferred, recorded as a non-goal). Refs #78. This file records the decision only; nothing is built for it.

## The question, in plain words

Some multi-agent setups keep one agent per area (a lead for the screen, one for the skills, one for the records) running all the time. The lead watches its area, splits work, and proposes what to do next. Should paddock have such leads under the secretary?

## What exists today (checked in this repository)

| Fact | Where |
| --- | --- |
| The roles are the secretary (started once and kept), workers (started per task) and a curator (started at a threshold). Only the secretary is resident. | [architecture §3](../design/architecture.md#3-roles) |
| Work discovery is carried as a skill, goal ledger first: the triage orders candidates by the goal ledger's clauses, and the conveyor takes its candidates from it. | [Q15](../design/open-questions.md#q15-which-of-the-predecessors-optional-organization-features-carry-over) |
| The carried triage also proposes a new goal clause when issues that match no clause pile up in one repository (the predecessor's `clause_gap` output). | [Q15](../design/open-questions.md#q15-which-of-the-predecessors-optional-organization-features-carry-over), work-discovery row |
| The goal ledger and the triage are not in this repository yet; the owner runs them through the predecessor today. | [0007](0007-first-run-setup-outside-the-round.md) "What is not measured", Q15 "How the owner uses these today" |

## Decision

No resident area-lead agents. The goal ledger and the clause-ordered triage take the lead's role: they say what matters per repository and which issue comes next, and the secretary delegates from that.

## Why

- **Idle agents cost attention and money.** A resident lead holds a context and a terminal while its area is quiet, and each of its turns is one more thing the person may have to read.
- **The ledger and triage cover most of a lead's job.** Ordering work by goal is the triage; knowing what an area is for is the ledger's clause; splitting and starting work is the secretary with `org-delegate`.

## The one gap, and where it goes

A lead would also **propose new goals** for its area. The ledger does not grow by itself. That gap goes to the triage's clause-addition proposal ([Q15](../design/open-questions.md#q15-which-of-the-predecessors-optional-organization-features-carry-over), work-discovery row): when issues that match no clause pile up in one repository, the triage proposes a new clause, and the owner decides.

## Costs accepted

- No agent keeps an area's context between tasks; each worker starts from its brief and the repository.
- The gap is closed only once the work-discovery skill is carried; until then, new goals come from the owner.

## Revisit when

An area's work cannot be ordered by the ledger's clauses, or the clause-addition proposal misses goals a lead would have seen.
