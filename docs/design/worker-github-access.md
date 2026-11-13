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

## Recommendation

Choose **A, GitHub App**, but keep the manual token until three probes pass, so the worker template does not change first:

1. A token minted with `contents: write` from a read-only app is refused (the ceiling).
2. A worker terminal and a Claude child fetch a private repository with the minted token through git's credential helper, and a push fails; `gh run watch` succeeds with Actions read.
3. A worker running longer than one hour keeps fetching through the helper, and an API read (a pull request view, a run watch) made after the first token's expiry still succeeds, without a relaunch.

If probe 3 fails, or the owner will not keep a private key beside the token file, **the manual token stays**: it is the only option measured as not cutting the worker's tools, and its cost is the person's time. B is the fallback if probe 1 or 2 fails and workers do not need the API.

**Not decided here.** Whether the app's private key may be reachable by the worker (this is what makes the 1-hour expiry workable); the owner decides, together with the Q20 known limit.
