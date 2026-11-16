# Why org-watch is built this way

- **A script in a kept terminal, not a mod.** A mod only runs while herdr-app is open, and the case is the window closed. The secretary cannot run the incident check, since it is what stopped. A kept terminal is how paddock already runs something resident, so the watcher starts, restarts and ends with the same commands.
- **Shell only.** No Python or Node: it reads `hc ls`, `hc get` and `hc read` and the org-state document, and tells a person.
- **Why the one typed line is safe (decision 0013).** It is a constant per target (no text from a worker or a person), sent only on an exact status (`idle` with `--if idle`, `done` just read), never into a working target and never over typed input on the prompt line, at most once per unread batch per `PADDOCK_WATCH_WAKE` s. A bug here can cost a needless turn, bounded by that limit; it cannot answer, close or approve anything. Every send and skip is in `watcher/woke`.
- **The watcher watches CI itself (decision 0013, open question 2).** The watch runs in its terminal, outside every agent, and always writes one line: a trap for the ordinary ends, the next pass for a SIGKILL. Long `gh` steps run in the background and are waited for, so a signal is handled at once.
- **A poll, not `hc events`.** The incident rule needs "unchanged for N minutes", which an event stream does not say by itself, and a pipeline loses changes while it is down.
- **The watcher's own memory of "unchanged".** A fingerprint of `turn`, `status_ms` and a checksum of the screen, with the time it was first seen, in the ledger folder. Any change resets the clock, which is the rule's reset.
- **One ledger for three kinds of item.** "Told once, again after N minutes" is the same for a card, an incident and a silent terminal, so one file and one `tell` function cover them; an item that stops waiting is forgotten.
- **Toast text goes in the environment, not the command line.** Questions and task titles come from workers; nothing they wrote is quoted into a command.
- **The bell is the floor.** It needs nothing, so a person is never told nothing. It is visible only where the terminal is on screen, hence the toast first.
- **The absolute `powershell.exe` path.** Measured on the host: from a login shell the name resolves; from a kept terminal it did not (its PATH holds no `/mnt/c`), and the default absolute path raised the toast.

## Plugin reload

`org-start --place-only --from-origin` leaves an empty marker `watcher/reload-plugins` in the state folder when the fast-forward changed a `SKILL.md` (a running secretary serves the old skill text until `/reload-plugins`, decision 0014 H4). The watcher decides nothing about it; it only types the one command when the marker says so:

- Marker empty: `/reload-plugins` is typed into the secretary under the same rules as a wake (exact `idle`/`done` status, never over typed input), once; the send time goes into the marker, the send into `watcher/woke` as `reload`. In that pass the secretary gets no wake line.
- Marker holding a time: a `Reloaded:` line below the last `/reload-plugins` on the secretary's screen clears it (`reloaded` in `watcher/woke`). None N minutes after the send: the person is told outside the window, as for a waiting card (again every N minutes), to type `/reload-plugins`; nothing is typed again. A new landing empties the marker, so it is typed once more.
