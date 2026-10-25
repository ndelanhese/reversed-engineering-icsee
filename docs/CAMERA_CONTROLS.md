# Native camera controls

Open a camera's **⋯ → Camera controls…** menu. The same controls are available from cinema/floating views and the menu bar preview. Each camera has one control window; opening it again brings that window forward.

## Connect

The window discovers the camera's ONVIF profiles and advertised controls. If video is already connected, its in-memory device credentials are reused. Otherwise choose **Authenticate…** and enter the camera's local credentials. Saved credentials use the existing macOS Keychain workflow; hovering over the menu icon never loads a password.

**Connect video** starts the shared video session and authenticates controls. Control authentication and RTSP authentication are separate protocol operations: firmware or account permissions may allow one and reject the other. Errors are shown separately; unsupported controls are not treated as a successful connection.

Default ports are **8899 for ONVIF** and **34567 for vendor device settings**. Change them in the camera's **Configure…** connection form if needed. Existing profiles keep their original video fields and receive these defaults. Use a trusted LAN or existing VPN; these legacy local protocols are not a substitute for encrypted remote transport.

## Movement and presets

- Select a **Video profile** returned by the device. Multi-lens firmware may expose different profiles/channels; do not assume a video layout identifies the motorized channel.
- Arrow clicks send short nudges at the selected speed. Supported zoom controls appear from advertised options.
- **Stop movement** cancels pending movement and sends Stop. Closing the control window also stops pending movement.
- **Save preset** stores the current position under a name; **Go** requests a saved finite target.

ContinuousMove always includes a device-side timeout of at most one second and is followed by Stop. Firmware requiring a minimum timeout greater than one second is rejected for this mode. Preset movement is different: ONVIF GotoPreset has no Timeout parameter. It uses status polling with a 15-second client watchdog and Stop on cancellation/failure/timeout. Advertised zoom/focus/preset support can exceed the actual hardware; rejected operations remain visible.

Normal **Quit** waits for pending control cleanup before exiting, including Stop and an acknowledged restart's connection hold. A forced process termination, network failure or noncompliant firmware cannot provide the same acknowledgement.

## Image

The **Image** tab reads current values and options from the selected video source. Fields with advertised numeric ranges or enumerated choices can be edited; unknown options remain read-only. Use **Apply image settings** to write explicit changes and verify them by reading the camera again. Unrelated extension fields are preserved. Profile changes, refresh and credential changes ask before discarding drafts.

Available fields depend on the device and may include brightness, contrast, saturation, sharpness, exposure, IR-cut/night mode, white balance and wide dynamic range. A field being advertised does not guarantee the hardware can physically change it.

## Device settings

After local authentication, the app checks a bounded catalog of known vendor sections. Only sections successfully returned by the selected camera are shown by default. The scan is read-only, has a time limit, and can be paused/resumed. **Show unverified settings** exposes additional known candidates and their read errors for diagnostics; it does not certify support.

Categories include image/lighting, video/audio, detection/alarms, recording/storage, network, time/privacy, movement configuration and device information. The structured editor changes existing scalar values only, preserves field names/types/array positions and masks password-like values. Device information/capabilities and unverified command-like calibration/storage-init blocks remain read-only.

These are advanced firmware-specific fields. Successful reads establish availability, not universal writability or parameter ranges. Applying a change:

1. Requires an explicit **Apply changes** confirmation.
2. Reads the current section again and rejects conflicts on the edited values.
3. Preserves concurrently changed, unrelated fields.
4. Sends one write without automatic replay and checks the returned values.

A lost acknowledgement is reported as uncertain. Reconnect and reload before trying again. Some accepted changes require a restart; they are displayed as pending rather than falsely reported as verified. **Restart camera…** is a separate confirmed action. Keep the app running during its 15-second connection hold; reconnect after the device finishes restarting.

Network/privacy/power changes can disconnect a camera. The app does not automatically change those settings, format storage, reset a device, upgrade firmware or modify accounts/passwords. Cloud subscriptions, phone/WeChat integrations and Android-only features are outside this local control implementation. There is no wildcard capable of enumerating every setting of every firmware.

## Validation and scope

The native ONVIF client was exercised against two owner-controlled cameras: discovery/profiles/options, bounded movement/Stop requests, and brightness change/readback/restoration succeeded. Physical optical-zoom and every individual preset/firmware setting were not exhaustively validated.

Synthetic localhost peers verify DVRIP framing/authentication/session/keepalive, availability discovery, structured edits, conflict checks, readback and restart handling. Native fixtures verify window reuse, shared streams, close/quit during movement and the 15-second restart hold. Live network/storage/reboot/password changes were not used for testing. Visual pixel/AX automation is limited; native window/model behavior and language resources are checked independently.

Build and run tests with `python3 test.py --core-only` or `python3 test.py --interactive` for native window checks. Releases remain Apple Silicon/macOS14+, without an Android SDK, Java or Python runtime dependency.

[Brazilian Portuguese guide](../README.pt-BR.md#controles-da-câmera).
