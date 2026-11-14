# Why secretary-handover is built this way

- **The secretary writes the document; a script outside it does the renewal.** A secretary cannot end and relaunch its own terminal and survive, and it must never be typed into. So it writes the handover when its context is getting full and tells the person; this script, run from the person's shell, reads it, ends the old terminal and starts a fresh secretary whose task is "resume from the handover".
- **Never inside an agent.** The new secretary's terminal inherits this script's environment, so an agent's session variables must not be in it (same rule as org-start).
- **An unreadable status is never taken as idle.** Only `idle` or a missing terminal allows the kill; `working`, `blocked`, a failed read or an output without `state` end nothing.
- **Workers are untouched.** They were started to outlive their parent, so the new secretary finds them again by their `task_id` label.
- **Repeatable.** The document is cleared by the new secretary once it has resumed, so a rerun after that ends nothing and a rerun before it relaunches from the same document. The task travels in the launch, not typed afterwards.
- **`--cwd` is the paddock folder** so the new secretary finds its tools whatever folder the script ran from.
