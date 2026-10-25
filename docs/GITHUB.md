# GitHub governance

Public repository: [ndelanhese/reversed-engineering-icsee](https://github.com/ndelanhese/reversed-engineering-icsee). Maintainer and code owner: [@ndelanhese](https://github.com/ndelanhese).

## Contribution gates

- `main`: pull requests, one approving code-owner review, stale-review dismissal, resolved review threads, linear history, and the passing `macOS build and core tests` GitHub Actions check on an up-to-date branch.
- Ordinary force pushes and branch deletion are blocked.
- The administrator can bypass branch requirements **through a PR**. This lets a single maintainer integrate their own changes without pretending they received an independent approval. Direct pushes to `main` remain restricted.
- `v*` tags: only the administrator bypass can create, update or delete them. Treat published tags as immutable; issue a new version for corrections.
- Squash and rebase merges are enabled; merge commits and automatic PR approval by Actions are disabled. Merged branches are deleted automatically.

The JSON payloads in [`.github/rulesets`](../.github/rulesets) describe the active rulesets. GitHub does **not** apply those files automatically. An administrator must apply changes through repository settings or the REST API. The server's [Rules page](https://github.com/ndelanhese/reversed-engineering-icsee/rules) is authoritative.

## Automation and reports

- CI uses the ordinary `pull_request` event, a GitHub-hosted macOS runner, read-only repository permissions and an immutable checkout action SHA. Checkout does not persist credentials.
- Workflow runs from outside contributors require maintainer approval. Workflows do not receive camera credentials or signing identities.
- Allowed Actions are restricted to GitHub-owned actions. Dependabot checks action updates monthly. New external actions need an explicit settings review.
- GitHub secret scanning, push protection, vulnerability alerts and private vulnerability reporting are enabled. They supplement source review; they do not detect every possible credential or device identifier.
- Issues use structured templates and direct security reports to the private channel. No automated issue/PR messaging bot is installed.

## Source releases

Version `0.2.1` is the first public source snapshot. Tags use `vMAJOR.MINOR.PATCH`. There is no binary publishing workflow, certificate, notarization secret, package registry or bundled FFmpeg. Building locally uses only the checked-in source and the installed Apple toolchain. Before a future binary release, review signing, notarization and licenses for any redistributed binaries separately.
