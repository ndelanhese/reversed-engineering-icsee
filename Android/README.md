# Android

[Português brasileiro](README.pt-BR.md) · [Project](../README.md)

Native Android companion to the macOS app: Rust camera protocols, Kotlin Android interface and LibVLC hardware-capable video playback. It connects directly to cameras on a trusted LAN or an existing VPN. No iCSee cloud account, Android vendor SDK, telemetry or Mac server is required.

## Install

The first Android build is **0.1.0-alpha.1**. Download its signed `.apk` from the project's **Android preview** GitHub release, allow installation from your browser/file manager when Android asks, then open **Reversed engineering Icsee**. It installs alongside the original iCSee app.

- Android 9/API 28 or later; arm64 phones and x86_64 devices. One APK includes both architectures.
- Add the camera's local address, ports and channel. New profiles prefer substream to reduce bandwidth/decoder load; change it if needed.
- Connect with the camera's local username/password. Optional persistence encrypts credentials using an Android Keystore AES-GCM key. Device/cloud backups and autofill for these fields are excluded.
- Android 17 requires local-network permission; grant it when connecting. Firmware and the phone's video decoder determine compatibility.
- Android release certificate SHA-256: `c52e6545c9064b8da5389d3c410d15f3f2e36f69c3f9c360974aeb1a700c297f`. Updates signed with this same certificate retain app data. The vendor app's identity or extraction keystore is never reused.

## Features and limits

Camera profiles support adding, editing, renaming and removal. Live cards and enlarged views use native video surfaces, with no JPEG transcoding. Offscreen cards and paused activities release their players; there is no background camera service. App memory and decoding still cost resources while visible. Android RAM/CPU has not been measured on the owner's phone; macOS measurements are not Android measurements.

Use a camera's **⋯** menu for controls or recordings. Controls discover ONVIF profiles and advertised PTZ ranges, send bounded nudges with Stop, handle presets and imaging options, and provide the same bounded catalog of local DVRIP settings as macOS. Discovery is read-only; only returned sections appear. Scalar edits preserve types/structure, reject edited-field conflicts and verify readback. Sensitive fields and command/storage-init blocks stay read-only. Restart is a separate explicit action. Capabilities advertised by firmware are not a guarantee of physical support.

Recordings use camera wall-clock components, not an automatic phone-timezone conversion. Select dates, use recorded-day availability, the timeline or a time search, then choose a clip. Daily searches include the preceding day for midnight overlaps and disclose incomplete pagination. Channel/substream follow the camera profile. Storage information is available through the device settings catalog.

Playback first downloads a complete recording into private cache, validates its XM framing and compressed video, creates an MP4, and checks every video frame with Android MediaCodec. H.264/HEVC, optional supported G.711-to-AAC audio, seeking, speed, previous/next and 15-second jumps are provided. Full download and validation add latency. Codec changes, missing parameters, reordered video without timestamps and corrupt media remain errors; **Export original** retains the original source when conversion is unavailable. Timing is approximate because camera key timestamps are whole seconds; audio alignment is inferred from sample order.

Only explicit document-picker exports save lasting files: original XM, MP4 or a keyframe-expanded interval. Cancel, change selection, leave playback or preparation failure removes its private playback cache; startup also prunes abandoned cache. The document picker temporarily retains the active prepared clip while choosing an export destination. Failed exports attempt to remove their partial destination; an OS kill or document-provider failure can leave an explicitly selected destination incomplete. No recording is silently added to Downloads or the media library. No SD-card deletion or formatting is implemented.

The interface follows Android's English/Brazilian Portuguese system or per-app language. Firmware identifiers/settings names remain as supplied by the device. macOS menu-bar hover and desktop floating windows do not apply to Android. PiP, notifications/background streaming, cloud P2P and automatic updates are outside this first port.

## Build

Use macOS or Linux x86_64 with Python 3, Rustup, JDK 21 (JDK 17+ meets the Android plugin requirement), Android SDK and NDK. Install SDK packages with Google's SDK manager:

```sh
sdkmanager 'platforms;android-37.0' 'build-tools;37.0.0' 'ndk;29.0.14206865' 'platform-tools'
export JAVA_HOME=/path/to/jdk
export ANDROID_HOME=/path/to/android-sdk
python3 Android/build.py --sign
```

The Rust toolchain is pinned in `native/rust-toolchain.toml`. The build downloads checksum-verified Gradle 9.4.1 if `GRADLE_HOME` is unset, runs Rust/JVM tests and release lint, builds both native ABIs, verifies every ELF/ZIP native library's 16-KiB alignment, and checks the APK signature. Output: `dist/android/`. The phone needs no compiler, Java installation, Python, Rust or separate player app.

`--sign` creates/reuses a private signing identity under `~/.local/share/reversed-engineering-icsee/android-signing/`, outside Git. Keep that directory private and back it up to retain update compatibility. Passwords reach signing tools through environment variables, not arguments or logs. Building without `--sign` produces an **unsigned APK**, useful as a CI artifact but not directly installable. CI never receives the maintainer's private release key. Anyone building with their own key gets their own identity and cannot replace a differently signed installed app without uninstalling it.

## Validate

```sh
cd Android/native
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
cd ../..
python3 Android/test_build.py
ANDROID_SERIAL=emulator-5554 python3 Android/build.py --device-tests
```

Android instrumentation tests cover JNI cancellation, Keystore round trips, private cache cleanup, synthetic H.264/HEVC MP4 conversion, G.711/AAC and all-frame decoding. A production surface/lifecycle RTSP check is enabled by supplying the runner's `rtspPort` argument with a loopback synthetic peer reachable from the emulator. Fixtures contain only original generated patterns; no private camera footage or credentials are included.

Local checks ran on an Android 15/API 35 arm64 emulator. Real-camera protocols were previously established by the macOS implementation, but **this Android port still needs physical-phone/camera validation**, including hardware codec limits and Android 17 permission enforcement. macOS core/protocol/media/localization tests also passed after the additive port. Do not interpret an alpha's implemented settings catalog as a claim that every firmware setting was physically tested.

## Source and licenses

Original app code/icon: MIT. LibVLC 3.7.7: LGPL-2.1-or-later; Kotlin/AndroidX: Apache-2.0; libc++: Apache-2.0 with LLVM exception; Rust dependencies: their included license notices. **About and licenses** and APK assets contain notices. `libvlc-source.json` pins the AAR hash, upstream source revisions and patch directory. Corresponding source snapshots/build recipes accompany Android preview downloads; the application can be rebuilt/relinked with a modified library. See [third-party notices](../THIRD_PARTY_NOTICES.md).
