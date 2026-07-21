# forge-azure

Azure DevOps backend for [Forge](https://github.com/magit/forge), using the
Azure DevOps REST API (api-version 7.1).

## Features

Pull requests only:

- Pulling pull requests with their comments into Forge's database
  (`forge-pull`, `forge-add-repository`)
- Checking out pull requests locally (`forge-checkout-pullreq`,
  `forge-branch-pullreq`)
- Creating pull requests, including drafts (`forge-create-pullreq`)
- Commenting, editing and deleting comments
- Approving (vote 10) and requesting changes (vote −5, "waiting for
  author"); a non-empty post buffer is additionally posted as a comment
- Adding and removing reviewers
- Completing (merging) with all four merge strategies (merge, squash,
  rebase, rebase+merge), abandoning and reactivating
- Editing title/description, toggling draft status
- `forge-browse-*` commands

Not supported:

- **Work items** (Azure's equivalent of issues). They belong to a
  project, not a repository, so every repository in a project would
  list the same "issues".
- Notifications, forking, and checking out pull requests from forks.

## Installation

With `use-package` and the built-in `:vc` keyword (Emacs 30+):

```elisp
(use-package forge-azure
  :vc (:url "https://github.com/dakra/forge-azure" :rev :newest)
  :after (forge))
```

Loading the package registers `dev.azure.com` in `forge-alist` and
installs the advices described below.

## Setup

Tell Forge your username (used to recognize you in topic lists, and in
PAT mode to look up the access token):

```
git config --global azure.user USERNAME
```

Then, in a repository cloned from Azure DevOps,
`M-x forge-add-repository`.

### Entra ID (Azure CLI, default)

Requests authenticate with a Microsoft Entra ID access token acquired
through the [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/):
install `az`. Tokens are cached for about an hour per host and
refreshed automatically shortly before they expire. The token is
issued for the active tenant/subscription, which you can switch with
`az account set`. When the CLI reports that logging in is required
(never logged in, or the login expired), forge-azure runs `az login`
for you after a confirmation prompt; Emacs blocks until the login
completes in your browser. Set `forge-azure-az-login` to `t` to skip
the prompt, or to `nil` to never run `az login` and fail with a
`user-error` instead.

The login must be completable in the browser: `az login` runs as a
background process that cannot answer terminal prompts, so in
environments where az falls back to the device-code flow or asks you
to select a subscription on the terminal (disable that picker with
`az config set core.login_experience_v2=off`), Emacs appears to hang
until the process is killed. Set `forge-azure-az-login` to `nil` and
log in from a terminal in such environments.

If GUI Emacs cannot find `az`, set `forge-azure-az-executable` to its
full path.

### Personal access token

Alternatively, set

```elisp
(setq forge-azure-auth 'pat)
```

create a [personal access token](https://learn.microsoft.com/en-us/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate)
with at least the **Code (Read & Write)** scope, and store it with
auth-source:

```
machine dev.azure.com login USERNAME^forge password TOKEN
```

After changing the entry, `M-x auth-source-forget-all-cached`.

Both remote url formats are supported:

```
https://ORG@dev.azure.com/ORG/PROJECT/_git/REPO
git@ssh.dev.azure.com:v3/ORG/PROJECT/REPO
```

The legacy `ORG.visualstudio.com` urls are not; point your remote at
the equivalent `dev.azure.com` url instead. Forge treats the
`ORG/PROJECT` pair as the repository's "owner".

## Caveats

- Azure only provides `refs/pull/{id}/merge` refs (a merge-preview
  commit, absent while a pull request has conflicts). They are only
  used as a fallback for closed pull requests; for open ones the
  source branch is checked out directly.
- The API cannot filter pull requests by update time, so `forge-pull`
  re-fetches all active pull requests every time (two requests per
  pull request). Edits to comments on closed pull requests are only
  picked up by `forge-pull-topic`.
- Reviewer lists may include Azure DevOps groups; they appear like
  users.

## How it works

Forge has no public interface for adding API backends, so this package
necessarily implements Forge's internal generic functions
(`forge--pull`, `forge--submit-*`, …) for a new
`forge-azure-repository` class, and additionally advises four
functions whose behavior is hard-coded per forge:

- `forge--split-forge-url` — normalize the three-segment
  org/project/repo remote urls into owner/name
- `forge-approve-pullreq`, `forge-request-changes` — lift the
  "Github only" guard
- `forge-select-merge-method` — offer Azure's merge strategies

ghub itself is not modified: requests authenticate with headers built
by this package — `Authorization: Bearer <token>` with an Entra ID
access token from the Azure CLI, or `Authorization: Basic
base64(user:PAT)` depending on `forge-azure-auth`.

**A Forge update may break this package**; it is developed against the
Forge version in `Package-Requires`.

## Development

```
make lisp   # byte-compile (ELIB=... to point at forge/ghub checkouts)
make test   # run offline ERT tests
```
