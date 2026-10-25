# Security policy

## Supported version

Security fixes target the latest version on `main`. Older tags are historical snapshots, with no promised backports or response deadline.

## Report privately

Use [GitHub private vulnerability reporting](https://github.com/ndelanhese/cammac/security/advisories/new). Include the affected revision, trust boundary, minimal reproduction with dummy credentials, expected/observed behavior and relevant source locations. Do not publish a vulnerability as a regular issue or include personal footage, device identifiers or live credentials.

## Boundaries and known limitations

- This app expects cameras you own or are authorized to access, on a trusted LAN or VPN. It does not bypass authentication.
- RTSP and the supported legacy authentication format do not provide end-to-end transport encryption. A derived Sofia credential can be sensitive too. Never treat it as an anonymized password.
- Names, addresses and camera settings are stored in macOS preferences; they are not secrets encrypted by the app.
- Optional credentials are stored in macOS Keychain. During a connection, passwords, authenticated URLs and decoded frames exist in process memory, including FFmpeg's memory. The app does not promise memory zeroization or protection from a privileged local process.
- Authenticated playlists are passed over a pipe rather than process arguments or disk files. Decoder output is reduced to fixed diagnostic messages in memory. OS crash reports, external debugging tools and independently run FFmpeg commands are outside this guarantee.
- The app runs a separately installed FFmpeg binary with the user's privileges and is not App Sandbox enabled. Keep macOS and FFmpeg updated; untrusted camera streams cross a decoder boundary.
- Builds are ad-hoc signed, not notarized. No bundled FFmpeg, automatic updater, hosted relay, cloud authentication or built-in VPN exists.

The repository contains focused tests, not a complete security audit or a guarantee of safety against malicious streams. Never publish APKs, raw protocol traces, secrets or camera recordings as reproducers. Use small synthetic fixtures.
