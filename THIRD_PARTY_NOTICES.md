# Third-party notices

The MIT license covers Reversed engineering Icsee's original source and documentation only. The following tools and platforms are acknowledged; their code is not vendored in this repository.

| Component | Role | Licensing / source |
| --- | --- | --- |
| Swift, SwiftUI, AppKit, Foundation, CryptoKit, Security | Compiler and macOS APIs | [Swift](https://www.swift.org/) and Apple SDK terms apply separately |
| FFmpeg | External runtime decoder | [FFmpeg legal information](https://ffmpeg.org/legal.html); license depends on the installed build and its configuration |
| REA and `reverse-engineer-anything` | Development-time investigation tooling and instructions | [REA repository and license](https://github.com/morluto/rea) |
| JADX | Development-time Android package inspection through REA | [JADX source and license](https://github.com/skylot/jadx) |
| Eclipse Temurin | Development-time Java runtime for the analysis tooling | [Temurin](https://adoptium.net/temurin/) |

Reversed engineering Icsee does not distribute FFmpeg, Android APKs, `libFunSDK.so`, other vendor libraries, decompiled vendor source, vendor artwork or camera footage. Adding any external binary later requires a separate review of that exact artifact's license and distribution obligations.

iCSee and Xiongmai names identify compatibility targets; trademarks and proprietary software remain with their respective owners. Reversed engineering Icsee is an independent project with no claimed affiliation or endorsement.
