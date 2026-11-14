# Why org-pull-request is built this way

- **CI is watched as a background child terminal.** `hc run --bg --rm --no-notify -- gh run watch ... --exit-status`, then `hc wait`, gives an integer exit code in one JSON line without blocking the secretary; a kill sets a signal instead and is reported rather than guessed.
- **`ci_completed` is recorded for a failed run too.** The record is the evidence that CI ran on that exact head; a missing line must mean "not run".
- **Acceptance has no local gate.** The check is the repository's CI as a required status check (the `acceptance` job). The script only confirms the PR head still equals the watched sha and the required checks are green, then merges with `--match-head-commit`, never `--admin` or `--auto`, so a push after the watched run cannot be merged unreviewed.
- **The events line goes through the secretary's own writer** (its folder, sequence and lock), so the sequence number never repeats one a reader has acknowledged.
- **A missing second-model review is stated in the PR body.** The script reads the task's last diff-review record; if there is none (or it did not pass) it appends that fact to the body it sends, so a body written without it still says so.
