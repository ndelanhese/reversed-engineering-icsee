# Changelog

## 0.3.0 — 2026-10-25

- Added an original native app icon in Finder, Dock and all builds, with a reproducible artwork generator.
- Added ready-to-run Apple Silicon DMG and ZIP releases with a bundled standalone FFmpeg 9.0.2 LGPL decoder.
- Included third-party notices, exact FFmpeg source, build configuration and SHA-256 checksums alongside downloads.
- Added offline H.264/HEVC decoding and dependency checks for staged, ZIP-extracted and DMG-mounted app bundles.
- Added tag-triggered GitHub release publishing after the same package checks required by CI.
- Documented installation, ad-hoc signing and the first-launch Gatekeeper flow; notarization and automatic updates remain unavailable.

## 0.2.2 — 2026-10-25

- Renamed the project, repository and native application to **Reversed engineering Icsee**.
- Updated source paths, build output, documentation, issue templates and GitHub links.
- Kept the original preferences identifier and Keychain service so existing camera profiles and saved credentials remain available.
- Clarified the synthetic empty-password test vector that triggered a GitGuardian false positive; kept protocol assertions without a literal credential pair or broad scanner exclusions.

## 0.2.1 — 2026-10-25

First public source release.

- Native multi-camera RTSP viewer for macOS on Apple Silicon.
- Cinema mode, floating resizable windows and native fullscreen, sharing one session per camera.
- Camera renaming, editable connection settings and optional Keychain credentials.
- One Sofia-style authentication compatibility retry, bounded decoder diagnostics and stream timeout detection.
- New installations start with no cameras; existing saved profiles are preserved.
- Documented research provenance, privacy boundaries, build instructions and contribution policy.
- Added CI-friendly core test mode and repository governance files.

Earlier development builds were local prototypes and were not public releases.
