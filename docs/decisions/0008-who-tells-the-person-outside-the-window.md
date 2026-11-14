# 0008. Who tells the person when something waits and the window is closed, and by what channel

Status: **draft** (2026-11-14), waiting for the owner. Refs #335 (goal clause G7). This file records options and a recommendation only; nothing is built. If accepted, the build is a separate task.

## The question, in plain words

Today a person learns that an approval is waiting only from the card in herdr-app (G4). With the window closed, or the secretary not moving, nothing tells anyone. [Q3](../design/open-questions.md#q3-incident-threshold-when-the-secretary-does-not-move) already decided the **rule** (a worker is `blocked` and the secretary's status, `turn` count and screen have not changed for N = 10 minutes; a terminal that never reported status after N minutes or whose `hc run` returned `first_message.sent = false`). What is open is **who runs the rule** and **what channel it uses**.

## What exists today (checked in this repository)

| Fact | Where |
| --- | --- |
| A mod can raise a toast and play a sound (`notify({ title, body, level, icon, timeout })`, `playSound`), but only while herdr-app is open. Nothing in herdr-core notifies a person; its notes go to parent agents only, and paddock turns them off (`notes = false`). | NTF-1, NTF-3 in the [inventory](../design/predecessor-inventory.md); Q8 |
| The secretary cannot run the check: it is the one not moving. | Q3 |
| The data the rule needs is readable by any script: `hc get` / `hc ls` (status, `status_ms`, `turn`), `hc read --lines 0` (screen), `hc events --json` (live, no replay, `seq` restarts with the core), and `org-state.approvals` through `scripts/org doc get org-state` (each entry has `id`, `task_id`, `question`, `asked_at`). | Q3, Q8, [org-escalation](../../skills/org-escalation/SKILL.md) |
| A kept terminal is how paddock already runs something resident: `org-start` starts the secretary with `hc run --bg --keep --name`, and `org-pull-request` starts the CI watcher as a child terminal. The events-bridge decision already says a kept-terminal watcher would share its start, restart and stop work. | [org-start.sh](../../skills/org-start/scripts/org-start.sh) line 190; Q8 "Revisit when" |
| The ground rules say shell only, no Python or Node. | README Assumptions |

## Who runs it

### (a) A shell script in a kept terminal (`hc run --bg --keep --name watcher`)

A loop in sh (no new language) that, on each pass, reads the state above, applies Q3's rule, and calls a channel command. `org-start` starts it next to the secretary.

- **Covers:** window closed, window open on another desktop, secretary frozen.
- **Costs:** one more resident terminal; one script plus its test against a stubbed `hc` (the existing tests do this); a small "already told" record so a person is not told every pass (the NTF-1 ledger, in a file under `~/.local/state/paddock`); `org-start`, `org-suspend` and `org-down` must know about it. The 10-minute rule needs its own memory of "unchanged since" between passes (a file or shell variables).
- **Needs from herdr:** nothing new. `hc get`, `hc read`, `hc events` and `hc run --keep` exist.
- **Gap:** it lives in the core. If the core stops, the watcher stops with it and nothing says so (`hc server stop` parks kept terminals as plain shells; the script is not restarted). That case is the person stopping their own core, or a crash, and is not covered by any option that stays inside herdr.

### (b) A herdr-app mod

`notify` and `playSound` are native and cost almost nothing to write; the cockpit mod already reads `org-state` and the terminals.

- **Covers:** only a window that is open. The Issue is the window being closed, so (b) alone does not answer it.
- **Costs:** a mod copy per window, and the 10-minute rule's memory in `localStorage` or `shared()`.
- **Needs from herdr:** nothing new.
- **Use:** a good *addition* for the open-window case (a sound while you work in another app), not the answer.

### (c) Others found in the code

1. **The secretary notifies when it escalates** (calls the channel command inside `org-escalation ask`). Cheap, no resident process, covers "an approval is waiting" with the window closed. It cannot cover "the secretary has stopped", because the secretary is what stopped. So it is half the answer and the two halves would have two owners.
2. **A timer outside herdr** (systemd user timer, cron, Windows Task Scheduler) running the same script. It would also notice a dead core. It is the only option that does, but it adds an install step per machine outside "nothing to install beyond herdr and those tools", and is outside the brief's "herdr-provided tools". Kept as the later answer if the dead-core case ever matters.
3. **`hc events` as the trigger** (a pipeline in the kept terminal instead of a poll). Same terminal as (a); it reacts faster but loses changes while the pipeline is down, and Q3's rule needs "unchanged for 10 minutes", which an event stream does not say by itself. A poll of `hc get` is simpler and enough.

## Channel

All are one shell command the watcher calls. Which one runs is chosen by what the host has, at the time of the call.

| Channel | Where | Cost | Needs |
| --- | --- | --- | --- |
| Windows toast, with sound, from `powershell.exe` | WSL (the host this project runs on) | About a second per call; a visible message with the task and the reason. | WSL's Windows interop switched on (on by default). |
| `notify-send` | Linux desktop | One command. | `libnotify` and a running notification daemon; not on this machine. |
| Terminal bell (`printf '\a'` to the watcher's terminal) | Anywhere herdr-app shows that terminal | Nothing; but visible only if that terminal is on screen. | Nothing. |
| `osascript` toast | macOS | One command. | macOS; paddock is Linux and WSL for now (Q7). |
| Sound only (`paplay`, or Windows `SystemSounds`) | Both | Cheap, but says only "something", not what. | A sound player; `paplay` is not on this machine. |

Floor: the bell, which needs nothing. On WSL: a toast through `powershell.exe`, which reaches the Windows desktop with the window closed. On Linux: `notify-send` when present.

## Recommendation

**(a), with the toast on WSL and `notify-send` on Linux, falling back to the bell.** Reasons:

1. It is the only inside-herdr option that covers both halves of the Issue (a waiting approval and a stopped secretary) with the window closed, and it has one owner.
2. It uses what Q3 already decided (rule, N = 10, never-reported rule) and nothing the README rules out.
3. The mod (b) stays as it is; adding a sound there later is a small change and is not needed to close the Issue.

What the watcher tells a person (all from one cooldown ledger, each at most once per item, then again after N minutes if still waiting):

- an approval card waiting (`org-state.approvals`), with the task and question;
- Q3's incident (a worker `blocked` and the secretary frozen for N minutes);
- a terminal that never reported status (the `first_message.sent = false` case, and the N-minute timeout).

## What is not measured

- Nothing here was run: this work was done in a sandbox with no running core, no `herdr-app`, and no working Windows interop, so no toast was raised and no `hc` call made. The `hc` facts are taken from the documents cited.
- Whether `powershell.exe` can raise a toast from a WSL process started by a kept terminal (no desktop session of its own) is **unmeasured**. It is the first thing the build task must probe, before choosing the toast; if it fails the WSL channel falls back to the bell and a sound.
- How long a healthy secretary keeps one status (N = 10 is a starting value, Q3).
- Whether a poll every 30 seconds is cheap enough on a core with many terminals. `hc get` per blocked worker plus one for the secretary should be, but this is not measured.

## Questions for the owner

Each has a recommended answer (marked).

1. **Who runs it?**
   - **(a) A script in a kept terminal, started by `org-start` (recommended).**
   - (b) A herdr-app mod only (does not work with the window closed).
   - (c) Both: (a) plus a sound in the mod while the window is open.
2. **What does a person see and hear?**
   - **A desktop toast with the system's sound on WSL and Linux, and a terminal bell as the fallback (recommended).**
   - Sound only, no text.
   - Text in the terminal only.
3. **Is a waiting approval card a reason to notify, or only the secretary's incident?**
   - **Both: tell the person once per approval card that waits, and on the incident (recommended). A card is an escalation, so it follows principle 6 ("people are interrupted by escalation").**
   - Only the incident.
4. **Should `org-start` start the watcher by itself?**
   - **Yes, as a kept terminal named `watcher`, and `org-down` ends it (recommended).**
   - No, a person starts it when they want it.
