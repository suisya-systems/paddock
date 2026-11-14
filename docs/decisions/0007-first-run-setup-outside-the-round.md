# 0007. First-run setup: which steps stay outside a round, and how the rest is made mechanical

Status: **accepted** (2026-11-14, owner: Q1 yes, Q2 (c), Q3 `/proc`). Refs #328 (goal clause G1). The implementation (`org-start --check` and the core PATH check) is a separate task; this file records the decision only.

## The question, in plain words

Goal G1 says a round needs no typed command and no hand-written settings file. Runs 7 and 8 passed `10-no-touch`, but the operator's assistant first did four things by hand. Do we (1) make them happen by themselves, (2) say plainly that they happen once per machine, outside any round, or (3) a bit of both?

## The four hand steps, and what the code already does

| # | Hand step | Seen in | What exists today | Can paddock do it itself? |
| --- | --- | --- | --- | --- |
| 1 | Write `notes = false` at the top of the core's `config.toml` | `org-start.sh` exit 8 | org-start checks and stops with one line telling you what to add. `prototype-3.sh prepare` checks it too (`notes-off`). | **No.** The core's config is trusted code that no agent may write (L-N1 in the [inventory](../design/predecessor-inventory.md)). A script run by an agent is an agent writing it. A person can write it. |
| 2 | Start or restart the core from a login shell, so `~/.local/bin` is on its PATH | #305, Run 6 | org-start refuses to run inside an agent (Q17, exit 4). It does **not** check the PATH of a core that is already running. `prototype-3.sh prepare` does (reads `/proc/<core pid>/environ`) and says to restart herdr from a login shell. org-start does record the absolute path of `claude` and `codex` (#268, #298). | **Partly.** It can *detect* a core without `hc` on its PATH (Linux only, through `/proc`). It cannot fix it: restarting the core kills every running terminal, and the new core takes the environment of whoever starts it. |
| 3 | Run `org-start` and `layout.switch` | Runs 7/8 | org-start already runs `layout.switch` itself (#270) and already answers the secretary's own folder-trust dialog (#244). | **Already mechanical.** What remains is that someone has to type `org-start` once per core start. That is the start of the organization, not a setup step. |
| 4 | Trust the project clone once with `claude` | Q13 | `prototype-3-setup.sh` checks whether the clone is recorded as trusted and prints the exact `claude` command. org-delegate never presses keys for a worktree (Q13). | **No, by design.** Trust follows the git repository; the only supported way to record it is the dialog, and writing `~/.claude.json` was rejected in Q13 (option c: undocumented key). One person, one answer, once per clone per machine. |

So only step 3 is mechanical today. Steps 1 and 4 must stay a person's action. Step 2 can be checked but not done. The real gap in G1 is not the typing; it is that **no single paddock command lists all four and prints the fix for each**. Today the checks live in three places (org-start, `prepare`, `prototype-3-setup.sh`) and step 2 is missing from org-start, so a clean host can reach `org-start: ready` with the secretary unable to run `hc` (Run 6).

## Options

### (a) Documented one-time install plus a single check

Keep the four as a one-time, per-machine install that sits **outside a round**. Add one entry (`setup`, modelled on `prototype-3-setup.sh`) that checks all four, changes nothing it must not, and prints the exact fix for each. Update the ledger to say: G1 covers a round; first-run setup is outside it, and every step in it is printed by a paddock command.

- Costs: one new command to keep in step with the checks; a person still does steps 1, 2 and 4 (about three one-off actions per new machine). Two places hold the notes check unless org-start calls the same code.
- Keeps: L-N1 and Q13 as decided. No new write surface.

### (b) org-start owns more

Make org-start do or refuse everything: write `notes = false` itself, restart the core on a bad PATH, record trust for the clone.

- Costs: it breaks decisions already made. Writing `config.toml` breaks L-N1; a script an agent runs is the agent writing trusted code. Restarting the core ends every running terminal, including a live secretary and workers (org-start "never stops or restarts the core" today, by design). Recording trust means writing `~/.claude.json`, rejected in Q13 (undocumented key that may change).
- Only the *detection* part of (b) is safe, and that is already inside (c).

### (c) A mix (chosen)

1. **The check goes into org-start**, which every host already runs. Add the missing step-2 check (core PATH has `hc`; same method as `prepare`, Linux `/proc`, silent skip elsewhere) next to the existing notes check. Each failure prints the exact fix and exits non-zero before anything is placed. org-start stays the one command a person types.
2. **`org-start --check`** runs only the checks (read-only, no placement, no secretary) and also checks trust of the project clones it is given (`--project DIR`, reusing `trusted()` from `prototype-3-setup.sh`). Output is `ok` or `TODO <step>: <exact command>` per step; exit 0 only when nothing is left for a person. This is the single `setup` entry of (a), without a second script.
3. **Steps 1, 2 and 4 stay with a person**, as decided. The ledger says so: G1 covers a round; a host's one-time setup is three person-actions, each named by a paddock command, and "clean host reaches `org-start: ready`" means *after* those, with `--check` clean.
4. `prototype-3-setup.sh` and `prepare` call the same check instead of carrying their own copies.

- Costs: org-start grows a flag and one more exit code (a bad core PATH); the check code is shared, so a change to it touches three callers. The `/proc` read works on Linux and WSL only.
- Does **not** make steps 1, 2, 4 mechanical. It makes them *impossible to miss and impossible to guess*, which is what the Issue's definition of done asks for ("no step that is not printed by a paddock command").

## Decision

The owner chose (c), with these answers:

1. **G1 wording.** First-run setup is a person's one-time job per machine, outside the round. G1 covers a round only. The goal ledger says so (the secretary edits it, not this file).
2. **Where the check lives.** `org-start --check`, added to org-start. No separate `setup` command.
3. **Core PATH.** Checked by reading the running core's own environment from `/proc/<core pid>/environ` (Linux and WSL only; silent skip elsewhere), not by looking at the PATH of the shell that runs org-start. That is the case that failed in Run 6.

What this means in practice:

- Steps 1, 2 and 4 stay with a person. Step 3 is already mechanical.
- org-start gains the step-2 check next to its notes check, and `org-start --check` runs only the checks (read-only, no placement, no secretary). It also checks the trust of project clones given with `--project DIR`, reusing `trusted()` from `prototype-3-setup.sh`. Output is `ok` or `TODO <step>: <exact command>` per step; exit 0 only when nothing is left for a person.
- `prototype-3-setup.sh` and `prepare` call the same check instead of carrying copies.
- "A clean host reaches `org-start: ready`" means after the person's three actions, with `--check` clean.

## Why

(c) is the only option that respects L-N1, Q13 and "org-start never restarts the core", and it closes the one real hole: step 2 was silent. (a) would add a second place that must agree with org-start. (b) breaks three earlier decisions. `/proc` was chosen over the shell's PATH because the core's environment, not the caller's, is what its terminals inherit.

## Costs accepted

- org-start grows a flag and one more exit code (bad core PATH). The check code is shared by three callers.
- The `/proc` read works on Linux and WSL only.
- Steps 1, 2 and 4 are not made mechanical; they are made impossible to miss and impossible to guess.

## What is not checked here

- The goal ledger is not in this repository; G1's wording is taken from the Issue text.
- The core's PATH check was measured in `prepare` (Run 6/7), not run again for this document.
- Whether the core re-reads `config.toml` without a restart is still unmeasured (org-start's exit 8 message says so).
