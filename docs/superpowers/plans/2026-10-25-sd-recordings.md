# SD-card Recordings Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for disjoint backend/media tasks and independent review. The user explicitly requested implementation; continue without another permission round.

**Goal:** Browse, play, seek and export local camera-card recordings in the native Mac app.
**Architecture:** A dedicated DVRIP recording client and bounded XM-media parser feed private local native movies. A separate camera recordings window/model owns AVPlayer and cache/download lifetime; live sessions and existing controls retain their current ownership.
**Tech Stack:** Swift6, Network, Foundation, AVFoundation/CoreMedia, SwiftUI/AppKit; macOS14+, arm64; no new runtime dependencies.
**Spec:** docs/superpowers/specs/2026-10-25-sd-recordings-design.md

## Global constraints

Preserve local.CamMac identity/preferences/Keychain/local signer and menu-bar live sessions. Camera-local wall-clock timestamps must not shift with Mac timezone. No secrets/private media/camera addresses/vendor source in Git, argv or logs. Bounded authenticated read/download operations, explicit EOF, no destructive commands or partial-file success. English/pt-BR resources follow macOS; public docs/releases English with pt-BR link. Reuse existing transport patterns without loosening settings-operation restrictions.

## Review focus

1. Missing explicit EOF, disconnection and rounded FileLength must never produce a complete video.
2. Equal-start-time page boundaries must not drop recordings or loop indefinitely.
3. Day changes/selection changes/close/Quit must ignore stale results and close/remove downloads; live view remains independent.
4. Malformed XM lengths, changing codecs/parameter sets, bad clocks and absent/unsupported audio must remain bounded and visible.
5. Timeline gaps, midnight/day bounds and host timezone changes must preserve camera-local recorded times.

## Task1 — Recording protocol client and typed history (worker)

Files: new Sources/CameraRecordings/RecordingTypes.swift, DVRIPRecordingClient.swift; Tests/RecordingProtocolTest.swift and synthetic peer fixtures as needed. May expose DVRIPTCPTransport as internal in its existing file; do not change settings behavior.

Interfaces: CameraRecordingTime validated wall-clock type with comparable arithmetic/date representation; CameraRecording stable opaque id/fileName, begin/end, channel/stream, estimatedBytes; RecordingCalendar day set; RecordingListing records plus completeness/warnings. Actor DVRIPRecordingClient(host:port:username:password:), connect(), disconnect(), cameraTime(), storage(), calendar(year:month:), recordings(day:channel:substream:), download(recording:to:progress:) async throws. Finalize exact signatures/types with root before implementation. Download writes raw XM data only to supplied private URL; progress is Sendable and bounded; returns only after explicit EOS. Root owns media conversion.

- [ ] RED tests for clock validation/masks/pagination and bounded preceding-window query for files crossing midnight, then implement queries and safe errors. Unsupported calendar means unknown, with daily-query fallback.
- [ ] RED tests for claim/download framing, split/coalesced media, empty/1423/endflag EOF, sequence/session mismatch, deadlines, no partial retry, cancellation and byte limits; implement.
- [ ] Run focused Swift6 tests with synthetic localhost peers; report protocol choices and remaining compatibility limits. Do not touch live cameras, Keychain, root app integration or commit other workers' files.

## Task2 — XM parser and native movie conversion (worker)

Files: new Sources/CameraRecordings/RecordingMedia.swift and RecordingMovieWriter.swift; Tests/RecordingMediaTest.swift. Pure media types are independent from Task1: frame carries kind/codec, payload, keyframe time components/FPS/dimensions. Converter consumes raw private file and returns a validated movie/result with duration/audio/timing notices. Finalize API with root before implementation.

- [ ] RED tests for chunk splits/coalescing, overflow/truncation, keyframe clocks and FPS, parameter sets, G711 vectors and discontinuities; implement parser with bounded memory.
- [ ] Native synthetic H264/HEVC fixture conversion verifies valid duration, AVPlayer-compatible samples, accurate declared cadence and audio presence/explicit unsupported status. Test cancellation/finalization removes partial outputs.
- [ ] Implement AVAssetWriter passthrough H264/HEVC and supported audio. No new FFmpeg dependency/config changes or copied upstream implementation.

## Task3 — Native history/player window and integration (root)

Files: new CameraRecordingsModel.swift, CameraRecordingsView.swift and timeline/calendar components as needed; modify CameraWindows/Board/Video/MenuBar/Forms and locale resources. Native reusable credential sheet and memory credentials; one recordings model/window per camera. Separate playback and raw/movie cache. Calendar/day navigation, typed channel/stream selection, daily timeline/list, selectable wall time, native player seek/rates, previous/next, download cancel and explicit original/movie/interval export.

- [ ] Add focused model/window fixtures for stale async results, gaps, cache cleanup and live lifetime.
- [ ] Integrate close/remove/edit/disconnect-all/Quit without breaking control Stop/restart wait.
- [ ] Build and run targeted protocol/media/model fixtures then full existing interactive suite once source is stable.

## Task4 — Review, real validation and delivery (root + independent reviewers)

- [ ] Review backend/media tasks independently before accepting dependencies; resolve material findings.
- [ ] Read-only live history/download/playback using normal native credentials when possible; record tested scope and never alter card contents.
- [ ] Update guides/provenance/changelog/version, verify signed portable bundle and secret scan.
- [ ] Install stable-signed local build preserving profiles/Keychain; protected PR, required CI, merge and publish release with five expected artifacts.
