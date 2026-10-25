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

- CI uses the ordinary `pull_request` event, a GitHub-hosted macOS runner, read-only repository permissions and immutable action SHAs. Checkout does not persist credentials. It checks the core, builds the app and pinned FFmpeg, validates DMG/ZIP packages and uploads the verified files as workflow artifacts.
- Workflow runs from outside contributors require maintainer approval. Workflows do not receive camera credentials or signing identities.
- Allowed Actions are restricted to GitHub-owned actions. Dependabot checks action updates monthly. New external actions need an explicit settings review.
- GitHub secret scanning, push protection, vulnerability alerts and private vulnerability reporting are enabled. They supplement source review; they do not detect every possible credential or device identifier.
- Issues use structured templates and direct security reports to the private channel. No automated issue/PR messaging bot is installed.

## Releases

Version `0.2.1` is the first public source snapshot; `0.3.0` adds installable DMG/ZIP assets. Protected tags use `vMAJOR.MINOR.PATCH` and must match `version.json`.

The tag-triggered Release workflow reuses CI packaging. Only after that job succeeds does a separate Ubuntu publishing job receive `contents: write`. It downloads artifacts from that same run, creates a draft release with app archives, checksums, source and metadata, then publishes it. It never executes the downloaded binaries. PR workflows cannot reach this publishing job.

App and FFmpeg use ad-hoc signatures. No certificate, notarization credential, package registry or automatic updater is configured. Source matching the bundled LGPL decoder is included as a release asset. [Release maintenance](RELEASING.md) documents reproducibility, checks and first-launch limitations.
