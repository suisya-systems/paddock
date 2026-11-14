# Acceptance-mode probe

Status: run on a host on 2026-11-14, all steps PASS ([Result](#result)); Issue #330, goal clause G2. [org-pull-request](../../skills/org-pull-request/SKILL.md) in `acceptance` mode and [org-update-branch](../../skills/org-update-branch/SKILL.md) were only tested against stubs and a local bare repository. This probe runs them against a real repository whose `main` requires the `acceptance` check and up-to-date branches. The settings the owner still has to make in paddock itself are in [acceptance-check](acceptance-check.md#settings-only-the-owner-can-make).

## Run

On the host, from the paddock root, in a terminal that `hc` launched, with a `gh` login that may push to and administer the throwaway repository of [Prototype 3](prototype-3.md) (its `main` already holds the acceptance job):

```sh
sh scripts/probes/acceptance-mode.sh --repo OWNER/NAME --project <clone of it> --set-protection
sh scripts/probes/acceptance-mode.sh --only-settings   # paddock's own settings, read only
```

Never paddock itself as `--repo` (the probe exits 6). It starts no `claude` and writes no `~/.claude.json`.

## Pass criteria

| RESULT | PASS when |
| --- | --- |
| `settings-acceptance-required`, `settings-up-to-date` | `main` of the throwaway requires `acceptance` and up-to-date branches (read back after `--set-protection`) |
| `1-green-merge` | `org-pull-request --mode acceptance`, stdin closed, on a branch with a declared test first: exit 0, PR `MERGED`, a `ci_completed` line with `exit_code` 0 |
| `3-stale-base-refused` | the same call on a PR whose base moved: exit 10 or 11, PR still `OPEN` |
| `2-update-branch` | `org-update-branch` exits 0 and the branch holds both the new `origin/main` and its old head |
| `2-push-no-force` | a plain push of the branch (no force flag) is accepted |
| `3-stale-head-refused` | with the new head green, `gh pr merge --match-head-commit <old head>` is refused, PR still `OPEN` |
| `2-merge-after-update` | `org-pull-request --pr N --mode acceptance` on the updated head: exit 0, PR `MERGED` |
| `settings-paddock-*` | INFO only: records the required checks and strictness on paddock's `main` (classic protection and rulesets) |

Not covered here: `PADDOCK_ORG` in a real worker session. That is [the worker probe](#worker-probe) below.

## Worker probe

`scripts/probes/update-branch-worker.sh` starts a real worker with `org-delegate` and has it run `org-update-branch` twice, so the worker check (`PADDOCK_ORG` set by the worker's launch command, the protected-path stop) runs in the sandbox it was written for. It starts no `claude` itself; the worker is the one `org-delegate` starts. Run it on the host, from the paddock root, in a terminal that `hc` launched, after `org-start` from this checkout, with the scratch repository (`happy-ryo/paddock-proto2-scratch`) and a clone of it that Claude Code already trusts:

```sh
sh scripts/probes/update-branch-worker.sh --repo happy-ryo/paddock-proto2-scratch --project <clone of it>
```

It pushes two side branches of the scratch repository (never its `main`, which may be protected) and deletes them on exit.

| RESULT | PASS when |
| --- | --- |
| `delegate`, `report-done`, `in-box` | the worker started and its `report done` reached the secretary's box |
| `worker-env` | the worker saw `PADDOCK_ORG` set |
| `worker-merge` | in the worker, `org-update-branch --base <plain side branch>` exits 0, `HEAD` moves, the branch holds that base (the worker cannot fetch; exit 5 would mean origin/<base> was not in the project clone, which the secretary's fetch at delegate time provides) |
| `worker-protected-stop` | in the worker, `--base <side branch adding .claude/skills/...>` exits 4, names the path, `HEAD` does not move |
| `host-control` | the same range on the host with `PADDOCK_ORG` unset exits 0 and merges |

Result: not run yet.

## Result

Host run on 2026-11-14 against the throwaway repository of Prototype 3, with `--set-protection`; the probe exited 0.

| RESULT | Outcome |
| --- | --- |
| `settings-acceptance-required` | PASS (`contexts=acceptance`) |
| `settings-up-to-date` | PASS |
| `settings-enforce-admins` | INFO (`true`) |
| `1-green-merge` | PASS: exit 0, PR 8 `MERGED`, `ci_completed` with `exit_code` 0 |
| `3-stale-base-refused` | PASS: exit 11, PR 7 `OPEN`, merge state `BEHIND` |
| `2-update-branch` | PASS: exit 0, new `origin/main` and the old head both in the branch |
| `2-push-no-force` | PASS: a plain push was accepted |
| `3-stale-head-refused` | PASS: exit 1, PR 7 `OPEN` |
| `2-merge-after-update` | PASS: exit 0, PR 7 `MERGED` |
| `settings-paddock-protection`, `settings-paddock-rules` | INFO: paddock's `main` has no branch protection (404 "Branch not protected") and no ruleset |

What this measured: `gh pr checks --required` under branch protection, the squash merge pinned with `--match-head-commit`, and a real push after `org-update-branch` all behave as the skills assume. A stale base is refused at the merge itself (exit 11), not by `gh pr checks --required`. The probe left the throwaway's protection on.

What it left open:

- paddock's own `main`, at the time of the probe, required neither `acceptance` nor up-to-date branches, so `acceptance` mode there was not guarded by the settings this probe relied on. The probe only records the state. Afterwards, on 2026-11-14, the owner set the protection on paddock's `main`: required check `acceptance`, branches up to date before merging, enforced for admins ([acceptance-check](acceptance-check.md#settings-only-the-owner-can-make)). That setting itself was made by the owner and not re-read by the probe.
- `PADDOCK_ORG` in a real worker session was not covered.
