# Android port

The owner approved Rust protocol code, a native Kotlin interface and LibVLC playback on 2026-10-26. Implement Android alongside macOS in this repository; keep the installed Mac app, source and identities unchanged.

## Contract

- Deliver an installable signed APK, original icon, reproducible build instructions and GitHub CI artifacts. Android 9/API 28 minimum; arm64 physical devices and x86_64 emulator QA. Target API 37 and request local-network permission before connections on Android 17.
- Camera profiles: add, edit, rename, delete, explicit connect/stop; live grid and enlarged video. Use existing RTSP paths and bounded Sofia authentication fallback. Hardware decoding when supported, release hidden players and connections, no background streaming service. Keep credentials in memory unless optional encrypted persistence is selected.
- Controls: ONVIF advertised profiles/PTZ/presets/imaging; existing discovered DVRIP setting catalog with scalar editing, explicit confirmation, fresh-read conflict detection and verified readback. Never invent support. No account changes, storage formatting, reset or firmware upgrade.
- Recordings: calendar/day/file queries in camera wall-clock time, previous-day overlaps, bounded pagination and partial-result disclosure; completed downloads, local seeking/speed, previous/next, original/movie/interval export. No card deletion. Preserve existing wire/session/media validation and cancellation rules.
- Playback downloads live only in app-private temporary storage; cancel, change selection, leave playback or fail preparation deletes them. Startup prunes abandoned playback cache. Only explicit Android document-picker exports survive. Export cancellation must not preserve an unintended partial export.
- English and Brazilian Portuguese follow Android app/system language. English documentation links to Portuguese. Camera names are never translated.
- Application ID `io.github.ndelanhese.reversedicsee`, distinct from the vendor app. Keep a stable private signing key outside Git. No APK/vendor SDK/decompiled code, credentials, footage or private endpoints in source or logs. Disable credential backup. Do not reuse the owner's old vendor/extraction key.

## Implementation choices

`Android/native` is an independent Rust crate for endpoint/auth helpers, bounded DVRIP framing/sessions, history/downloads, structured setting patches and ONVIF SOAP. A small synchronous JSON JNI dispatcher runs on a bounded Android worker executor, never on the UI thread. Cancellation tokens are independent of the worker so lifecycle changes can abort transfer promptly. Per-operation camera sessions close at completion; playback's query/control and media sockets are independent. LibVLC supplies RTSP H.264/HEVC and native surface playback rather than transcoding every live frame to JPEG. Rust parses downloaded XM framing; Android MediaMuxer writes a seekable MP4 from validated compressed samples, preserving disclosed timing/audio limits.

`Android/app` owns native Android views, camera storage, encrypted credential blobs using AES-GCM keys in Android Keystore, lifecycle, document pickers and video surfaces. UI actions have generation guards. Stale worker completions may delete their own temporary work, never update a new screen. PTZ uses device-side timeout and best-effort Stop on cancellation. Settings writes are not automatically retried.

JNI input/output is bounded JSON with fixed safe error messages; credentials are never returned in operation results. Rust panic boundaries never unwind into the JVM. Dependencies and Gradle downloads are pinned; native libraries must pass 16-KiB ELF/ZIP alignment checks. APKs are verified with Android build tools. Build tooling JDK/SDK/NDK is not a Java runtime bundled with the app; no application Java source is planned.

## Validation and release

Port protocol fixtures rather than using private recordings. Rust tests exercise malformed packets, wrong sessions/sequences, partial downloads, date/pagination boundaries, auth and structured edit conflicts. Android tests exercise credential round trips, lifecycle cleanup and explicit exports. Emulator smoke tests cover empty launch/profile validation/playback against a synthetic peer where possible. Physical camera and hardware-decoder compatibility remain device tests; do not label emulator success as physical-camera validation.

Build and test macOS using existing commands to prove the additive port did not alter it. Android preview APK may be delivered for device testing before all firmware features are validated; clearly state its status. Publish a stable release only with the retained release certificate, source/notices for linked libraries and checksums. No Play Store submission or VPN setup is requested. macOS menu-bar behavior and floating desktop windows are not Android features; Android uses its own full-screen player.

## Sources checked

- [Media3 RTSP supported codecs](https://developer.android.com/media/media3/exoplayer/rtsp) (H.264 documented; insufficient as sole HEVC RTSP path).
- [VideoLAN LibVLC Android](https://github.com/videolan/vlc-android) (engine and LGPL notices; use engine, not GPL application source).
- [Android local network access](https://developer.android.com/privacy-and-security/local-network-permission).
- [Android Keystore](https://developer.android.com/privacy-and-security/keystore).
- [16-KiB native alignment](https://developer.android.com/guide/practices/page-sizes).
