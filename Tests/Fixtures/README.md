# Synthetic decoder fixtures

`blue.h264` and `blue.hevc` each contain two 64×48 blue frames. They were generated from FFmpeg's `color` source, contain no camera footage or device data, and are distributed with the original project fixtures under MIT.

Regenerate using an FFmpeg installation with the relevant encoders:

```sh
ffmpeg -f lavfi -i color=c=blue:s=64x48:r=1:d=2 -frames:v 2 -c:v libx264 -pix_fmt yuv420p -f h264 Tests/Fixtures/blue.h264
ffmpeg -f lavfi -i color=c=blue:s=64x48:r=1:d=2 -frames:v 2 -c:v libx265 -x265-params log-level=error:pools=1:frame-threads=1 -pix_fmt yuv420p -f hevc Tests/Fixtures/blue.hevc
```

The release decoder does not include these encoders. It only needs to decode the fixtures and produce MJPEG, using the same scale/output path as the app. `Tools/verify_bundle.py` checks this without Homebrew on PATH or any camera connection.
