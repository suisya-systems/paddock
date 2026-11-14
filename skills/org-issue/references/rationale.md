# Why org-issue is built this way

The triage parser reads dependency references only from the same line as the keyword (`Blocked by`, `Depends on`, `Requires`). A reference written under a heading was silently treated as unblocked. Building the body in the script means the dependency line is always a single `Depends on #N #M` line at the end, so the person or the secretary cannot get it wrong by hand. Each dependency is checked against the repository before anything is created, so a typo does not become an issue that blocks on nothing.
