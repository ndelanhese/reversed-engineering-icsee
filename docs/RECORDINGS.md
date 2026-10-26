# Local SD-card recordings

[Brazilian Portuguese guide](../README.pt-BR.md#gravações-do-cartão-sd).

Open **⋯ → Recordings…** on a camera, or use the recordings action in enlarged views or the menu preview. One window is retained per camera. This feature reads/downloads existing camera files; it never deletes recordings, formats storage or changes recording settings.

## Browse by camera time

Authenticate with the camera's local account. Active live-video credentials can be reused in memory; otherwise the existing credential sheet provides optional Keychain storage. Calendar/history requests use a separate local DVRIP session, normally on the camera's configurable control port34567.

Choose a month/day, channel and main/substream. Calendar dots indicate dates returned by the camera's monthly presence mask, which may cover the whole device rather than one selected channel. If monthly queries are unavailable, every date remains selectable for a direct daily query. No result is distinct from an unsupported, unauthorized or failed query; storage information is supplementary and does not replace a file search.

The **Camera time** axis preserves wall-clock components returned by the device. It does not silently shift history into the Mac timezone. Device timestamps do not supply a validated UTC offset; the internal UTC Gregorian calendar is an arithmetic coordinate, not a claim that the camera records in UTC. Check the displayed device clock if the camera itself has incorrect time.

Select a list item or click a recorded timeline interval. **Go to time** locates footage covering a requested camera time. Empty intervals remain gaps. The search includes a bounded preceding24hours to find files crossing midnight. Pagination is inclusive and deduplicated, with finite page/item limits and an explicit partial-result warning when the firmware cursor cannot progress. Completeness describes that queried window: a file beginning more than24hours before the selected day can be missed. Calendar availability and file overlap behavior depend on firmware.

## Playback

The selected file downloads into a randomly named mode0700 temporary directory. Raw/native files use mode0600. Progress reports received bytes; the camera's rounded file size is only an estimate. Explicit media completion is required: a timeout, connection loss or truncated media is not a finished recording. Canceling or switching clips closes the transfer and removes incomplete output.

After download, native conversion and an all-frame decode check prepare a seekable `.mov`. The player supports pause/resume, position seeking,15-second backward/forward jumps, previous/next recordings and local0.5×/1×/2×/4× rates. Seeking/speed operate locally because device Fast/Slow commands can acknowledge without changing playback. Continuous reverse decoding is not claimed.

Supported video is independently decodable H.264/HEVC with stable parameter sets. Streams requiring missing decode timestamps for reordered pictures, malformed pictures, unsupported formats or changing configurations are rejected for native conversion. Supported8kHz G.711A/U audio becomes AAC through the platform encoder. Unsupported audio is explicitly disclosed as video-only native output; export the original to retain all source bytes.

Only keyframes carry whole-second camera timestamps. Intermediate frame timing is inferred from declared FPS and re-anchored without inventing high-resolution timestamps. True timestamp gaps are retained; the player may hold the previous image through a gap. The timeline uses decoded mapping segments once available. Audio has no recovered absolute timestamps, so its alignment is inferred from packet order/sample counts. These disclosures remain visible after export.

## Export

- **Export original…** saves the exact completed XM camera stream. Its contents may be H.264/HEVC despite the opaque source filename; a compatible demuxer/player may be required.
- **Export movie…** saves the native `.mov`, with the audio/timing limitations displayed by the player.
- **Export interval…** takes seconds relative to the prepared movie. **Start here**/**End here** use the current player position. Bounds expand to decodable keyframes and the UI shows the effective interval before export. This is passthrough trimming, not arbitrary frame-exact re-encoding.

Exports use a native save panel. Interval preparation stays inside the private cache; publishing uses mode0600 staging and replaces a destination only after successful completion. The completed original remains exportable if native conversion fails. Switching recordings or closing the recordings window removes its temporary cache; user-selected exports survive.

Live video remains independently active. Disconnect-all, relevant camera edits/removal and normal Quit cancel/reap recording work while preserving the existing control Stop/restart cleanup rules. Forced process termination may leave an OS-temporary directory; it is not a persistent recording library. Raw downloads are limited to8GiB; native conversion accepts up to2GiB. Available disk space, media/frame/sample limits and processing deadlines also apply. An encrypted/proprietary firmware stream may require an unsupported decoder; no vendor SDK or cloud fallback is embedded.

## Protocol provenance

REA/JADX inspection of the owner's unchanged APK established local device-record manager, component-based date searches and native SDK boundaries. Protocol facts were cross-checked against pinned primary implementations and vendor documentation; no decompiled application logic or vendor SDK binary is shipped.

- [Vendor calendar request/mask](https://github.com/xmeye/openplatform-docs/blob/7db946442bb3254402f9f20e16baba97a85e4b56/docs/InterfacedescriptionofFunSDKiOS/InterfacedescriptionofFunSDKiOS-devicefunctionmethod.md#L1286-L1343): OPSCalendar1446/1447.
- [Independent protocol/transport](https://github.com/alexshpilkin/dvrip/tree/e76df1d091d85aa6cffb5c332ba6ae419ac9ac89/dvrip): query1440, claim1424, control1420, media1426 and explicit termination.
- [OpenIPC protocol reference implementation](https://github.com/OpenIPC/python-dvr/blob/6ea861a1e99cab5922084a4a0eac6fe2d5b6120d/dvrip.py): file metadata, rounded sizes and download shapes.
- [Recent firmware/media observations](https://github.com/Moxnatiy/hass-xmeye/tree/51b3ed9a34301e71c6382f20a63a89854b609a7c/src/xmeye): XM frame metadata, timing limitations and firmware-dependent playback behavior.

## Validation scope

Synthetic protocol tests cover clock/date validation, calendar/storage states, inclusive pagination and midnight overlap, auth/session/correlation, claim ordering and compatibility, explicit completion, binary boundaries, cancellation and failed-transfer cleanup. Synthetic H.264/HEVC fixtures verify native all-frame decode, duration/sync flags, seeking/rate, G.711/AAC, gaps/late starts, malformed pictures/configuration rejection and cancellation. Native model/window fixtures exercise original/interval export, stale work, private-cache cleanup and independent live-session lifetime.

These establish implementation behavior, not universal firmware compatibility. No card deletion, formatting or storage-setting writes are used for validation. Visual pixel automation is limited; window/model behavior is tested independently. Actual recording codecs and local-camera support must be checked on the target firmware; unsupported operations remain visible.
