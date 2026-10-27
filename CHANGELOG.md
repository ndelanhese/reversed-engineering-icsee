# Changelog

## Android 0.1.0-alpha.4

- Allocate live video surfaces only for cameras visible on the dashboard; release them when scrolled out of view.

## Android 0.1.0-alpha.3

- Keep the audio track active but muted during live video, avoiding session teardown on affected cameras.
- Refresh the native interface with light/dark themes, larger video, compact actions, and a scrollable recordings calendar.
- Silence native player logs that could contain authenticated stream URLs.


## 0.7.0 / Android 0.1.0-alpha.2

- Find local ONVIF cameras from macOS and Android; select a result to fill its address and ONVIF service automatically. Manual and advanced setup remain available.
- Keep discovery cancellable and inactive in the background; validate bounded network replies without sending credentials.
- Stop unresponsive Android RTSP players outside the UI thread so connection timeouts and Stop remain responsive.


## 0.6.2 — 2026-10-26

- Pause live decoding and release frames when all camera viewers are closed, minimized, fully covered or hidden, and during system sleep. Resume visible viewers using their in-memory authenticated session; explicit Stop stays stopped.
- Use a 480-pixel / 5 FPS menu-only preview and an 800-pixel / 5 FPS grid while preserving the existing 1280-pixel / 15 FPS limit for cinema, floating windows and fullscreen. Share one session per camera across viewers.
- Enable VideoToolbox with software fallback, bound FFmpeg thread counts and avoid per-frame board status updates.
- Close the live output reader before awaiting decoder diagnostics, preventing FFmpeg shutdown from hanging on a full JPEG pipe.
- Add native energy regressions using synthetic RTSP video, including hover, camera selection and window/sleep transitions.

## 0.6.1 — 2026-10-26

- Focus the menu bar preview on its camera selector and larger video; remove action rows, status text and the footer.

## 0.6.0 — 2026-10-26

- Add local SD-card calendar, camera-time daily history, channel/stream selection and a recording timeline.
- Download recordings into a private cache, with explicit completion, progress, cancellation and incomplete-transfer rejection.
- Play native H.264/HEVC movies with seek, speed, previous/next and supported G.711 audio converted to AAC.
- Export original camera files, complete movies and keyframe-aligned intervals without modifying the card.
- Handle rounded fractional frame rates and bounded camera-file EOF padding; verify a real five-minute HEVC/G.711 recording through native conversion and all-frame decode.
- Preserve camera-time gaps and disclose estimated frame/audio timing.
- Delete failed playback cache immediately and clean orphaned process caches at launch. Only explicit Save exports persist; original export can download again after a playback failure.
- Validate every decoded video frame before publishing a native movie; test corruption, cancellation, query pagination and independent live-session lifetime.

## 0.5.0 — 2026-10-25

- Add native ONVIF movement, Stop, profile selection, presets and camera-provided image controls.
- Add authenticated DVRIP discovery and structured local settings with conflict-safe writes and readback verification.
- Reuse active video credentials in memory and preserve legacy profiles with configurable control-port defaults.
- Show per-feature authentication/transport failures and protect unsaved drafts during navigation and reload.
- Wait for pending movement Stop and acknowledged restart connection holds before normal Quit.
- Add synthetic protocol/model/native lifecycle fixtures; validate bounded ONVIF commands and reversible brightness edits on two owner-controlled cameras.

## 0.4.0 — 2026-10-25

- Add an original menu bar icon and native hover preview using the existing camera stream.
- Save a default preview camera, selectable from the preview or the camera menu.
- Support click-to-pin, connection controls, floating windows and reopening the main window from the preview.
- Keep active cameras running when app windows close; explicit Quit stops all streams.
- Localize new controls in English and Brazilian Portuguese and test background scene reopening.

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
