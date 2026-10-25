# Reversed engineering Icsee

**A native macOS viewer for iCSee / Xiongmai cameras over your own network.**

[Português brasileiro](README.pt-BR.md) · [How it was reverse engineered](docs/REVERSE_ENGINEERING.md) · [Contributing](CONTRIBUTING.md)

[![CI](https://github.com/ndelanhese/reversed-engineering-icsee/actions/workflows/ci.yml/badge.svg)](https://github.com/ndelanhese/reversed-engineering-icsee/actions/workflows/ci.yml)
[![MIT license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Reversed engineering Icsee started with a simple need: view personally owned iCSee cameras on a Mac, with native windows and direct local video. Research on an Android app exported from the owner's phone helped identify the SDK family; authenticated camera tests established the RTSP behavior needed by this independent Swift implementation.

It is a small, unofficial interoperability project. It does not embed the Android app or its SDK, and it is not affiliated with iCSee or Xiongmai. Compatibility depends on your camera's firmware and local RTSP support.

## What works

- Multiple cameras in a grid, with editable addresses, ports, channels and main/substream selection.
- Rename a camera without interrupting its video.
- Cinema mode, resizable floating popups, and native macOS fullscreen.
- One shared stream per camera across its views.
- Local camera authentication, optional macOS Keychain storage, and one compatibility retry for Sofia-style authentication.
- Connection diagnostics and a watchdog that stops showing frozen video as live.

The interface currently uses Brazilian Portuguese. Video output is scaled to 1280 pixels wide and capped at 15 fps. Audio, PTZ, recording, SD-card playback, cloud-account login and vendor P2P are not implemented. Remote viewing requires an already configured VPN into your home network; Reversed engineering Icsee does not configure one.

## Build and run

Requirements: **Apple Silicon, macOS 14+, Swift 6 toolchain, Python 3, and FFmpeg**. Install Apple's Command Line Tools if needed, and install FFmpeg using an existing Homebrew installation:

```sh
xcode-select --install
brew install ffmpeg
git clone https://github.com/ndelanhese/reversed-engineering-icsee.git
cd reversed-engineering-icsee
python3 build.py
open "dist/Reversed engineering Icsee.app"
```

The build uses `swiftc` directly. There is no Xcode project, Swift package dependency, Java runtime, Go runtime, or Rust runtime in the app. FFmpeg runs as a separate executable; it is not distributed here. Reversed engineering Icsee checks `/opt/homebrew/bin/ffmpeg` and `/usr/local/bin/ffmpeg`.

Build output is locally signed **ad hoc**, not Developer ID signed or notarized. No prebuilt installer or automatic updates are provided. Intel builds and compatibility with every supported macOS version have not been validated.

## Add your cameras

1. Open **Adicionar câmera**. New installations start empty.
2. Enter the camera's local IP/hostname, RTSP port (usually `554`) and channel (usually `1`). Find the address in your router's connected-device list or the camera's network settings.
3. Click **Conectar**, then enter the camera's **local device** username and password. These can differ from your iCSee cloud credentials.
4. Enable **Salvar no Chaves** only if you want to remember credentials.
5. Try **Fluxo leve** if the main stream is too heavy or unsupported.

Do not forward camera ports to the public internet. Local RTSP is not an encrypted transport; use a trusted LAN or VPN.

| Action | Control |
| --- | --- |
| Cinema mode | Double-click video or click the expand button |
| Leave cinema | `Esc` or **Voltar** |
| Floating window | Camera menu **⋯ → Popup flutuante** |
| Camera fullscreen | Camera menu **⋯ → Tela cheia** |
| Exit fullscreen | `Esc` |
| Toggle focused window fullscreen | `Control + Command + F` |
| Rename / edit connection | Camera menu **⋯** |
| Close popup | Native close button or `Command + W` |

Closing a popup keeps the shared stream alive. Closing the last app window quits Reversed engineering Icsee and stops its streams.

## Privacy and authentication

Camera names, addresses and settings live in local macOS preferences. Credentials are saved in Keychain only when requested. The app sends authenticated URLs to FFmpeg through an in-memory pipe rather than process arguments or a playlist file. Raw decoder diagnostics are classified in memory instead of being saved or displayed. The app has no telemetry or cloud-account integration.

Passwords, derived Sofia credentials and decoded video still exist in process memory while viewing. The Sofia transformation exists for legacy protocol compatibility; it is not modern password storage or encryption. See [security policy and boundaries](SECURITY.md).

## Development and validation

```sh
python3 test.py --core-only  # deterministic protocol/parser checks; no camera needed
python3 test.py              # adds native window lifecycle checks; desktop required
python3 test.py --interactive # adds native fullscreen / Escape checks
python3 build.py             # creates and verifies an ad-hoc signed arm64 .app
```

CI builds the app and runs core checks on a GitHub-hosted macOS runner. Window/fullscreen checks are manual desktop checks; CI is not a real-camera compatibility test. No camera credentials, APKs or live network access are required by these tests.

Start with [architecture](docs/ARCHITECTURE.md), [research provenance](docs/REVERSE_ENGINEERING.md), and [contribution rules](CONTRIBUTING.md). Please use synthetic data in issues and pull requests.

## Research credits

Built with assistance from Codex. The investigation used [REA](https://rea.tools/) and its [`reverse-engineer-anything` skill](https://github.com/morluto/rea/blob/main/.agents/skills/reverse-engineer-anything/SKILL.md), including package inspection and a JADX bridge. Development also used Swift/macOS guidance, systematic debugging, test-driven checks, review and verification skills. [The research notes](docs/REVERSE_ENGINEERING.md) explain their actual roles, the evidence behind compatibility decisions, and what remains unverified.

## License

Reversed engineering Icsee's original source and documentation are [MIT licensed](LICENSE). Android packages, decompiled vendor source, vendor libraries and camera footage are not included. FFmpeg and investigation tools retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).
