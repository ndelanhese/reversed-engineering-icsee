# Third-party notices

The MIT license covers Reversed engineering Icsee's original source, geometric app icon and documentation. Third-party code retains its own license. Proprietary camera software is not redistributed.

| Component | Role | Licensing / source |
| --- | --- | --- |
| Swift, SwiftUI, AppKit, Foundation, CryptoKit, Security | Compiler and macOS APIs | [Swift](https://www.swift.org/) and Apple SDK terms apply separately |
| FFmpeg 9.0.2 | Separate runtime decoder, bundled in binary releases | LGPL-2.1-or-later; [FFmpeg legal information](https://ffmpeg.org/legal.html), [matching source archive](https://github.com/ndelanhese/reversed-engineering-icsee/releases/latest/download/ffmpeg-9.0.2.tar.xz) |
| REA and `reverse-engineer-anything` | Development-time investigation tooling and instructions | [REA repository and license](https://github.com/morluto/rea) |
| JADX | Development-time Android package inspection through REA | [JADX source and license](https://github.com/skylot/jadx) |
| Eclipse Temurin | Development-time Java runtime for the analysis tooling | [Temurin](https://adoptium.net/temurin/) |

Binary releases compile FFmpeg from the official, SHA-256-pinned `ffmpeg-9.0.2.tar.xz`, with GPL, nonfree and third-party autodetection disabled. No source patches are applied. FFmpeg remains a separate executable accessed through pipes; it is not linked into the Swift app. Its own libraries are statically linked into that executable, with only Apple system libraries as runtime dependencies.

Every binary release provides the exact unmodified source archive on the same GitHub release page, `ffmpeg-build.json` with configure arguments and binary hashes, and `SHA256SUMS.txt`. The app contains `COPYING.LGPLv2.1`, upstream `LICENSE.md`, source-location information and build metadata under `Contents/Resources/ThirdParty/FFmpeg`. `Tools/build_ffmpeg.py` contains the build procedure. You may modify and replace the separate decoder under its license; a modified app bundle requires re-signing its local signature.

Quick development builds can use a separately installed FFmpeg instead; that installation's configuration and license can differ. Investigation tools are not runtime components and are not distributed with the app.

Android APKs, `libFunSDK.so`, other proprietary vendor libraries, decompiled vendor source, vendor artwork and private camera footage are not distributed.

iCSee and Xiongmai names identify compatibility targets; trademarks and proprietary software remain with their respective owners. Reversed engineering Icsee is an independent project with no claimed affiliation or endorsement.
