# Research provenance: from iCSee Android to a native Mac viewer

## Goal and result

The owner wanted direct access to personally owned iCSee cameras on a Mac: a grid, larger views and native windows. The starting material was an Android package exported from the owner's installed app. The result is an independent Swift client for the cameras' local RTSP interface, not a translated Android application or a replacement implementation of the vendor cloud.

This document summarizes observations and decisions in original prose. It does not distribute the inspected application, decompiled code, vendor libraries, private traces or camera footage. Original research evidence remains outside this public repository; the notes are a provenance summary, not a fully reproducible artifact archive.

## Investigation inputs

| Input | Identification |
| --- | --- |
| Android app | Package `com.xm.csee`, version `7.9.5_G`, version code `79531` |
| Complete split-package export | SHA-256 `c524a7812820d25f74cd609316e1a3d46536a7deee5d0751df1eafdf1d4d32b4` |
| Native SDK examined | Android arm64 `libFunSDK.so`, SHA-256 `88a91fe8f1b3d34342994f90b80b526a4062764411c6a5c01869f4914ca4b1c0` |
| Runtime validation | Two owner-controlled cameras on the same LAN, with owner-supplied local credentials |

The first standalone APK was insufficient because the installed app used split packages. A later complete `.apks` export supplied the missing architecture-specific material. Artifact hashes identify inputs without redistributing them; no passwords or device identifiers are needed to use the public source.

## How REA was used

[REA](https://rea.tools/) ([source](https://github.com/morluto/rea)) and its [`reverse-engineer-anything` skill](https://github.com/morluto/rea/blob/main/.agents/skills/reverse-engineer-anything/SKILL.md) guided artifact-first inspection and separation of observations from hypotheses.

1. **Inventory the exported package.** Container and manifest inspection established package identity and split-package requirements. This prevented treating a partial APK as a complete distribution.
2. **Inspect Android managed metadata.** REA's JADX bridge loaded the package and inspected relevant SDK integration classes, including `com.manager.XMFunSDKManager`. A task-local Temurin Java runtime supported this analysis. Java was used by the inspection tooling, not the Mac application.
3. **Inspect the native SDK boundary.** ARM64 binary metadata, exported/JNI entry points and protocol strings helped identify the FunSDK/Xiongmai family. Native deep-analysis support was limited in the available environment. This was bounded inspection, not exhaustive SDK decompilation or recovery of its source.
4. **Validate against the actual cameras.** Local endpoint checks and authenticated RTSP/DVRIP probes established which observed interfaces were usable. Static package evidence alone did not prove that a camera would stream video.
5. **Implement only the needed behavior.** Native macOS views and a separate FFmpeg decoder replaced the Android runtime path. No Android executable code or SDK library is linked into Reversed engineering Icsee.

The original work also used REA-supported native UI inspection during development. Public source maintenance normally uses repository tools rather than re-running binary analysis.

## Authentication finding that mattered

One camera accepted ordinary RTSP authentication. The other remained usable in the phone app but rejected standard RTSP login with HTTP-style status 401, even with its correct local password. An authenticated local DVRIP login succeeded, and an RTSP request carrying the Sofia-style derived query credential succeeded. That supported a firmware compatibility explanation rather than simply assuming a wrong password.

Reversed engineering Icsee consequently tries the ordinary RTSP form first. Only a 401 before the first decoded frame permits one compatibility retry. The local credential is never bypassed; the second attempt uses a representation expected by this firmware family.

The supported endpoint shape, with placeholders, is:

```text
rtsp://<encoded-user>:<encoded-password>@<host>:554/user=<encoded-user>[&password=<derived-value>]&channel=1&stream=0.sdp?real_stream
```

`stream=1` selects the substream. Credentials are percent-encoded before constructing the playlist. The optional derived value is produced by the small `sofiaPassword` function in `CameraCore.swift`: MD5 bytes are combined in pairs and mapped into a 62-character alphabet. This is a legacy compatibility transformation, not secure password hashing. Treat its output as sensitive.

Only two physical cameras were validated during original development. Exact model names and firmware versions were not captured in a publishable compatibility matrix. A device marketed for iCSee is not automatically supported; its RTSP service, channel layout and firmware still matter. No official protocol specification or vendor compatibility guarantee is claimed.

## Agent skills and their roles

Development was assisted by Codex with these instruction sets. They are development workflow guidance, not packages required to build or run Reversed engineering Icsee.

| Skill | Actual role |
| --- | --- |
| `reverse-engineer-anything` (REA) | Package/binary investigation, available provider selection, evidence boundaries and runtime inspection |
| `write-swift` | Swift modeling and concurrency guidance |
| `macos-patterns`, `macos-build`, `apple-design` | Native window behavior, platform conventions and build guidance; this repository ultimately uses direct `swiftc` |
| `superpowers:systematic-debugging` | Separate credential failures, firmware compatibility, connection failures and test-harness failures using observations |
| `superpowers:test-driven-development` | Focused checks for protocol encoding, framing, diagnostics and window behavior |
| `superpowers:requesting-code-review` | Independent review of viewer lifecycle and shared-session behavior |
| `superpowers:verification-before-completion` | Confirm builds and runtime checks before reporting success |
| `ponytail:ponytail`, `finisher` | Keep implementation small and remove unfinished or redundant work |

The public-repository preparation additionally used focused privacy/security review guidance from `security-audit`. That does not constitute a complete security audit or third-party certification. Tool assistance does not replace maintainer responsibility for the published code.

## Evidence and limits

| Statement | Basis / limit |
| --- | --- |
| Android app integrates the FunSDK family | Package/class inspection and native SDK identification |
| Two devices support local video | Authenticated tests on owner-controlled hardware |
| One needs a legacy query form | Standard RTSP failed; local authenticated probes and the compatible form succeeded |
| The viewer has no Android runtime dependency | Published Swift source and build script; no vendor library distributed |
| Parser and encoding behavior is repeatable | Synthetic tests in `Tests/CoreSelfTest.swift` |
| Popup/fullscreen share the camera session | Local native lifecycle tests; desktop tests are separate from CI |
| Native PTZ and image controls | ONVIF implementation; bounded command/Stop acknowledgements and brightness write/readback/restoration on two cameras; other physical features firmware-dependent |
| Vendor device settings | DVRIP implementation and synthetic transaction/lifecycle verification; all firmware fields not exhaustively certified |
| Cloud/P2P, live audio and SD playback work | **Not established and not implemented** |
| Full vendor protocol or SDK was recovered | **Not claimed** |

For another device, obtain your own authorized input, keep private artifacts outside the repository, document observations without copying vendor implementation, and test using your own device credentials. Do not attach private dumps to issues.
