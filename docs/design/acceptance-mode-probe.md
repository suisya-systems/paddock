# Acceptance-mode probe

Status: written, not yet run on a host (Issue #330, goal clause G2). [org-pull-request](../../skills/org-pull-request/SKILL.md) in `acceptance` mode and [org-update-branch](../../skills/org-update-branch/SKILL.md) were only tested against stubs and a local bare repository. This probe runs them against a real repository whose `main` requires the `acceptance` check and up-to-date branches. The settings the owner still has to make in paddock itself are in [acceptance-check](acceptance-check.md#settings-only-the-owner-can-make).

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

Not covered: `PADDOCK_ORG` in a real worker session.

## Result

Not run yet.
