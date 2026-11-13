# Worker GitHub access without a hand-made token

Status: comparison, 2026-11-13 (Issue #277, Refs #267). Nothing here is built and nothing is decided: the owner decides. The rule being met is [Q20](open-questions.md#q20-how-is-a-workers-github-access-held-to-read-only): a worker can fetch and pull, and holds nothing it can use to write; GitHub, not a rule the agent could bypass, refuses the write.

**Premise check (2026-11-13).** Options are judged on what a Paddock worker does with GitHub: it fetches the base and commits; the secretary pushes, opens the PR and watches CI ([open-questions.md](open-questions.md) line 324). Weigh API reads only for a worker that would make them.

**Today (Q20 (d)).** The person creates a fine-grained personal access token (PAT) with `contents:read` by hand on GitHub and saves it as `worker-gh-token`; the [worker template](../../templates/worker.md) sets `GH_TOKEN` from it and `GH_CONFIG_DIR` to an empty folder. Costs the owner named: the token is made by hand (GitHub has no API to create a fine-grained PAT; the docs only describe pre-filling the creation page), it expires and must be renewed by hand, and the repository list is chosen by hand on a web page. ([managing PATs](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens), read 2026-11-13.)

**Feasibility marks.** *Verified by doc*: the quoted page says it. *Needs probe*: the page is silent or only summarized when read, or the claim is about how Paddock's pieces behave together. No probe was run for this document.

## Options

### A. GitHub App, installation token minted per worker launch

A GitHub App is registered once with read permissions only and installed on the repositories workers may fetch. At each worker launch (or on demand, see the expiry row), a small minter signs a JWT with the app's private key and calls `POST /app/installations/{id}/access_tokens`, narrowing to the one repository and to the read permissions; the result goes in `GH_TOKEN`.

| Claim | Mark | Source |
| --- | --- | --- |
| A token expires after 1 hour; an expired one returns 401. | Verified by doc | [generating an installation access token](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app): "The installation access token will expire after 1 hour."; [REST, create token](https://docs.github.com/en/rest/apps/apps#create-an-installation-access-token-for-an-app) |
| The request can narrow `repositories` and `permissions`, and cannot exceed the app or the installation. | Verified by doc | same pages: "The installation access token cannot be granted permissions that the app was not granted." and "...repositories that the installation was not granted access to." |
| Git over HTTPS works with the token as the password, user `x-access-token`; the app needs the Contents permission. | Verified by doc | [authenticating as an installation](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation): `git clone https://x-access-token:TOKEN@github.com/owner/repo.git` |
| `gh` takes the token from `GH_TOKEN` for github.com and it wins over stored credentials. | Verified by doc | [gh help environment](https://cli.github.com/manual/gh_help_environment) |
| Minting needs a JWT with the app's private key and the installation id. | Verified by doc (JWT maximum lifetime and signing details are on a separate page, not read) | the first two pages above |
| An app with read permissions only cannot mint a write token (a ceiling that holds even if the key leaks). | Needs probe: follows from the "cannot be granted permissions that the app was not granted" sentence, but no page states it for a leaked key; probe by requesting `contents: write` and expecting a refusal | |
| `gh run watch` and PR reads work: runs need Actions read, a pull request needs Pull requests read, contents and commits need Contents read. | Needs probe: read from a summarized copy of [permissions required for GitHub Apps](https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps), not verbatim. This also answers the open scope question in Q20. | |
| Git's credential helper (`gh`) picks up `GH_TOKEN` in the worker's terminal and in the Claude child. | Needs probe (the same unmeasured item as Q20) | |
| Rate limits of installation tokens. | Needs probe: not stated on the pages read | |
| Tokens minted after 2026-04-27 may use a longer stateless format (`ghs_APPID_JWT`), so code must not assume 40 characters. | Verified by doc | the first page above |
| One-time setup can be scripted with the manifest flow, which pre-sets `default_permissions` and returns the private key (`pem`) from `POST /app-manifests/{code}/conversions`. | Verified by doc. A person still clicks **Create GitHub App** (the code comes from that redirect), then installs the app: two clicks, once. | [registering a GitHub App from a manifest](https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest) |

**Against Q20.** Better than the PAT on the write side: the ceiling is the app's permission set, not a token the person must remember to scope. Open points:

- **The 1-hour expiry is shorter than a worker's life.** A token minted at launch dies mid-task. The fix is a minter the worker calls again. Git can call a credential helper, but `gh` API commands read the inherited `GH_TOKEN` and do not consult it, so `gh` needs its own path (for example a wrapper that mints a fresh token per call); this part is not designed here. Either way the worker can reach the minter, which means the worker can reach the minter and so the private key. That is acceptable only because the app has read permissions only (the *needs probe* ceiling row above); it must be probed before relying on it. Without a helper, a worker would need a relaunch each hour.
- **The private key is a new long-lived secret**, stored outside the repository like `worker-gh-token` today. Its blast radius is read access to the installed repositories, until the owner widens the app's permissions, which then widens what a leaked key can do. The app's permissions must be treated as part of Q20's line.
- The Q20 known limit (a started program can unset `GH_TOKEN` and `GH_CONFIG_DIR` and fall back to the person's login) is unchanged.
- New code: a JWT signer (RS256 with `openssl`, or a small script) and the helper. The token file and the template's launch check change to a key file.

### B. Read-only deploy key per repository

A key pair is generated per repository and its public half is added to that repository as a deploy key, read-only.

| Claim | Mark | Source |
| --- | --- | --- |
| Read-only by default; write is granted only by an explicit option. | Verified by doc | [managing deploy keys](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys): "Deploy keys are read-only by default, but you can give them write access when adding them to a repository." |
| One key per repository; a key cannot be reused. | Verified by doc | same page: "You can't reuse a deploy key for multiple repositories." |
| Access is to a single repository only; used over SSH. | Verified by doc | same page: "Deploy keys only grant access to a single repository." |
| Keys can be created and revoked by REST (`POST` and `DELETE /repos/{owner}/{repo}/keys`), with `read_only`. No organization-level endpoint is listed. The role needed to call them is not stated. | Verified by doc (role: needs probe) | [REST, deploy keys](https://docs.github.com/en/rest/deploy-keys/deploy-keys) |
| A deploy key authenticates the REST API or `gh` (PR reads, `gh run watch`). | Needs probe: neither page says it does; the docs describe SSH use only | |
| No expiry, no passphrase by default, and not tied to organization membership. | Verified by doc | managing deploy keys: "credentials that don't have an expiry date"; "usually not protected by a passphrase" |

**Against Q20.** Holds the write line only as long as every key was added read-only, and that is a per-repository choice the person can get wrong; the key itself does not carry a ceiling the way an app does. It also cuts the worker's `gh` use if the API does not accept the key (CI watching, PR reads), and it needs one key and one SSH setup per repository. The managing-deploy-keys page itself recommends a GitHub App for finer control. No expiry means revocation is the only rotation. Cheapest to build (no minter), weakest on what a worker can read through the API.

### C. Machine account with the Read role

A second GitHub account, added to the repositories with the Read role, with its own PAT in the worker template.

| Claim | Mark | Source |
| --- | --- | --- |
| The Read role can pull and cannot push or merge. | Verified by doc | [repository roles for an organization](https://docs.github.com/en/organizations/managing-user-access-to-your-organizations-repositories/managing-repository-roles/repository-roles-for-an-organization) |
| Machine accounts are allowed, one free one per person, to run a machine. | Verified by doc | [GitHub Terms of Service](https://docs.github.com/en/site-policy/github-terms/github-terms-of-service), B.3 |
| It removes the hand-made, repository-scoped token. | **No**: the account still needs a token or key, made by hand and renewed by hand. | |

**Against Q20.** Holds the line through the role, not the token, which is a good ceiling, but it keeps the manual-token problem and adds an account to keep alive. Rejected as the answer to #277. It is not a fallback for repositories of a personal account either: a personal repository has no Read role (a collaborator gets write), and the deploy-keys page says "Only organizations can restrict machine users to read-only access." There the account would need a read-only credential and gain no role-based ceiling.

### D. No GitHub credential in the worker (local mirror)

Nothing in the worker authenticates to GitHub. The worker reads from a local copy of the repository that the secretary keeps fresh; the secretary alone talks to GitHub.

**Why the old cost does not apply (corrected 2026-11-13, owner review).** An earlier version of this section rated D down because "the worker cannot reach the API (CI watching, PR reads)". In Paddock the worker never does either: the [worker template](../../templates/worker.md) (line 11) says "Do not push and do not open a pull request; the secretary does both", and [org-pull-request](../../skills/org-pull-request/SKILL.md) ("Run it from the secretary") pushes, opens the PR and starts the CI watcher with the secretary's credential ([open-questions.md](open-questions.md) line 324, "Waking on CI completion"). The premise came from Q20's open scope question ([open-questions.md](open-questions.md) line 790, "The worker would use it to watch its own CI"), which assumed a design Paddock does not have. What the worker needs from GitHub is only a base to branch from and to compare against: git objects, not the API. The same corrected premise lowers the cost of A and B too (they no longer buy API reads the worker does not use), but they still carry a credential; D does not.

**How it works.** No new software is needed for the first version, because the mirror is the project clone the secretary already has:

- **Who fetches, and when.** The secretary, at delegate time. [org-delegate.sh](../../skills/org-delegate/scripts/org-delegate.sh) lines 139-143 already run `git fetch origin` in the project before `git worktree add` and branch from `origin/<base>` (a failed fetch stops with exit 6 before anything is created; `--no-fetch` skips it). So the worktree is current at creation with no new step. On demand, the secretary runs the same `git fetch origin` in the project clone (for example when a worker reports that its base is stale); it is one command and happens only when asked, not on a schedule.
- **How a worker's `origin` points at it.** It does not need to be repointed. A worktree shares its repository's object store, remote-tracking refs (`refs/remotes/origin/*`) and `origin` URL with the project clone, so `git log origin/main`, `git diff origin/main...HEAD` and `git rebase origin/main` in the worker read what the secretary last fetched, with no network and no credential. (A separate bare mirror would only be needed for a worker that has no worktree of the project clone; Paddock has none.)
- **What a worker does when it needs a newer base.** It does not fetch (it has no credential, so its own `git fetch origin` of a private repository fails, which is the intended line). It reports "base is stale, need origin/<branch> at or after <sha>" in its message to the secretary; the secretary fetches in the project clone and replies; the worker then sees the new `origin/*` and rebases itself. This is the "secretary fetching on behalf of workers" that Q20 rejected as toil, narrowed: it is not per fetch or pull, only the rare stale-base case, because delegate time already fetches.
- **What stays out of reach.** The worker has no `GH_TOKEN`, so the Q20 line holds without a token; the known limit (a started program falling back to the person's login) still applies to whatever the secretary's home holds, and is unchanged.

**Needs probe** (not a documented GitHub feature; these are claims about how Paddock's pieces behave together; first measured 2026-11-13, see "Measured" below):

1. A worker terminal started without `GH_TOKEN` (and with the empty `GH_CONFIG_DIR`) can `git log`, `git diff` and `git rebase` against `origin/<base>` as fetched by the secretary, and its own `git fetch origin` of a private repository fails without leaving the refs half-updated.
2. After the secretary fetches in the project clone, the new `origin/*` is visible in a running worker's worktree without a restart.
3. The worker's sandbox lets git read the shared object store and refs of the project clone (the worktree's admin folder is writable, the common folder may be read-only); record what a `git rebase` needs to write there.
4. The stale-base round trip (worker message, secretary fetch, worker rebase) works in the mailbox as the mailbox is used today.

**Probe.** [scripts/probes/worker-mirror.sh](../../scripts/probes/worker-mirror.sh) measures items 1-4 above from a worker started with the worker template's command (token removed, `GH_TOKEN` unset, empty `GH_CONFIG_DIR`) and the worker settings sandbox, against a throw-away project clone. It prints one verdict line per item. Its stale-base "message" is a file the worker writes, not the org mailbox.

**Measured 2026-11-13** (host run by the secretary, commit f0eda21; git 2.43.0, hc 0.1.18, Claude Code 2.1.323; the control `ls-remote` of the private repository from the runner succeeded). The probe's items 1-3 cover the list above as: probe 1 = reading and committing in the shared clone (list 1 and 3), probe 2 = list 2, probe 3 = the git side of list 4 (rebase); probe 4 = the fetch-fails half of list 1.

| Probe item | Result | How to read it |
|---|---|---|
| 1 read-shared-refs | PASS | The worker read `origin/main`, its log, diff and objects from the project clone, and **committed** from its worktree. The throw-away clone was placed outside the paths the worker sandbox may write, so a commit that succeeded means the worker sandbox wrote the shared object store and the branch ref. Which paths it needed was not recorded (list 3 stays open on that point). |
| 2 fetch-visible | PASS | The worker's `wait` step already showed the new value as "before": the secretary-side fetch had finished before the worker entered `wait`, so that line cannot show a change. The change the running worker saw is the `origin/main` it read at `read` time (db68ad1) against the one it read after the fetch (92808c8), in the same process and with no restart. |
| 3 stale-base-round-trip | PASS | The worker rebased onto the newly fetched `origin/main` (rebase and ancestor checks 0, its file kept). Only the git side of the round trip: the "base is stale" message was a file, so the mailbox leg of list 4 is **not measured**. |
| 4 no-github-credential | INCONCLUSIVE | Measured: no token variable, `GH_CONFIG_DIR` an empty folder, `gh auth status` exit 1, `git credential fill` returned no password. The fetch of the private repository failed (exit 128, refs unchanged) with `CONNECT tunnel failed, response 403`: the worker sandbox's network allowlist refused the connection, so the failure does not show that GitHub would refuse an unauthenticated request, and "no credential" was not confirmed on the wire. It is still an extra wall for D: even a credential found later would not reach GitHub from the worker. |

Other facts: the worker was started through the production path, `org-escalation prompt --task <id> --then-send` passed Claude Code's folder-trust dialog on the new worktree (exit 0, `POLICY folder-trust`), which is the #260 path of [Q13](open-questions.md); a trusted parent folder did not carry over to the new worktree. A warning `unable to access '<worktree>/.gitmodules': Permission denied` appeared in the fetch output; its cause is not confirmed. `git push` was not attempted (the worker settings deny it by permission, which would not show the credential side).

Cost left: the worker has no API reads (a pull request's comments, a run's logs), which Paddock's workers do not use today; if a worker role ever needs them, that is the case for A. The secretary's fetch at delegate time stays a dependency: a stale project clone gives a stale base, which `--no-fetch` makes silent.

### E. Considered and set aside

- **Classic PAT or OAuth token:** the read-only repository scope for private repositories does not exist for classic tokens as far as this review read; not verified, set aside because fine-grained and App tokens exist.
- **Actions' `GITHUB_TOKEN`:** only exists inside a workflow run; a worker is not one.

## Comparison

| | PAT today | A. App token | B. Deploy key | C. Machine account | D. Mirror |
| --- | --- | --- | --- | --- | --- |
| Made by hand per repository set | Yes | Once (two clicks) | Per repository, by API | Account once, token by hand | No |
| Expires and must be renewed by hand | Yes | No (1 hour, minted) | Never, so never rotated | Token yes | No |
| Write line held by | Token scope | App ceiling | Per-key flag | Role | No credential |
| Worker keeps `gh` and API reads (Paddock's worker does not use them: the secretary pushes and watches CI) | Yes | Yes (needs probe: scopes) | Needs probe | Yes | No, and not needed today |
| New code | None | Minter and helper | Key generation | None | None for the first version (delegate-time fetch exists); a stale-base message rule |
| Long-lived secret to guard | Token | Private key | Private key per repository | Token | None |
| Developer finishes it alone in a default company organization (new axis, see below) | No: an owner approves by default | Only if admin on the repository and installs are not owner-only | Only if deploy keys are allowed (off by default for new organizations) | No | Yes |

## Axis added 2026-11-13: can one developer finish it alone?

Review point (owner): a developer in a company organization often cannot grant themself anything; an option that needs an organization owner, or that an organization can switch off, counts against it. The question per option: **can a developer with their own account and (at most) admin on the repository set it up with no one else's action, and what can the organization or enterprise do to stop it?** Facts come from docs read 2026-11-13; the setting names are the docs' own.

| Option | What the developer can do alone | What needs an organization owner | What an organization or enterprise can switch off | Mark |
| --- | --- | --- | --- | --- |
| **PAT today (fine-grained)** | Create the token for a resource owner. Tokens read public resources without approval. | Default: "An organization owner must approve each fine-grained personal access token that can access the organization." An owner's own request is approved automatically. Until approved the token reads public resources only. | An owner can set "Restrict access via personal access tokens" (classic and fine-grained cannot reach the organization's resources). An enterprise can fix that setting or the approval setting so organizations "cannot override" it, and set a maximum lifetime. | Verified by doc: [org PAT policy](https://docs.github.com/en/organizations/managing-programmatic-access-to-your-organization/setting-a-personal-access-token-policy-for-your-organization), [enterprise PAT policy](https://docs.github.com/en/enterprise-cloud@latest/admin/enforcing-policies/enforcing-policies-for-your-enterprise/enforcing-policies-for-personal-access-tokens-in-your-enterprise), [managing PATs](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) |
| **A. GitHub App** | Register the app: "You can register a GitHub App under your personal account or under any organization you own." ([registering](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app)). Install it on a repository the developer administers, when the app asks for no organization permission and no Repository administration permission. | Installing on the organization; a member who is not an owner can only send the owner a request ([installing a GitHub App](https://docs.github.com/en/apps/using-github-apps/installing-a-github-app-from-a-third-party)). | An organization can limit installation to owners and turn the requests off ([limiting access requests and installations](https://docs.github.com/en/organizations/managing-programmatic-access-to-your-organization/limiting-oauth-app-and-github-app-access-requests-and-installations)). An enterprise policy for GitHub Apps: **unchecked**; the enterprise-level policy page was not found (the page tried returned 404), so the answer is Needs probe: ask an enterprise owner or try an install under a restricting policy. | Verified by doc for the three rows above; enterprise: unchecked |
| **B. Deploy key** | Add a read-only key to a repository, no approval step exists in the docs read. The role needed is not stated on the deploy-keys pages; a summary of the roles table reads "Manage webhooks and deploy keys: Admin only" (not read verbatim: Needs probe). | Not stated. | **Most exposed.** "Organization owners can disable deploy keys entirely across the organization, which disables all existing deploy keys"; "By default, new organizations are configured to disallow the creation of deploy keys in repositories"; "Enterprise owners can enforce a policy to disable deploy keys across all repositories." ([credential types](https://docs.github.com/en/organizations/managing-programmatic-access-to-your-organization/github-credential-types), [restricting deploy keys](https://docs.github.com/en/organizations/managing-organization-settings/restricting-deploy-keys-in-your-organization)). Also, a PAT restriction does not stop SSH ("SSH keys created by personal access tokens will continue to work"). | Verified by doc (role: Needs probe) |
| **C. Machine account** | A second personal account (allowed: one free machine account per person, [terms of service](https://docs.github.com/en/site-policy/github-terms/github-terms-of-service) B.3). | Putting it on repositories: "By default, anyone with admin access to a repository can invite outside collaborators", but an organization can restrict that to owners only (Enterprise Cloud) ([outside collaborators](https://docs.github.com/en/organizations/managing-user-access-to-your-organizations-repositories/managing-outside-collaborators/adding-outside-collaborators-to-repositories-in-your-organization)). Read-only through a role works only in an organization, and the account's own fine-grained token falls under the same approval policy as the PAT row. | The owners-only invitation setting, and the PAT policy above for its token. A company is also likely to refuse a machine account on a corporate organization; that is a policy matter the docs do not state. | Verified by doc; company policy: unchecked |
| **D. Mirror** | Everything: it uses the credential the person's own secretary already holds; nothing is registered, installed or approved on GitHub. | Nothing. | Nothing on GitHub's side (an organization can still audit or restrict the person's own login, which Paddock already uses). | By design; the worker-side reads Need probe (D section) |

**What this changes.**

- The **manual PAT is not a developer-discretion option in a default organization**: approval by an owner is the default, and an owner or the enterprise can switch fine-grained tokens off. The earlier text called it "the only option measured as not cutting the worker's tools"; it also is the one most often blocked by organization policy. Only the owner of the organization, or a personal repository, finishes it alone.
- **A** is discretionary in one useful case: a developer who administers the repository, in an organization that has not limited installation to owners, with a read-only app that needs no organization permission. It is not discretionary when the organization limits installs to owners (a request goes to an owner) or when an enterprise policy forbids it (unchecked). Registering the app is always the developer's own.
- **B** needs the fewest people when it is allowed, and it is blocked by default in new organizations, with an off switch for owners and the enterprise: it only works where an owner already allowed deploy keys.
- **C** is no better than the PAT (a token from the second account needs the same approval) and adds an invitation that an organization may restrict.
- **D** is the only option that no organization setting can stop. Its earlier cost, API reads (CI watching, pull request views), is not a cost in Paddock: the secretary does both (see D).

## Recommendation

Revised 2026-11-13 after the owner review of D's cost (see D). With the corrected premise, D has no cost that Paddock pays today, and it is the only option with no credential in the worker, no expiry, no key to guard and nothing for an organization to approve or switch off. So:

1. **Primary: D, mirror (the secretary's project clone, fetched at delegate time and on demand)**. Its probes held on 2026-11-13 for reading, committing, seeing a new fetch and rebasing from a credential-free worker (see D, "Measured"); two points stay open: the mailbox leg of the stale-base round trip and an unauthenticated refusal from GitHub itself (the worker sandbox's network allowlist refused GitHub first). It needs no setup on GitHub, so every developer can finish it alone. It is also the smallest change: the delegate-time fetch exists, and the worker template already leaves push and PR to the secretary.
2. **Alternative: A, GitHub App**, when a worker role needs API reads (PR comments, run logs) or fetches from GitHub itself. Built behind the probes below. The worker template reads the app key when it is there and the token file otherwise.
3. **Alternative: B, deploy key**, only when the organization already allows deploy keys and a worker fetches directly.
4. **The manual PAT stays only where an owner already approves it** (the owner's own organization, a personal repository). It is not the default answer for a company organization.

Probes for D are listed in its section. Probes for A, run only if A is pursued, so the worker template does not change first:

1. A token minted with `contents: write` from a read-only app is refused (the ceiling).
2. A worker terminal and a Claude child fetch a private repository with the minted token through git's credential helper, and a push fails; `gh run watch` succeeds with Actions read.
3. A worker running longer than one hour keeps fetching through the helper, and an API read (a pull request view, a run watch) made after the first token's expiry still succeeds, without a relaunch.
4. In an organization that limits installs to owners, the developer's install request reaches an owner and, until it is approved, the worker keeps its previous credential (record what the person sees). Also ask an enterprise owner, or test under an enterprise policy, whether one can forbid the install (unchecked above).

If a D probe fails (for example the worker cannot read the shared refs under its sandbox), fall back to A where installs are allowed, or to the manual token where an owner approves it; its cost is the person's time.

**Not decided here.** The owner leans to D and the probes did not contradict it; the decision is still the owner's, between D and A. Before D is called settled: run the stale-base message through the real mailbox, and, only if wanted, record which paths a worker's commit and rebase write in the project clone. If A is chosen, whether the app's private key may be reachable by the worker (this is what makes the 1-hour expiry workable), together with the Q20 known limit.
