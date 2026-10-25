# Contributing

Issues and pull requests are welcome in English or Brazilian Portuguese. This is an early, personally maintained project; there is no support SLA.

## Before opening an issue

- Read the requirements and limitations in the README.
- For camera compatibility, provide manufacturer/model, firmware version if known, macOS version, Reversed engineering Icsee version and the app's safe error message. State whether standard RTSP or the compatibility retry works.
- Replace network addresses with documentation examples such as `192.0.2.10` or `camera.example`.
- Do not attach passwords, credential-bearing URLs, serial numbers, cloud IDs, personal footage, APKs, firmware, raw decoder logs or packet captures.
- Report vulnerabilities privately using [SECURITY.md](SECURITY.md).

## Pull requests

1. Fork the repository and branch from `main`.
2. Keep changes focused. Explain the user-visible problem, resulting behavior, and how you verified it.
3. Run `python3 test.py --core-only` and `python3 build.py` on macOS. For window changes, also run `python3 test.py --interactive` in a desktop session.
4. Add a focused test when changing protocol parsing, credential handling or lifecycle behavior. Tests must use synthetic inputs and must not connect to real cameras.
5. Update relevant documentation and the changelog when behavior changes.
6. Submit a PR. Passing CI and code-owner review are required for normal merges; the maintainer controls final integration.

GitHub rules require a PR, one approving code-owner review, resolved review conversations and the `macOS build and core tests` check on an up-to-date branch. Stale approvals are dismissed. `main` blocks force pushes and deletion, and merges use a linear history. The repository administrator retains an explicit bypass through pull requests for maintenance of this single-maintainer project; it is not an approval by an independent reviewer. Release tags `v*` are restricted to administrators and protected against ordinary updates/deletion. Current server settings are visible under the repository's **Rules** page and documented in [GitHub governance](docs/GITHUB.md).

## Scope and code style

Prefer SwiftUI/AppKit and the standard library. Keep one shared session per camera and preserve saved profile IDs and Keychain access. Avoid adding a dependency for behavior the platform already supplies. App UI currently uses Brazilian Portuguese; keep messages consistent and avoid exposing implementation diagnostics to users.

No vendor code, vendor binaries, extracted resources, private research dumps or real device data may be added. Describe observations in your own words and separate what was tested from what was inferred. Third-party additions need a source and a compatible license.

AI-assisted contributions are welcome. Authors remain responsible for the patch, its provenance and its verification. Name relevant tools and describe actual checks; do not substitute generated claims for test evidence. A CLA or DCO sign-off is not required. Contributions are accepted under the repository's MIT license.
