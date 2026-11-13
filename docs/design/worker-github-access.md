# Worker GitHub access without a hand-made token

Status: comparison, 2026-11-13 (Issue #277, Refs #267). Nothing here is built and nothing is decided: the owner decides. The rule being met is [Q20](open-questions.md#q20-how-is-a-workers-github-access-held-to-read-only): a worker can fetch and pull, and holds nothing it can use to write; GitHub, not a rule the agent could bypass, refuses the write.

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

The secretary keeps a bare mirror per repository fetched on a schedule; a worker's `origin` points at the local path. Nothing in the worker authenticates to GitHub.

- Strongest on Q20: there is no credential to misuse, and the person's login stays out of reach if the mirror folder is the only thing a worker mounts. *Needs probe* (not a documented GitHub feature: a Paddock design).
- Cost: the worker cannot reach the API (CI watching, PR reads), mirror freshness is the secretary's job, and Q20 already rejected "secretary fetching on behalf of workers" as toil. An automated mirror removes the toil but is new software. Not pursued unless A and B both fail their probes.

### E. Considered and set aside

- **Classic PAT or OAuth token:** the read-only repository scope for private repositories does not exist for classic tokens as far as this review read; not verified, set aside because fine-grained and App tokens exist.
- **Actions' `GITHUB_TOKEN`:** only exists inside a workflow run; a worker is not one.

## Comparison

| | PAT today | A. App token | B. Deploy key | C. Machine account | D. Mirror |
| --- | --- | --- | --- | --- | --- |
| Made by hand per repository set | Yes | Once (two clicks) | Per repository, by API | Account once, token by hand | No |
| Expires and must be renewed by hand | Yes | No (1 hour, minted) | Never, so never rotated | Token yes | No |
| Write line held by | Token scope | App ceiling | Per-key flag | Role | No credential |
| Worker keeps `gh` and API reads | Yes | Yes (needs probe: scopes) | Needs probe | Yes | No |
| New code | None | Minter and helper | Key generation | None | Mirror sync |
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
| **D. Mirror** | Everything: it uses the credential the person's own secretary already holds; nothing is registered, installed or approved on GitHub. | Nothing. | Nothing on GitHub's side (an organization can still audit or restrict the person's own login, which Paddock already uses). | By design; the mirror itself Needs probe |

**What this changes.**

- The **manual PAT is not a developer-discretion option in a default organization**: approval by an owner is the default, and an owner or the enterprise can switch fine-grained tokens off. The earlier text called it "the only option measured as not cutting the worker's tools"; it also is the one most often blocked by organization policy. Only the owner of the organization, or a personal repository, finishes it alone.
- **A** is discretionary in one useful case: a developer who administers the repository, in an organization that has not limited installation to owners, with a read-only app that needs no organization permission. It is not discretionary when the organization limits installs to owners (a request goes to an owner) or when an enterprise policy forbids it (unchecked). Registering the app is always the developer's own.
- **B** needs the fewest people when it is allowed, and it is blocked by default in new organizations, with an off switch for owners and the enterprise: it only works where an owner already allowed deploy keys.
- **C** is no better than the PAT (a token from the second account needs the same approval) and adds an invitation that an organization may restrict.
- **D** is the only option that no organization setting can stop, at the cost of API reads (CI watching, pull request views).

## Recommendation

Revised 2026-11-13 after the axis above. The first recommendation (A, with the manual token as fallback) stands for **technical** fit; for **developer discretion** it needs a floor that no organization can remove. So:

1. **Primary: A, GitHub App**, built behind the probes below. The worker template reads the app key when it is there and the token file otherwise (so today's setup keeps working).
2. **Floor: D, mirror**, for a developer whose organization limits installs to owners or has an enterprise policy against them (or if A's probes fail). It gives up API reads, but nothing outside the developer's own account is needed.
3. **The manual PAT stays only where an owner already approves it** (the owner's own organization, a personal repository). It is no longer the default answer for a company organization.
4. **B only** when the organization already allows deploy keys and workers do not need the API.

Probes for A, so the worker template does not change first:

1. A token minted with `contents: write` from a read-only app is refused (the ceiling).
2. A worker terminal and a Claude child fetch a private repository with the minted token through git's credential helper, and a push fails; `gh run watch` succeeds with Actions read.
3. A worker running longer than one hour keeps fetching through the helper, and an API read (a pull request view, a run watch) made after the first token's expiry still succeeds, without a relaunch.

4. Add for the new axis: in an organization that limits installs to owners, the developer's install request reaches an owner and, until it is approved, the worker keeps its previous credential (record what the person sees). Also ask an enterprise owner, or test under an enterprise policy, whether one can forbid the install (unchecked above).

If probe 3 fails, or the owner will not keep a private key beside the token file, fall back to the floor (D) or, where an owner approves it, the manual token: its cost is the person's time, and it does not cut the worker's tools.

**Not decided here.** Whether the app's private key may be reachable by the worker (this is what makes the 1-hour expiry workable); the owner decides, together with the Q20 known limit.
