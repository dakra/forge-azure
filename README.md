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

Tell Forge your username (only used to look up the access token):

```
git config --global azure.user USERNAME
```

Create a [personal access token](https://learn.microsoft.com/en-us/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate)
with at least the **Code (Read & Write)** scope, and store it with
auth-source:

```
machine dev.azure.com login USERNAME^forge password TOKEN
```

Then `M-x auth-source-forget-all-cached` and, in a repository cloned
from Azure DevOps, `M-x forge-add-repository`.

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

ghub itself is not modified: requests authenticate with
`Authorization: Basic base64(user:PAT)` headers built by this package.

**A Forge update may break this package**; it is developed against the
Forge version in `Package-Requires`.

## Development

```
make lisp   # byte-compile (ELIB=... to point at forge/ghub checkouts)
make test   # run offline ERT tests
```
