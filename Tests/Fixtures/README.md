# Synthetic decoder fixtures

`blue.h264` and `blue.hevc` each contain two 64×48 blue frames. They were generated from FFmpeg's `color` source, contain no camera footage or device data, and are distributed with the original project fixtures under MIT.

Regenerate using an FFmpeg installation with the relevant encoders:

```sh
ffmpeg -f lavfi -i color=c=blue:s=64x48:r=1:d=2 -frames:v 2 -c:v libx264 -pix_fmt yuv420p -f h264 Tests/Fixtures/blue.h264
ffmpeg -f lavfi -i color=c=blue:s=64x48:r=1:d=2 -frames:v 2 -c:v libx265 -x265-params log-level=error:pools=1:frame-threads=1 -pix_fmt yuv420p -f hevc Tests/Fixtures/blue.hevc
```

The release decoder does not include these encoders. It only needs to decode the fixtures and produce MJPEG, using the same scale/output path as the app. `Tools/verify_bundle.py` checks this without Homebrew on PATH or any camera connection.

## Synthetic recording media

These tiny streams contain only FFmpeg `testsrc2` patterns (64×64 at10fps), never camera footage. They are test inputs only and are not bundled with the app. Runtime decoding/encoding remains native AVFoundation; the existing bundled FFmpeg configuration is unchanged.

To regenerate using a development FFmpeg with libx264/libx265:

```sh
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=64x64:rate=10 -frames:v 30 -c:v libx264 -pix_fmt yuv420p -x264-params bframes=0:keyint=10:min-keyint=10:scenecut=0:aud=1:repeat-headers=1 -f h264 -y Tests/Fixtures/recording-synthetic.h264
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=64x64:rate=10 -frames:v 30 -c:v libx265 -pix_fmt yuv420p -x265-params bframes=0:keyint=10:min-keyint=10:scenecut=0:aud=1:repeat-headers=1:log-level=error -f hevc -y Tests/Fixtures/recording-synthetic.h265
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=64x64:rate=10 -frames:v 10 -c:v libx265 -pix_fmt yuv420p -x265-params bframes=2:keyint=10:aud=1:repeat-headers=1:log-level=error -f hevc -y Tests/Fixtures/recording-reordered.h265
```

`RecordingMediaTest --write-fixture <path>` wraps the valid H.264 fixture in independently constructed XM headers with synthetic G.711A silence for localhost integration tests. Ordinary tests also construct corrupted/fragmented fixtures in memory and remove their temporary outputs.
