# Why org-pull-request is built this way

- **CI is watched by the watcher, not here (decision 0013).** The script records `ci_requested` and returns; org-watch's `ci-watch.sh` runs outside every agent and always writes one `ci_completed` (a failed run too) or `ci_watch_failed`, so a watch never vanishes without a line and the secretary holds nothing.
- **One open request per head.** A rerun with `--pr` writes `ci_requested` only when the head has none, or its watch failed; a second request for a head already watched or reported would make the watcher report it twice.
- **Acceptance has no local gate.** The check is the repository's CI as a required status check (the `acceptance` job). The script only confirms the PR head still equals the watched sha and the required checks are green, then merges with `--match-head-commit`, never `--admin` or `--auto`, so a push after the watched run cannot be merged unreviewed.
- **The request line goes through the secretary's own writer** (its folder, sequence and lock), so the sequence number never repeats one a reader has acknowledged.
- **A missing second-model review is stated in the PR body.** The script reads the task's last diff-review record; if there is none (or it did not pass) it appends that fact to the body it sends, so a body written without it still says so.
