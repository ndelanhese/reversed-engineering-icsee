# Resource use

The menu bar icon stays available while live video work follows visible viewers. Closing the last viewer, minimizing, fully covering the window, hiding the app or system sleep suspends that camera. The session drops its frame, decoder and watchdog. The output reader closes before waiting for diagnostic EOF, so a final JPEG flush cannot leave a stopped decoder stuck on a full pipe. No periodic background camera polling is scheduled. Authentication and manual connection intent remain in memory for resume; **Stop**, failure and Quit clear that intent. Keychain is not accessed by hover/resume. SD recording playback/export uses its own independent session.

One decoder is shared per camera. A menu-only preview emits 480-pixel-wide images at up to 5 FPS, dropping excess frames before scaling/JPEG encoding. Grid cards use 800 pixels / 5 FPS. Cinema/floating/fullscreen views keep the existing 1280-pixel / 15 FPS limit and take priority over the preview. The app requests VideoToolbox decoding with a bounded software fallback; decoder/filter/JPEG thread counts are limited.

Idle cannot mean zero RAM: the running native app and its windows/frameworks remain resident. Active video also costs CPU/GPU time, buffers and network traffic. Resuming after idle reconnects RTSP and may wait for a camera keyframe. These changes do not lower the camera's saved recording quality or alter camera settings.

## Validation

`python3 test.py --interactive` exercises repository-owned synthetic H.264 over a loopback-only RTSP/TCP peer, with the bundled decoder. It checks full-size/preview sharing, close/reopen with output-pipe backpressure and subprocess cleanup, minimize/restore, sleep/wake, menu hover and camera selection, and explicit Stop. `--core-only` checks that a hidden connection request starts no decoder and retains credentials only in memory. Bundle verification decodes synthetic H.264/HEVC through both a software path and a hardware request (which may fall back). No real footage or credentials are fixtures.

Visibility follows [AppKit window occlusion notifications](https://developer.apple.com/documentation/appkit/nswindow/didchangeocclusionstatenotification); decoding and thread controls use [FFmpeg's documented options](https://ffmpeg.org/ffmpeg.html).

## Measured comparison

Measured on the same Apple M1 Pro / macOS 27.0.1, October 26, 2026, using the same two local camera profiles. Each steady-state sample lasted about 20 seconds; all process IDs stayed stable throughout each reported sample. Values include the app and every live decoder process, not just the Swift executable. The final build is 0.6.2 (17).

| State | Previous build 0.6.1 (14): footprint / CPU | Final build: footprint / CPU | Live decoders after |
| --- | --- | --- | --- |
| Main window closed, preview closed | 998.85 MiB / 96.00% | 53.27 MiB / 0.02% | 0 |
| Main grid, two cameras visible | 1001.73 MiB / 91.87% | 177.69 MiB / 27.73% | 2 |
| Menu preview alone, one camera | Not separately measured | 120.23 MiB / 15.50% | 1 |

CPU is a percentage of **one CPU core**: 100% means one fully occupied core. It is derived from process user+system CPU time deltas, converting Mach ticks with this machine's timebase (125/3). Memory is the sum of per-process `ri_phys_footprint` from `proc_pid_rusage`, including the decoder children; RSS is a different measure and may include shared resident mappings. GPU, WindowServer and system-wide energy are not included. These are short local measurements, not universal budgets or a long-duration leak test. Different camera codecs, resolutions, scene complexity and hardware affect active-view costs. No camera addresses, credentials or footage are included in this report.

For reference, final aggregate resident sizes were 82.75 MiB with the icon alone, 231.89 MiB with two grid cameras, and 125.96 MiB with the preview alone. Closing the preview after measurements again left zero decoder children.
