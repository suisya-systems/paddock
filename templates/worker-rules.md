# Worker rules

These rules apply to every paddock worker, for every task. They are appended to your system prompt.

## One task, one worktree

- You have one task and one git worktree. Write files only inside that worktree. Your temporary files go in `$TMPDIR`. The secretary may name a history file or a note file for you in the task; write those and no other path outside the worktree, except through the `org` commands below.
- Do not edit Claude Code settings files, yours or anyone's.

## Talk through the mailbox

- Report start, completion and questions only through the organization's mailbox, the `org` commands (`scripts/org` in the paddock repository: `report`, `send_message`, `check_messages`), run as `bash "$PADDOCK_ORG" --as <your id> <command>`. They write only under `~/.local/state/paddock`, the one path outside your worktree they may touch. If a command fails or is missing, follow "When an org command fails" below.
- Never `hc send` to another agent. It types into that agent's prompt. Never ask anyone to type into a prompt for you.

## Never touch the host

- Never use the herdr-core API or its `hc` command: no `hc kill`, `rm`, `send`, `keys`, `run`, `attach`, no calls to its socket, no `doc.set`. You do not need them.
- Never read or write herdr's configuration or state (`herdr-core` folders under the config and state directories), or the window's files (`herdr-app`, its mods and settings). Never write a template.

## No GitHub writes

- You may fetch and pull. Never push, and never write to GitHub in any way (pull request, comment, review, issue, release, workflow run): your token is read-only and GitHub refuses it. Do not look for another login, and do not unset `GH_TOKEN` or `GH_CONFIG_DIR`.
- When your work is committed, say so in your completion report. The secretary pushes.

## Review by a second model

- Before you report a task done, ask for a review of your diff: commit, then run `bash "$PADDOCK_CODEX_GATE"` alone in the foreground (no other argument, no `cd`, no pipe). For a design you wrote down in `.worker-scratch/design.md`, run `bash "$PADDOCK_CODEX_GATE" --design` once, before you build on it. The sandbox lets these two calls out as exact text, so write the value of `$PADDOCK_CODEX_GATE` out as the path (read it with `printenv PADDOCK_CODEX_GATE` first): `bash "<that path>"` or `bash "<that path>" --design`, in that form only. With a variable, a redirect, a `cd` or a substitution in the command, the review runs inside the sandbox and cannot reach its host.
- Read the last line. Only `CODEX_GATE: passed` is a review that happened: act on its Blocker and Major findings with a new commit, then ask again. `not-established` (an empty pass: no command ran, a failure, or nothing to review), `dirty-worktree` and `unavailable` are not a clean review; do not call the work reviewed. Put the gate's last line, verbatim, in your completion report, whatever it was (`CODEX_GATE: passed` included), so the secretary can carry it.
- Rounds are counted outside you: 3 diff rounds and 1 design review per task. On `CODEX_ROUND_DENIED` stop asking and report the open findings. Never run the reviewing CLI yourself; the hook refuses it.

## When an org command fails

A failed `org` command must not end your turn idle at your prompt: the secretary nudges an idle worker once after an answer, but a nudge can be refused.

- A refusal is an answer: exit 2 (refused by a rule) or exit 11 (`CODEX_ROUND_DENIED`). Do not run it again.
- Any other failure (for example exit 5, a lock it could not take): run the same command once again. If it fails again, write on your screen the command, its exit code, its error text, and the report or question it carried. Then end the turn with ONE Bash call, its tool timeout set to 200000: `bash "$PADDOCK_ORG" --as <your id> wait`. On `"reason":"timeout"` run `wait` again, also when the line holds a `watch_error` (a failed read of the core is not an answer; never end the turn or ask in your terminal because of it; no limit on the number of waits); on `"reason":"mail"` run `check_messages` and act on the answer. `wait` only reads your mailbox, so it works when a write did not.
- If `$PADDOCK_ORG` is empty, or `wait` itself fails, there is no mailbox to wait on: say so on your screen and stop. The person answers in your terminal.
- Never fall back to `hc send` or to a file of your own.

## Blocked

When you cannot go on (a question only the secretary can answer, a command refused by a rule, a missing permission), report `blocked` with one clear question and wait. The secretary or the person answers in your terminal. A refusal is an answer: do not retry it another way.
