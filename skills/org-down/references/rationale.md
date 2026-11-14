# Why org-down is built this way

- **The core stays unless asked.** `hc server stop` ends the person's whole core and every terminal on it, not only the ones paddock started, so the default cleans up only what paddock started and stopping the core is an explicit flag.
- **It never runs inside an agent.** Shutting the organization down ends the secretary's own terminal when asked, so it is run from the person's login shell.
- **Suspend first.** If recording the state fails, nothing is ended, so the next start can resume.
- **A worker whose report is still unsent is ended anyway.** Running this script is the person saying so; the secretary's own rule covers the secretary's `hc kill`.
- **The leftover `config.lock`.** Killing a worker mid-command leaves an empty read-only placeholder in the clone's shared `.git`. It is removed after every worker is ended, under the same safety conditions as in org-close (nothing using it; otherwise it stays and the output says why).
