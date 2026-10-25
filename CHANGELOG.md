# Changelog

## 0.3.3 — 2026-10-25

- Use English for release notes and DMG installation instructions, with a link to the separate Brazilian Portuguese guide.
- Keep the app interface following macOS language preferences.
- Bring the Brazilian Portuguese credential-storage guide up to date.

## 0.3.2 — 2026-10-25

- Preserve saved credentials when Keychain access is denied or cancelled.
- Add a persistent machine-local signing identity that local builds can reuse across rebuilds.
- Document ad-hoc update reauthorization and the one-time local-signing migration.

## 0.3.1 — 2026-10-25

- Follow macOS preferred app language, including per-app overrides, using native English and Brazilian Portuguese resources with an English fallback.
- Localize controls, dynamic camera labels, diagnostics, accessibility text, tooltips and the local-network permission description.
- Preserve camera names, connection settings and saved credentials when the app language changes.
- Add checks for preferred-language ordering, regional variants, unsupported-language fallback, typed interpolation and rendered SwiftUI in both languages.

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
