# Why org-watch is built this way

- **A script in a kept terminal, not a mod.** A mod only runs while herdr-app is open, and the case is the window closed. The secretary cannot run the incident check, since it is what stopped. A kept terminal is how paddock already runs something resident, so the watcher starts, restarts and ends with the same commands.
- **Shell only, read only.** No Python or Node, and nothing typed into a terminal: it reads `hc ls`, `hc get` and `hc read` and the org-state document, and tells a person. A bug here can be noisy, never destructive.
- **A poll, not `hc events`.** The incident rule needs "unchanged for N minutes", which an event stream does not say by itself, and a pipeline loses changes while it is down.
- **The watcher's own memory of "unchanged".** A fingerprint of `turn`, `status_ms` and a checksum of the screen, with the time it was first seen, in the ledger folder. Any change resets the clock, which is the rule's reset.
- **One ledger for three kinds of item.** "Told once, again after N minutes" is the same for a card, an incident and a silent terminal, so one file and one `tell` function cover them; an item that stops waiting is forgotten.
- **Toast text goes in the environment, not the command line.** Questions and task titles come from workers; nothing they wrote is quoted into a command.
- **The bell is the floor.** It needs nothing, so a person is never told nothing. It is visible only where the terminal is on screen, hence the toast first.
- **The absolute `powershell.exe` path.** Measured on the host: from a login shell the name resolves; from a kept terminal it did not (its PATH holds no `/mnt/c`), and the default absolute path raised the toast.
