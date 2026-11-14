# Why org-suspend is built this way

- **A record, not a stop.** Terminals keep running with no window open, so suspending only writes down what a resume needs: the work entries, the labelled terminals, and each worktree's git state. It sends nothing into any agent (no `SUSPEND:` message, no `hc send`; the mailbox is the only channel) and never stops the core.
- **A local file, not a core document.** The set of allowed document names is fixed by the records contract; adding one is a design change this skill does not make.
- **Never inside an agent.** The core and its terminals must carry the person's environment, not an agent's sandbox environment.
- **The work entries are cut out by a scan that skips string contents,** so braces, brackets and commas inside a task or title survive. Fields are read assuming flat entries; an entry that cannot be read fails the suspend rather than being dropped, because a silently dropped worker cannot be resumed.
