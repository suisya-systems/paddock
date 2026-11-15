# 0014. How role rules, skills and tools reach an agent: worker rules in the system prompt, skills as a plugin, procedures in scripts

Status: **accepted** (2026-11-15, owner: all seven questions answered yes, see [Questions for the owner](#questions-for-the-owner)). Decided: worker rules stay in the system prompt with the precedence section (A); paddock's skills load as a plugin with `--plugin-dir` (P), falling back to `.claude/skills` symlinks if probe H4 fails; the secretary's standing rules go to `AGENTS.md` + `CLAUDE.md` (`@AGENTS.md`) in its own working folder `<state>/secretary/` (F), **on the condition of probe H3**, and to the system prompt (R) if H3 shows they are not re-injected after an automatic compaction; the caps, workers without the plugin, and the `next:` line. Refs #375, #418, #419. This file records the decision only; the build is the follow-up tasks of waves 0 to 3 under [Build, in parallel units](#build-in-parallel-units). Behaviour of Claude Code that no page states is marked **not stated** and has a probe in [Host probes](#host-probes); none of it is assumed.

## The question, in plain words

Three issues ask one question from three sides: where does each piece of what an agent must know live, so that it reaches the agent, survives a long session, and can change without a restart?

- **#375, the worker's role rules.** They reach the worker as `--append-system-prompt-file` today. Keep that, or move them into a folder outside the repository that Claude Code reads as a `CLAUDE.md` (`--add-dir`), or for Codex a per-worker `CODEX_HOME`? And when the rules and the repository's own `AGENTS.md`/`CLAUDE.md` disagree, which wins?
- **#418, the secretary template.** `templates/secretary.md` is 23,834 bytes in 95 lines. Much of it is procedure (exit codes, flag lists, multi-step sequences). Which lines stay in the template, which go to a skill, which to a script?
- **#419, paddock's skills.** They live in `skills/<name>/SKILL.md`, which Claude Code does not discover, so the secretary cannot load one by situation and the template carries every script path. Where should Claude Code find them, and in what form?

The three meet in one rule, the [sorting rule](#3-the-sorting-rule-template-rules-file-skill-script-418) below: a line that must hold in every turn goes to a standing rules file that survives compaction; a procedure for a situation goes to a skill; a fixed sequence goes to a script. Where each of those is loaded from is decided in parts 1 and 2.

## What exists today (checked in this repository)

| Fact | Where |
| --- | --- |
| The worker's rules are `worker-rules.md` in the bin folder, passed with `--append-system-prompt-file "$bd/worker-rules.md"` in the worker template's `command`. The template body says "Read its `AGENTS.md` and `CLAUDE.md` if it has them, and follow them" and says nothing about a conflict between the two. | [templates/worker.md](../../templates/worker.md) lines 3, 9; [templates/worker-rules.md](../../templates/worker-rules.md) line 3 |
| That split was decided under Q12: the rules file "never touches the target repository's git"; `AGENTS.md` in the worktree and `CLAUDE.local.md` were rejected. The basis was one weak measurement that a rule given only in the template body survived `/compact`. | [open-questions.md Q12](../design/open-questions.md#q12-where-do-a-workers-role-rules-and-task-brief-live) |
| The secretary's command passes `--settings` only. Its whole role text is the template body, which herdr-core sends as the **first message** with the task after a blank line. | [templates/secretary.md](../../templates/secretary.md) line 3; [architecture §8](../design/architecture.md#8-facts-this-design-relies-on) ("the body is the opening instructions, and core appends the task") |
| The secretary runs with `--cwd <paddock checkout>`, so `bash skills/<name>/scripts/...` resolves there; `org-start --place-only` fast-forwards that checkout after a landing and prints a renewal line when `secretary.md` changed. | secretary.md line 13; [org-start.sh](../../skills/org-start/scripts/org-start.sh) lines 18-24, 355 |
| The template's long lines are procedure: L18 (902 chars, org-delegate's flags), L19 (665, its exit codes), L21 (1,825, the org-clone sequence and its exits), L83 (1,142, placing files after a landing), L94 (1,251) and L95 (1,492, org-escalation's subcommands and exits). | `awk '{print NR, length}' templates/secretary.md` at 79d7085 |
| 21 tests read `templates/secretary.md` (for example `secretary-cwd`, `secretary-ci-watch`, `org-escalation-context`, `worker-prompt-relay`), so a moved line moves a test with it. | `grep -l secretary.md tests/*.sh` |
| Skills are `skills/<name>/SKILL.md` with front matter `name` and `description` only, plus `scripts/` and `references/rationale.md`. The largest bodies: org-start 16,001 bytes, org-delegate 15,749, org-escalation 12,848, org-watch 9,370. `tests/skill-selfcontained.test.sh` forbids Issue numbers and links out of a skill's folder. | `skills/*/SKILL.md`; [decision 0009](0009-growth-through-skills-smallest-form.md) Part 5 |
| paddock has no `.claude/` folder, no `AGENTS.md` and no `CLAUDE.md` in git (principle 8 names `AGENTS.md` as the shared file; none is written yet). | `git ls-files` |
| **Measured:** in a worker, the sandbox makes `.claude/skills/**`, `.claude/hooks/**`, `.claude/settings.json` and `.claude/settings.local.json` read-only; an incoming change to one of them stops a rebase or a merge. | [org-update-branch rationale](../../skills/org-update-branch/references/rationale.md) line 4; `scripts/probes/rebase-protected-path.sh` |
| Principle 9: a routine procedure goes through a tool, not a sentence; judgment stays in the text. | [architecture §2](../design/architecture.md#2-design-principles) |
| No Codex worker exists. Codex appears only as the second-model reviewer behind `PADDOCK_CODEX_GATE`. | templates/worker.md line 3, worker-rules.md "Review by a second model" |

## What Claude Code's documentation says (read 2026-11-15)

Each row quotes the page and the section. Where a page is silent, the row says so.

| # | Statement | Source (page, section) |
| --- | --- | --- |
| D1 | Skills are found in `~/.claude/skills/`, the project's `.claude/skills/` (and parents up to the repository root, and nested `<subdir>/.claude/skills/`), `.claude/skills/` of a directory passed with `--add-dir`, and a plugin's `<plugin>/skills/<name>/SKILL.md`, invoked as `/plugin-name:skill-name`. | [skills.md](https://code.claude.com/docs/en/skills.md), "Choose where skills load" |
| D2 | "When you add a directory with `--add-dir` or `/add-dir`, Claude Code loads the skills in that directory's `.claude/skills/`" and "watches `.claude/skills/` in a directory you pass with `--add-dir` at launch." "`permissions.additionalDirectories` ... grants file access only and loads none of these." | skills.md, "Load skills from a directory outside the project" |
| D3 | An edited skill in `~/.claude/skills/`, a project's `.claude/skills/` or an `--add-dir` `.claude/skills/` is picked up "within the current session, without a restart", except in bare mode; a top-level skills directory that did not exist at session start needs `/reload-skills`. For a skill folder that is also a plugin, `.mcp.json`, `agents/` and `output-styles/` changes need `/reload-plugins`. Whether an edited `SKILL.md` **inside a plugin loaded with `--plugin-dir`** is picked up live is **not stated** (probe H4). | skills.md, "Edit a skill during a session" |
| D4 | Descriptions are in context up front; "full skill content only loads when invoked". The listing truncates `description` + `when_to_use` at 1,536 characters per skill; the whole listing scales with 1% of the context window. | skills.md, "Control who invokes a skill", "Frontmatter reference", "Skill descriptions are cut short" (troubleshooting) |
| D5 | An invoked skill's text "enters the conversation as a single message and stays there across later turns." After the conversation is summarized, Claude Code "re-attaches the most recent invocation of each skill after the summary, keeping the first 5,000 tokens of each", 25,000 tokens in all. | skills.md, "Skill content lifecycle" |
| D6 | Front matter fields include `name`, `description`, `when_to_use`, `argument-hint`, `arguments`, `disable-model-invocation`, `user-invocable`, `allowed-tools` (usable without prompting during the invoking turn), `disallowed-tools`, `model`, `effort`, `context: fork`, `agent`, `background`, `hooks` ("registered on invocation and kept for the session"), `paths`, `shell`, `metadata` (ignored by Claude Code), `license`, `compatibility`. Unknown fields are ignored without error. | skills.md, "Frontmatter reference" |
| D7 | A personal or project `<skill-name>` entry may be a symlink to a folder elsewhere. Same names: enterprise over personal over project; plugin skills never clash (namespaced); an added directory's skill that clashes runs under a prefixed name. | skills.md, "Choose where skills load", "Resolve skills that share a name" |
| D8 | With `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` set, an added directory's `CLAUDE.md`, `.claude/CLAUDE.md`, `CLAUDE.local.md` and `.claude/rules/*.md` (except rules with `paths`) load; an added directory's `AGENTS.md` does not. | [memory.md](https://code.claude.com/docs/en/memory.md), "Load from additional directories", "Where AGENTS.md differs from CLAUDE.md" |
| D9 | "All discovered files are concatenated into context rather than overriding each other." "If two files give different guidance for the same behavior, Claude may pick one arbitrarily." | memory.md, "How CLAUDE.md files load", "Claude isn't following my CLAUDE.md" |
| D10 | CLAUDE.md "is delivered as a user message after the system prompt, not as part of the system prompt itself"; "For instructions you want at the system prompt level, use `--append-system-prompt`." | memory.md, "Claude isn't following my CLAUDE.md" |
| D11 | "Project-root CLAUDE.md survives compaction: after `/compact`, Claude re-reads it from disk and re-injects it." Whether an **added directory's** CLAUDE.md, an `AGENTS.md` loaded in place of CLAUDE.md, or a file a CLAUDE.md imports is re-injected is **not stated**; whether a CLAUDE.md edited mid-session is picked up before the next compaction or restart is **not stated**. | memory.md, "Instructions seem lost after `/compact`" |
| D12 | `--append-system-prompt-file`: "Load additional system prompt text from a file and append to the default prompt." The system prompt flags work in interactive and non-interactive modes. | [cli-reference.md](https://code.claude.com/docs/en/cli-reference.md), "CLI flags", "System prompt flags" |
| D17 | After compaction: "System prompt and output style: Both still apply"; "Project-root CLAUDE.md and unscoped rules: Re-injected from disk"; "Skill descriptions: Rebuilt from your current skills and re-injected"; invoked skill bodies re-injected within the caps of D5; nested CLAUDE.md and `paths:` rules are summarized away and reload on demand. The automatic pass "works the same way as the `/compact` step". That the system-prompt row covers text added with `--append-system-prompt-file` is implied, not named. The first user message is not named: it is part of the history that is summarized. | [context-window.md](https://code.claude.com/docs/en/context-window.md), "What survives compaction", "When your context fills up" |
| D18 | "CLAUDE.md files can import additional files using `@path/to/import` syntax." The documented way to keep `AGENTS.md` as the shared file is "an `@AGENTS.md` import in a `CLAUDE.md` next to it." CLAUDE.md and `AGENTS.md` are read from the working directory "and every directory above it"; no git repository is required by the text. | memory.md, "Import additional files", "Share one file with other coding tools", "How CLAUDE.md files load", "When Claude Code reads AGENTS.md" |
| D19 | "Claude Code shows the workspace trust dialog when you start it in a folder you haven't trusted"; trust is saved per directory, except in the home directory itself. | [security.md](https://code.claude.com/docs/en/security.md), "Additional safeguards" ("Trust verification") |
| D13 | `--add-dir`: "Add additional working directories for Claude to read and edit files. Grants file access." `--plugin-dir`: "Load a plugin from a directory ... for this session only." | cli-reference.md, "CLI flags" |
| D14 | A plugin's layout is `skills/<name>/SKILL.md`, `agents/`, `hooks/hooks.json`, `.mcp.json`, and an optional `.claude-plugin/plugin.json`. "A `CLAUDE.md` at the plugin root isn't loaded as context ... To include instructions that load into Claude's context, put them in a skill." | [plugins-reference.md](https://code.claude.com/docs/en/plugins-reference.md), "Standard layout" |
| D15 | Settings files are watched and "most edits" apply to the running session. Whether a file passed with `--settings` is watched is **not stated**. | [settings.md](https://code.claude.com/docs/en/settings.md), "When edits take effect" |
| D16 | The pages disagree on two points: cli-reference says Claude Code "doesn't discover most `.claude/` configuration" from an added directory, while skills.md says its skills, commands and agents load; and on bare mode with `--add-dir` skills. paddock does not run in bare mode, so only the first matters, and it is one more reason not to depend on `--add-dir` (part 2). | cli-reference.md `--add-dir` and `--bare` rows; skills.md, "Load skills from a directory outside the project" |

For Codex (part 1's option C and part 3's portability axis): Codex reads a global `AGENTS.md` (or `AGENTS.override.md`) from `CODEX_HOME` first, then the repository's files from the root down ([developers.openai.com, AGENTS.md guide](https://developers.openai.com/codex/guides/agents-md), as cited in #375; **not re-read for this record**: the page could not be fetched from this task). How Codex treats a working folder that is not inside a git repository is **not verified**.

## 1. How a worker's role rules reach it (#375)

### Options

- **(A) Keep `--append-system-prompt-file` (today).** The rules sit in the system prompt, the slot the docs name for instructions meant at that level (D10). Nothing is written into the worktree; the file stays where `tests/worker-rules-place.test.sh` checks it.
  - Cost: Claude Code only. The person cannot see the rules from the worktree. A change reaches a worker only at its next launch (each worker is launched per task, so this is short). The system prompt still applies after a compaction (D17).
- **(B) `--add-dir <rules folder>` with `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`.** The rules are a `CLAUDE.md` in a per-worker folder outside the repository (D8).
  - Cost: the rules become one more user message concatenated with the repository's files, and on a conflict "Claude may pick one arbitrarily" (D9): the repository could win over a safety line. `--add-dir` "grants file access" to read and **edit** (D13), so the sandbox and the file-tool hook must be shown to keep the folder read-only (#375's second measurement), or a worker could edit its own rules. Whether an added folder's CLAUDE.md is re-injected after compaction is not stated (D11, D17). Two docs pages disagree on what else loads from it (D16). It also loads that folder's skills and agents (D2), which paddock does not need for workers.
- **(C) For Codex, a per-worker `CODEX_HOME` holding `AGENTS.md`.** The only per-launch path Codex has; Codex reads it before the repository's files.
  - Cost: nothing today, because no Codex worker exists. Building it now is a path with no user.

### Recommendation: (A) for Claude Code workers; (C) is the path when a Codex worker is built, and is not built now

(B) gains visibility (a file the person can open) and costs a weaker slot and a write surface to measure. The rules exist to hold lines the repository must not override (write only the worktree, no push, no GitHub, no `hc`, mailbox only, the review gate), so the system prompt is the slot that fits. Visibility is answered more cheaply: the rules file's path is fixed (`<bin>/worker-rules.md`, a copy of `templates/worker-rules.md`), and the person reads it there.

### What wins when the repository disagrees

Add one section to `templates/worker-rules.md`, in these words or close to them:

> **When the repository's instructions disagree with these rules.** These rules decide *where* you may act and *how you report*: the files you may write, git and GitHub, `hc`, the mailbox, the review. The repository's `AGENTS.md`/`CLAUDE.md` decide *how the work is done*: code style, commands, tests, commit form. If a repository instruction would take you past one of these rules (push, write outside the worktree, open a PR, talk to another agent), follow these rules and say in your report which instruction you did not follow. If following these rules makes the task impossible, report `blocked` with the one question.

The template body's line 9 ("Read its `AGENTS.md` and `CLAUDE.md` ... and follow them") gains "within your rules". Whether a worker actually follows this when the two conflict is probe H1.

## 2. Where paddock's skills are discovered (#419)

### Options

- **(P) The paddock checkout is a plugin, loaded with `--plugin-dir`.** Add `.claude-plugin/plugin.json` (`"name": "paddock"`) at the repository root; the secretary's command passes `--plugin-dir <paddock checkout>`. The existing `skills/<name>/SKILL.md` folders are already the plugin layout (D14), so no file moves.
  - Cost: skills are namespaced, `paddock:org-delegate` (D7), which also means they never collide with a personal skill of the same name. A top-level `agents/`, `hooks/` or `.mcp.json` added to paddock later would become part of the plugin; that is a constraint on the repository's layout. Live reload of an edited plugin `SKILL.md` is not stated (D3); hook, agent and `.mcp.json` changes need `/reload-plugins` (D3), which nothing types into the secretary, so those wait for a renewal. Nothing about a trust prompt for `--plugin-dir` is stated; probe H4 covers it.
- **(S) `.claude/skills/<name>` in the paddock checkout, as folders or symlinks to `skills/<name>`.** Project skills, found because the secretary's working folder is the checkout (D1); live reload is documented (D3); symlinks are documented (D7).
  - Cost: **measured**, a worker's sandbox makes `.claude/skills/**` read-only, and an incoming change there stops a rebase or a merge (org-update-branch rationale). Real folders there could not be edited by paddock's own workers at all. Symlinks keep the content editable (the target is `skills/`), but adding or renaming a skill is a write under `.claude/skills/`, so every new skill (decision 0009's growth loop ends in exactly that) becomes a hand step outside a worker, and every rebase over it stops in `org-update-branch` with exit 4.
- **(D) `--add-dir` of a folder that holds `.claude/skills/`.** Documented and watched (D2, D3).
  - Cost: the secretary's working folder is already the checkout, so an added folder would be a second folder to place and keep in step; the `.claude/skills/` write problem of (S) stays wherever that folder is a git checkout; the docs disagree on what else loads from an added folder (D16); `--add-dir` grants edit access to it (D13).

### Recommendation: (P), gated on probe H4

(P) moves nothing, adds one small file, and avoids the measured `.claude/skills` problem. If H4 shows an edited plugin `SKILL.md` is **not** picked up in a running session, the fallback is (S) with symlinks, accepting the hand step per new skill, because #419's "a changed SKILL.md takes effect without a renewal" is a done-when of that issue. If H4 shows `--plugin-dir` raises a dialog at launch, the template launch cannot answer it (nothing types into the secretary), and (S) is the fallback as well.

Workers do **not** get the plugin. Every paddock skill today is the secretary's or the person's; a worker that sees `org-delegate` can only misuse it. How a worker learns of work skills stays open, as decision 0009 left it.

### The SKILL.md form

Every `skills/<name>/SKILL.md`:

- Front matter: `name` (equal to the folder name), `description` (what it does, one or two sentences), `when_to_use` (the situations, in the secretary's words: "a worker reports done", "a request names a repository not in projects.md"). Together under 1,536 characters (D4). Other fields only where they apply:
  - `disable-model-invocation: true` for skills the secretary never runs itself (run by the person from a shell: `org-start`, `org-down`; the person's half of `secretary-handover`). It keeps their text out of the secretary's choices.
  - `allowed-tools` for the skill's own script calls, where the secretary's settings would otherwise prompt.
  - `hooks` is **not** used for a guard: a skill's hooks register only once the skill is invoked (D6), so a line that must hold before first use stays in the secretary settings' hooks.
  - `context: fork` is not used for now: a forked subagent cannot talk to the person and returns only its result, while every paddock skill today either asks the person or acts on what it reads.
  - `metadata` only when a paddock script reads it (none does today).
- Body: when to use, the steps with the judgment in them, what to check afterwards (the 0009 skill template). Exit-code tables, flag lists and measurements go to the script's `--help` and `next:` output (part 3) or to `references/`.
- Size: the body under 12 KB, so that the 5,000-token re-attachment after a compaction (D5) holds all of it with room to spare.
- `templates/skill/SKILL.md` gains `when_to_use`. `tests/skill-selfcontained.test.sh` stays; a new `tests/skill-frontmatter.test.sh` checks `name` = folder, `description` and `when_to_use` present, the 1,536-character sum and the body cap.

## 3. The sorting rule: template, rules file, skill, script (#418)

### Where the secretary's standing rules live

The secretary's template body is a first message (see the table above), and a compaction summarizes the conversation history it is part of (D17). So the lines that must hold in every turn leave the body for a file that survives compaction. Two places do, by the docs; the template body shrinks to the opening task either way: who the secretary is, where the conversation language line comes from, "your procedures are the `paddock:` skills; when a situation below arises, use that skill", and a list of situations → skill names. No script paths, no flags, no exit codes.

- **(R) A rules file in the system prompt.** `templates/secretary-rules.md`, placed in the bin folder like `worker-rules.md`, passed with `--append-system-prompt-file` in the secretary template's `command`. The secretary's working folder stays the paddock checkout.
- **(F) The instruction file of a folder of the secretary's own.** The secretary's working folder becomes `<state>/secretary/` (default `~/.local/state/paddock/secretary`), outside every git checkout. `org-start` places there `AGENTS.md` (the rules, from `templates/secretary-rules.md`) and a `CLAUDE.md` whose only line is `@AGENTS.md`, the documented way to keep `AGENTS.md` the shared file (D18). The worker's reason for the system prompt (a target repository's own `AGENTS.md` that could disagree, part 1) does not apply: nothing else is in this folder. Putting the rules in the paddock checkout's own `AGENTS.md` instead is ruled out: every worker that develops paddock works in a worktree of that checkout and would read the secretary's rules.

| Axis | (R) system prompt | (F) `AGENTS.md` + `CLAUDE.md` in `<state>/secretary/` |
| --- | --- | --- |
| Survives compaction | Yes: "System prompt ... still apply" (D17); the flag's text is implied, not named | The project-root CLAUDE.md is "re-injected from disk" (D17). **Not stated:** whether a CLAUDE.md in a folder that is not a git repository counts as "project-root", and whether its `@AGENTS.md` import is re-injected with it (D11). Probe H3 |
| A change reaches the running secretary | Only by renewal (`secretary-handover`) | At the next compaction at the latest, because the re-injection reads the file from disk (D17), once `org-start --place-only` has placed it. Whether an edit is picked up sooner is **not stated** (D11); probe H3. A renewal still works |
| Weight against other instructions | System prompt level (D10) | A user message after the system prompt (D10); nothing in the folder competes with it. The person's own `~/.claude/CLAUDE.md` and any CLAUDE.md above `<state>` load in both options alike (D18) |
| A person can see it | A file in the bin folder; nothing points the person there | The instruction file of the folder the secretary runs in, where a person would look first |
| Leaks to workers that develop paddock | No | No (it is outside the checkout; it would leak if it were the checkout's `AGENTS.md`) |
| The secretary edits its own rules | Possible today: `secretary-settings.json` has hooks only, no deny | Possible, and the file sits in its own working folder. Either way the secretary settings deny `Edit`/`Write` on the rules file, and `org-start` overwrites it when it places files |
| Script paths | Unchanged: `bash skills/...` from the checkout (template L13) | The working folder moves, so every `skills/...` and `scripts/...` path the secretary runs gains a prefix: the template's `command` sets `PADDOCK_HOME=<checkout>` and the text says `bash "$PADDOCK_HOME/skills/..."`. `tests/secretary-cwd.test.sh` and the tests that read those lines change with it; `--plugin-dir` already names the checkout explicitly |
| Folder trust | The checkout is already trusted | A new folder raises the workspace trust dialog once (D19); `org-start` must handle it, as `org-curate start` already does for the curator's `knowledge/` folder |
| A Codex secretary later (principle 8) | No: `--append-system-prompt-file` is a Claude Code flag | `AGENTS.md` is the file Codex reads, so the rules move as they are. How Codex treats a working folder outside a git repository is **not verified** (see the Codex note above) |

**Recommendation: (F), gated on probe H3; (R) is the fallback.** In their plain form both are documented to survive compaction (D17); (F)'s two open points are what H3 checks. So the deciding axes are the others: (F) lets a landed rule reach a running secretary without a renewal (the cost #418 names: "each change to it needs a secretary renewal"), puts the rules where principle 8 says shared instructions go, and carries over to a Codex secretary. Its costs are one-time: the path prefix and the trust dialog, both in the wave 3 build. If H3 shows that the folder's CLAUDE.md or its `@AGENTS.md` import is not re-injected after an automatic compaction, the rules move to (R), and nothing else in this record changes.

### The rule, per line

| A line that ... | Goes to | Why |
| --- | --- | --- |
| must hold in every turn, whatever the situation (mostly "never ..." and "only through ...") | the standing rules file, `templates/secretary-rules.md`, placed per (F) or (R) above | It cannot wait for a skill to be invoked; it must survive compaction. |
| is a procedure for a situation, with judgment in it | a skill (`when_to_use` names the situation) | Loaded only when needed (D4), re-attached after compaction (D5), live after a landing (D3, H4). |
| is a fixed sequence with no judgment between the steps, a flag list, or what to do on an exit code | the script: one command for the sequence, flags in `--help`, and on every non-zero exit one line `next: <exact action>` or `next: ask the person: <question>` | Principle 9. The secretary reads one line instead of a table. |
| can be checked from the command text | a hook or a test (already: the secretary's Bash guard) | A rule a tool checks need not be read. |
| is data of one launch (the task, the language) | the template body or the task | It is the first message by design. |

Applied to the template at 79d7085 (each move is a build task below and moves its tests with it):

| Lines | Destination |
| --- | --- |
| L5, L7, L9 (role, language) | body keeps the role sentence; the language rule goes to the rules file |
| L13 (working folder) | rules file, one line; the check is `org-start`'s `--cwd` |
| L17, L20 (scoping a task, `task_id` form) | rules file (judgment on every delegation) |
| L18, L19 (org-delegate flags, exits) | `--help` and `next:` lines; skill `org-delegate` |
| L21 (uncloned repository) | one command: `org-delegate --repo OWNER/NAME` clones when needed and stops only at the trust card; skill `org-clone` keeps the trust judgment |
| L22 (stale base) | skill `org-delegate` ("a worker says base is stale") |
| L26, L27 (mailbox and config commands) | `scripts/org --help`; rules file keeps "talk through the mailbox only, change settings only through `org config`" |
| L28-L30 (watcher, `wait --children`) | rules file: one line "end turns idle; the watcher wakes you"; the rest to skill `org-watch` |
| L31-L33 (nothing may hold you, no `hc send`, org missing) | rules file; the `hc run --bg ... ; send_message` recipe is a candidate for one `org` subcommand |
| L37, L38, L42, L43 (status, blocked first, core, cleanup) | rules file |
| L47-L54 (`org-state`) | rules file keeps "you are its only writer; only through the helper"; field list and `--lazy`/`flush` to `scripts/org doc --help` |
| L58-L65 (handover) | skill `secretary-handover` (the writing half, model-invocable); the resume steps travel in the handover task text |
| L69-L71 (raw notes, curator, candidates) | skill `org-curate` |
| L75 (issues) | skill `org-issue` |
| L79-L88 (pull request, CI, update branch) | skill `org-pull-request` with `next:` lines; L83's placing after a landing becomes part of the landing in both modes (the secretary no longer remembers it) |
| L92 (close) | rules file keeps "never kill before the report is in"; the rest to skill `org-close` |
| L93 (shutdown) | skill `org-down` |
| L94, L95 (escalation, prompts) | skill `org-escalation` with `next:` lines; rules file keeps "a prompt is answered only after a fresh read of the screen matched it" |

Caps (tested, so they do not regrow): template body and rules file together under 12 KB, no line over 400 characters. Each SKILL.md body under 12 KB (part 2).

## 4. When a change reaches a running secretary

| What changed (after it lands and the checkout is fast-forwarded) | Reaches the running secretary | Basis |
| --- | --- | --- |
| A script under `skills/*/scripts/` or `scripts/org` run from the checkout | At its next call | It is read from disk each run |
| A copy in the bin folder (`org`, `worker-rules.md`, settings files) | After `org-start --place-only`; then at the next worker launch | Today's placing |
| A `SKILL.md` body | (P): **not stated**, probe H4. (S): within the session (D3). Either way, a copy the secretary already invoked stays in its conversation (D5) until it invokes the skill again | D3, D5 |
| A new skill folder | (P): **not stated**, H4. (S): picked up, as the `.claude/skills/` folder exists at start (D3) | D3 |
| The standing rules under (F): `AGENTS.md` in `<state>/secretary/`, after `org-start --place-only` | At the next compaction at the latest (re-injected from disk); sooner is **not stated**, probe H3; or by renewal | D11, D17 |
| The standing rules under (R), the template body, the template's flags | Renewal only (`secretary-handover`) | The system prompt and the first message are set at launch |
| A plugin hook, agent or `.mcp.json` | Renewal (or `/reload-plugins`, which nothing types into the secretary) | D3 |
| `secretary-settings.json` (passed with `--settings`) | Treated as renewal until probed; settings files are watched but `--settings` files are not stated (D15) | D15 |

Two consequences for the build:

- `org-start --place-only` already prints a renewal line when `secretary.md` changed; it prints the same for `secretary-rules.md` under (R) (under (F), a line that the rules take effect at the next compaction or renewal), and for a changed `SKILL.md` it prints `skill changed: paddock:<name> (invoke it again before you use it)`, so a stale copy in the conversation is not followed.
- After a compaction, the most recent invocation of each skill is re-attached (D5). That copy is the one from before a change, so the same "invoke it again" line covers it.

## Host probes

None of these is assumed by the recommendation; each one can change it, as noted.

| Id | What | How | Changes |
| --- | --- | --- | --- |
| H1 | The precedence section holds (#375, "Measure first") | A test repository whose `AGENTS.md` tells the agent to `git push` after committing; a worker with the new rules section, under (A); and once under (B) for comparison. Record which it follows, at launch and after a long session with `/compact`. | If (A) loses to the repository, the rules section needs a hook (a push is already refused by settings) and the answer to Q2 changes |
| H2 | `--add-dir` gives a worker no write access to the rules folder | Only if the owner picks (B): a worker under the worker settings tries `Edit` and a Bash write on the added folder's `CLAUDE.md` | (B) is ruled out if either succeeds |
| H3 | The secretary's standing rules hold after an automatic compaction, and when an edit reaches it (part 3) | Rerun `scripts/probes/q12-rule-after-compact.sh` in a template launch whose working folder is a non-git folder holding `AGENTS.md` (a codeword rule) and `CLAUDE.md` = `@AGENTS.md`; run past an **automatic** compaction (not `/compact`) and capture the replies, not only the screen. Then change the codeword in `AGENTS.md` mid-session: record whether the new one is followed before the next compaction, after it, or only after a restart. Run once more with the codeword only in an `--append-system-prompt-file` file (R) | If (F)'s file or its import is not re-injected, part 3 takes (R). If neither holds, the rules need a `SessionStart` hook on the `compact` source (D17's last row) |
| H4 | `--plugin-dir` of the checkout in a template launch | Start a secretary-like template with `--plugin-dir`; check: no dialog at launch; `paddock:` skills in the skill list; a skill is invoked by situation; edit its `SKILL.md` and add a new skill folder while it runs, invoke again, see the new text and the new skill | If edits are not live or a dialog appears, part 2 falls back to (S) with symlinks |
| H5 | `allowed-tools` pre-approves a skill's script call under the secretary's settings | Invoke a skill with `allowed-tools: Bash(bash skills/org-issue/scripts/org-issue.sh:*)` | Only decides whether the field is used |

**H1 result (2026-11-16, `scripts/probes/h1-precedence.sh` at 0210a64, hc 0.1.18, Claude Code 2.1.325):** control PASS (without the rules the worker pushed to the local bare repository, so the repository's `AGENTS.md` does pull), at launch PASS, after `/compact` PASS (committed, not pushed); verdict PASS. Under (A), with the precedence section, the rules won in both stages, and the worker said which instruction it did not follow and still followed the repository's commit-message line. **Not established:** that the compaction completed. The screen after `/compact` showed only the input box, with no completion text, so `s3-compacted: yes` is the probe's grep on the echoed command, not proof. The after-compact PASS therefore stands only as "after sending `/compact`"; an automatic compaction was not measured. One run, mechanism (A) only; (B) was not measured.

### Probe results

**H4 and H5, run 2026-11-15** on the host (paddock `6ff88e3`, hc 0.1.18, Claude Code 2.1.325), `scripts/probes/plugin-dir-skills.sh`, a throwaway plugin named `paddock` loaded with `--plugin-dir`, default permission mode:

| Question | Result |
| --- | --- |
| Dialog at launch | None from the plugin. The folder-trust dialog appeared, as it does without a plugin. `H4-dialog` PASS. |
| `paddock:` skills in the skill list; invoked by situation (`when_to_use`) | Yes, both. `H4-list`, `H4-invoke` PASS. |
| Edited `SKILL.md` seen while running | `H4-edit-live` **FAIL**: the new text did not appear. The run printed no evidence of what the agent did instead (it may have reused the old copy or the skill may be stale), so this is a failure to see the text, not a measured "stale". The probe now prints the matching lines and adds the step below. |
| New skill folder seen while running | `H4-new-skill` **FAIL**; after `/reload-plugins`, `H4-new-skill-after-reload` PASS. A new skill in a plugin needs a reload command, not a renewal. |
| Edited `SKILL.md` seen after `/reload-plugins` | **Not measured yet** (`H4-edit-after-reload`, added to the probe). If it passes, (P) stands with "run `/reload-plugins` after a landing"; if not, part 2 falls back to (S) as above. |
| `allowed-tools` pre-approves the script call | `H5-allowed-tools` **FAIL** with `Bash(bash <absolute path>/marker.sh:*)`: the script ran only after a permission prompt. The control (a call the field does not cover) was prompted, so prompts were on. |

Why H5 failed is **not established**. What is known: the form used was the `:*` suffix with an absolute path inside a plugin skill, and the prompt's text was not captured. The skills page (read through a summary of it, not verbatim) shows the forms `Bash(git add *)` and `Bash(${CLAUDE_SKILL_DIR}/scripts/render.sh *)`, says the grant lasts for the turn that invokes the skill, and does not say anything specific about plugin skills. The probe now also tries the space-star form with an absolute path (`H5-allowed-tools-b`) and with `${CLAUDE_SKILL_DIR}` (`-c`), and prints the prompt text, which tells a form problem from "plugin skills are not pre-approved". Until it is rerun, nothing here supports writing `allowed-tools` into a paddock skill.

## Build, in parallel units

Each unit is one worker task. Units in the same wave touch different files and can run at once.

**Wave 0 (probes, all in parallel):** H1, H3, H4 (H2 only if (B) is chosen; H5 rides on H4's run).

**Wave 1 (after H4, in parallel):**

1. *Plugin and front matter test.* `.claude-plugin/plugin.json`; `--plugin-dir` in the secretary template's `command` (and the handover launch); `templates/skill/SKILL.md` gains `when_to_use`; `tests/skill-frontmatter.test.sh` (only `name` and `description` required until wave 2 lands; then `when_to_use` and the caps). Files: those four and the template's line 3.
2. *Worker precedence.* The section in `templates/worker-rules.md` and "within your rules" in `templates/worker.md`; a test greps both. Independent of everything else.

**Wave 2 (after wave 1, one task per skill family, in parallel; each owns its skill folder, its scripts, its tests, and the template lines it empties):**

3. `org-delegate` + `org-clone`: `--repo OWNER/NAME` clones when needed; `next:` lines; SKILL.md form. Template L18-L22.
4. `org-escalation`: `next:` lines on `ask`/`prompt`/`answer`; SKILL.md form. Template L94-L95.
5. `org-pull-request` + `org-update-branch`: landing places files in both modes; `next:` lines. Template L79-L88.
6. `org-watch`, `org-close`, `org-curate`, `org-issue`, `secretary-handover`: SKILL.md form and their template lines (L28-L30, L58-L65, L69-L75, L92).
7. `org-start`, `org-down`, `org-suspend`, `org-resume`: SKILL.md form with `disable-model-invocation` where the person runs them; `org-start --place-only` prints the renewal and `skill changed` lines of part 4.

Each wave-2 task removes only its own template lines, so they do not conflict except by line position in one file; the template is merged last in each PR's rebase.

**Wave 3 (after wave 2):**

8. *Secretary rules file and the slim template.* `templates/secretary-rules.md` with the remaining standing lines, placed by `org-start`: under (F) as `<state>/secretary/AGENTS.md` plus a one-line `CLAUDE.md`, with the secretary's `--cwd` moved there, `PADDOCK_HOME` in the template's `command`, the `$PADDOCK_HOME/` prefix on every script path in the template and the skills, the trust dialog of the new folder handled in `org-start`, and an `Edit`/`Write` deny on the two files in `secretary-settings.json`; under (R) as `--append-system-prompt-file` in the command. Then the template body as situations → skills, the 12 KB / 400-character cap test, and the 21 tests that read `secretary.md` pointed at the right file. Then one dogfood round with no new hand step (#418's done-when).

## Questions for the owner

Answered 2026-11-15 (the owner's decision board, through the secretary): 1, 2, 3, 5, 6 and 7 **yes, as recommended**. Question 4 was first reopened with the owner's note: "moving the secretary's standing rules into a separate file in the system prompt still rests on the system prompt; what happened to moving them into `AGENTS.md` (or CLAUDE.md)?" It was rewritten from the comparison in [part 3](#where-the-secretarys-standing-rules-live), and the rewritten question was answered yes the same day (2026-11-15).

1. **Worker rules (#375 Q1):** keep `--append-system-prompt-file` (A) for Claude Code workers; build `CODEX_HOME` (C) only when a Codex worker exists. **Accepted.**
2. **Precedence (#375 Q2):** the rules decide where a worker may act and how it reports; the repository decides how the work is done; a repository instruction that would cross a rule is not followed and is named in the report, worded as in part 1. **Accepted.**
3. **Skill discovery (#419):** the paddock checkout as a plugin loaded with `--plugin-dir` (P), falling back to `.claude/skills` symlinks (S) if H4 fails. **Accepted.**
4. **Secretary rules (#418):** the secretary's working folder becomes `<state>/secretary/`, holding the standing rules as `AGENTS.md` and a one-line `CLAUDE.md` (`@AGENTS.md`), with the script paths prefixed by `$PADDOCK_HOME` (F); if probe H3 shows that file or its import is not re-injected after an automatic compaction, the rules go to the system prompt instead (R)? Either way the template body keeps only the opening task and a situations → skills list. **Accepted: (F), after H3; (R) if H3 shows no re-injection.**
5. **Caps:** template body + rules file under 12 KB, no line over 400 characters, each SKILL.md body under 12 KB (starting values). **Accepted.**
6. **Workers do not load the plugin;** how a worker learns of work skills stays open (decision 0009). **Accepted.**
7. **The `next:` line** (one line on every non-zero exit, `next: <action>` or `next: ask the person: <question>`) as the contract for every script the secretary runs. **Accepted.**

## Consequences (on acceptance)

- [open-questions.md Q12](../design/open-questions.md#q12-where-do-a-workers-role-rules-and-task-brief-live): add the precedence rule and a pointer here; the worker rules stay as decided.
- [architecture.md](../design/architecture.md) §4 "Role contracts": the secretary's role is a standing rules file plus a short template body; skills are a plugin loaded by the secretary. Under (F) the secretary's working folder is `<state>/secretary/`, not the paddock checkout (architecture's "Secretary" row and template L13 change), and its rules are an `AGENTS.md`, which is principle 8 applied to the secretary. A paddock `AGENTS.md` in the checkout, when one is written, stays for agents that work on paddock itself; the secretary's rules never go there, since every worker that develops paddock would read them.
- [decision 0009](0009-growth-through-skills-smallest-form.md) Part 5: the skill template gains `when_to_use` and the caps.
- [routine-procedures.md](../design/routine-procedures.md): the `next:` line joins principle 9's tool contract.
- A top-level `agents/`, `hooks/` or `.mcp.json` in this repository becomes part of the plugin; adding one is a decision, not a file.
