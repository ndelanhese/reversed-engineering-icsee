# Local SD-card recordings

## Intent

The owner requests the iCSee SD-card history workflow in the native Mac app: inspect recordings by day/time, play recorded video, seek forward/backward, change playback speed and manage downloaded videos. They explicitly requested implementation in the existing app. Follow the existing autonomous implementation/review/install/release workflow.

## User experience

Each camera gains **Recordings…** in its card, enlarged views and menu preview. One window per camera contains a calendar marking recorded days, channel/stream selection, camera-local clock/status, daily timeline and recording list. Selecting a recording downloads that file to a private temporary cache with progress/cancel, validates its media and opens a native AVPlayer. Playback supports pause/resume, seeking, previous/next recording and supported local rates. Timeline clicks select the containing clip and seek to the requested recorded time; gaps remain visible and are never silently treated as continuous footage.

Export supports the selected recording and a chosen interval within it through a native save panel. Interval passthrough cuts align to decodable keyframes and show actual exported bounds; do not promise frame-exact trimming. Exports contain no credentials. Explicitly distinguish device contents, private downloaded cache and exported files. The owner confirmed consult/play/export only. Remote/cloud history, storage formatting and camera-recording deletion are excluded. No destructive camera operation is used for tests.

## Protocol and timing

Prior device observations advertise no ONVIF recording/search/replay services. Implement DVRIP local queries and download using independently reconstructed protocol facts. Calendar uses OPSCalendar1446; daily listing uses OPFileQuery1440 with bounded pagination/deduplication and explicit partial/error results. Preserve channel, stream and opaque file identifiers returned by the camera. StorageInfo1020 and OPTimeQuery1452 are read-only status queries.

Device timestamps contain camera-local wall-clock components without an offset. Preserve them as validated Gregorian components, using a fixed UTC calendar only as an internal arithmetic representation. Label UI **Camera time** and never silently reinterpret history in the Mac timezone. Prefer the reported device clock for today's date. Do not claim a timezone offset that the device has not supplied.

Download uses a separate session/transport from existing live video and settings. Authenticate a control session, claim a media socket and request a by-name download; support a documented single-socket compatibility path only after an explicit unsupported claim, before bytes are received. Correlate session/sequence/message, bound frames/bytes/deadlines, serialize control requests/keepalive and cancel both sockets. No transport retry after a partial download. Explicit end-of-stream is required; FileLength is rounded kilobytes, not exact size. Failed downloads never become completed cache entries.

XM media has a second framing layer crossing DVRIP packet boundaries. Parse bounded key/P/audio/info frames. Keyframes carry whole-second packed camera timestamps, dimensions, codec and declared FPS; interpolate intervening frame times from that FPS and re-anchor to subsequent keyframes. Reject invalid clocks/FPS, malformed or truncated data; identify discontinuities instead of guessing 25 FPS. This protocol cannot establish true per-frame variable-rate timestamps.

## Native media implementation (builder decision)

Use a native AVAssetWriter passthrough movie for H.264/HEVC, preserving parameter sets and calculated recording timestamps, and native AVPlayer for seeking/rate/audio. Decode supported G.711 audio to PCM and encode with the platform audio encoder; disclose inferred audio alignment because recovered absolute audio timestamps are absent. Unknown audio must be disclosed, never silently represented as a complete audiovisual export. Movie results carry first decodable camera time and camera/movie mapping segments; seeking must not assume the queried BeginTime equals the first decoded frame. Keep timestamps monotonic, exposing quantization/gaps and rejecting unsupported reordered/config-changing streams. Delete playback downloads when conversion fails. An explicit original-file Save may make a new download without native conversion; its private scratch files are removed afterward. Successful playback data remains private and temporary, and is removed on selection changes, window close or Quit. On startup, remove only this app’s owned, non-symlink cache directories whose process no longer exists. Do not expand bundled FFmpeg solely to add a movie muxer.

## Preservation and privacy

- Swift6, macOS14+, Apple Silicon; existing standalone FFmpeg/live path unchanged.
- Preserve local.CamMac preferences, local.CamMac.camera Keychain and stable local signing identity.
- Reuse video credentials in memory or the existing explicit credential sheet; never dump Keychain, include credentials in argv/logs or persist passwords elsewhere.
- Temporary media uses a randomly named, mode0700 directory and mode0600 files; only explicit user-selected exports survive cleanup. Bounded disk/byte limits, cancellation and app/window shutdown remove incomplete files and release handles/tasks.
- Live cameras remain active in the menu bar when windows close. Closing a recordings window only stops its playback/download. Disconnect-all, removal/configuration changes and normal Quit clean up recordings without breaking pending control Stop/restart cleanup.
- English and pt-BR UI follow macOS settings. Public docs/releases use English with a separate pt-BR link.

## Evidence and validation

Private REA APK evidence and primary protocol references remain outside Git. Publish protocol facts/provenance links, synthetic fixtures and implementation only. Test wall-clock boundaries/leap years, calendar masks, inclusive pagination/same-time records, malformed frames, authentication/EOF/partial download, cancellation, native conversion duration/seek/rate, audio handling, cache cleanup, stale async results, live-session independence and normal Quit.

Validate read-only history and playback against owner cameras when the app can obtain local credentials through its normal UI/Keychain flow. Never use delete/format/recording-setting changes to verify browsing. Independent review, appropriate tests, signed bundle checks, local installation preserving profiles/signer and protected PR/release complete delivery.
