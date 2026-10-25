# Security policy

## Supported version

Security fixes target the latest version on `main`. Older tags are historical snapshots, with no promised backports or response deadline.

## Report privately

Use [GitHub private vulnerability reporting](https://github.com/ndelanhese/reversed-engineering-icsee/security/advisories/new). Include the affected revision, trust boundary, minimal reproduction with dummy credentials, expected/observed behavior and relevant source locations. Do not publish a vulnerability as a regular issue or include personal footage, device identifiers or live credentials.

## Boundaries and known limitations

- This app expects cameras you own or are authorized to access, on a trusted LAN or VPN. It does not bypass authentication.
- RTSP and the supported legacy authentication format do not provide end-to-end transport encryption. A derived Sofia credential can be sensitive too. Never treat it as an anonymized password.
- Names, addresses and camera settings are stored in macOS preferences; they are not secrets encrypted by the app.
- Optional credentials are stored in macOS Keychain. During a connection, passwords, authenticated URLs and decoded frames exist in process memory, including FFmpeg's memory. The app does not promise memory zeroization or protection from a privileged local process.
- Authenticated playlists are passed over a pipe rather than process arguments or disk files. Decoder output is reduced to fixed diagnostic messages in memory. OS crash reports, external debugging tools and independently run FFmpeg commands are outside this guarantee.
- The app runs FFmpeg as a separate process with the user's privileges and is not App Sandbox enabled. Binary releases prefer the bundled decoder; development builds can use an installed decoder. Keep the app, macOS and any external FFmpeg updated; untrusted camera streams cross a decoder boundary.
- Builds are ad-hoc signed, not Developer ID signed or notarized. Release instructions explain Apple's per-app first-launch approval; no installer disables Gatekeeper. No automatic updater, hosted relay, cloud authentication or built-in VPN exists.
- Release downloads include SHA-256 checksums and exact FFmpeg source/build metadata. Checksums detect accidental corruption but are not a substitute for a trusted publisher identity. A new decoder build requires a new app release; users must install updates manually.

The repository contains focused tests, not a complete security audit or a guarantee of safety against malicious streams. Never publish APKs, raw protocol traces, secrets or camera recordings as reproducers. Use small synthetic fixtures.

## Synthetic protocol fixtures

`Tests/CoreSelfTest.swift` uses documentation-only addresses, a synthetic user, deliberately malformed input and known Sofia transformation vectors. Its empty-string vector is not a credential extracted from a device. An initial GitGuardian alert pointed to the corresponding literal query assertion in commit `d628238`; that occurrence is a test-data false positive. Classify that specific historical incident as **False positive (not a secret)** rather than disabling a detector or excluding the test directory. The current test keeps its independently checked vector separate from the expected query string.
