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
- Auto-complete (merge automatically once all branch policies are
  satisfied): turning it on for the pull request being created
  (`forge-azure-toggle-auto-complete`, bound to `C-c C-a` in the post
  buffer), and setting or canceling it on existing pull requests
  (`forge-azure-set-auto-complete`, `forge-azure-cancel-auto-complete`).
  Open pull requests show their auto-complete state — merge strategy,
  whether the source branch is deleted, and who set it — as an
  "Auto-complete:" header in the pull request buffer.
  The option `forge-azure-auto-complete` turns it on by default for
  new pull requests, e.g. per repository in `.dir-locals.el`:

  ```elisp
  ((nil . ((forge-azure-auto-complete
            . ((mergeStrategy . "squash") (deleteSourceBranch . t))))))
  ```
- Editing title/description, toggling draft status
- Work items linked to a pull request: pulled and shown as a
  clickable "Work items:" header in the pull request buffer,
  linking/unlinking on existing pull requests
  (`forge-azure-link-work-item`, `forge-azure-unlink-work-item`),
  and attaching work items when creating a pull request
  (`forge-azure-set-work-items`, bound to `C-c C-w` in the post
  buffer)
- Pipeline status: the build-validation branch policies evaluated for
  each open pull request are pulled with it and shown as a clickable
  "Pipelines:" header in the pull request buffer and as a rollup
  glyph before the title in topic lists — `✓` all approved, `✗` any
  failed or expired, `●` any queued or running, plus an
  approved/total count when there is more than one pipeline.
  `forge-azure-browse-pipeline` (also `-p` in `forge-topic-menu`)
  opens a build's results page in the browser. Set
  `forge-azure-pull-pipeline-status` to `nil` to skip pulling the
  status.
- The post menu (`forge-post-menu`, `C-c C-e` in the post buffer) has
  an "Azure" column showing the work items, auto-complete state and
  draft flag of the pull request being created, with keys to change
  them
- `forge-browse-*` commands

Not supported:

- **Work items as topics of their own** (Azure's equivalent of
  issues). They belong to a project, not a repository, so every
  repository in a project would list the same "issues"; they are not
  modeled as Forge issues. Only their links to pull requests are
  mirrored (see above).
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
  re-fetches all active pull requests every time (four requests per
  open pull request, plus one batched title request per pull for the
  linked work items; set `forge-azure-pull-work-items` and
  `forge-azure-pull-pipeline-status` to `nil` to skip work items and
  pipeline status and get back to two). Edits to comments on closed
  pull requests are only picked up by `forge-pull-topic`.
- Reviewer lists may include Azure DevOps groups; they appear like
  users.

## How it works

Forge has no public interface for adding API backends, so this package
necessarily implements Forge's internal generic functions
(`forge--pull`, `forge--submit-*`, …) for a new
`forge-azure-repository` class, and additionally advises five
functions whose behavior is hard-coded per forge:

- `forge--split-forge-url` — normalize the three-segment
  org/project/repo remote urls into owner/name
- `forge-approve-pullreq`, `forge-request-changes` — lift the
  "Github only" guard
- `forge-select-merge-method` — offer Azure's merge strategies
- `forge--format-topic-title` — prefix titles in topic lists with the
  pipeline rollup glyph

ghub itself is not modified: requests authenticate with headers built
by this package — `Authorization: Bearer <token>` with an Entra ID
access token from the Azure CLI, or `Authorization: Basic
base64(user:PAT)` depending on `forge-azure-auth`.

Work-item links, auto-complete state and pipeline status are stored
in `azure-workitem`, `azure-pullreq` and `azure-pipeline` tables
owned by this package inside Forge's database, created lazily on
first use. Pipeline status comes from the policy evaluations
endpoint (the build-validation branch policies, which are the only
mechanism that runs pipelines for pull requests on Azure Repos),
which only exists as a preview api-version. Forge's
`forge-pullreq` schema cannot be extended, and the tables
deliberately have no foreign key on the pullreq table, because closql
rewrites topic rows with `insert or replace`, whose implicit delete
would cascade. Work-item requests go to the organization-scoped
`_apis/wit` endpoints. Linking and unlinking use JSON-patch requests,
for which the `Content-Type` header pushed unconditionally by
`ghub--headers` is temporarily overridden with
`application/json-patch+json`.

**A Forge or ghub update may break this package**; it is developed
against the Forge version in `Package-Requires`.

## Development

```
make lisp   # byte-compile (ELIB=... to point at forge/ghub checkouts)
make test   # run offline ERT tests
```
