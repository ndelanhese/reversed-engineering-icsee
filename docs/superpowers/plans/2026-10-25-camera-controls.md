# Native camera controls implementation plan

> For agentic workers: use superpowers:subagent-driven-development for independent clients and a whole-branch review. User explicitly requested execution of the completed research; proceed without another approval round.

**Goal:** Add usable native PTZ, image controls and discovered local device settings to the existing Mac app.
**Architecture:** Independent Swift ONVIF and DVRIP clients feed an app-owned camera control model/window. RTSP sessions remain shared; controls use explicit bounded operations and existing credential entry. ONVIF handles movement/presets/imaging; DVRIP handles vendor settings by named sections.
**Tech:** Swift 6, Foundation/FoundationXML, CryptoKit, Network, SwiftUI/AppKit. macOS14+, Apple Silicon. No new runtime dependencies.
**Spec:** Owner request quotes outputs/Camera-controls-research.md in the parent workspace, then says “faça”; requested all available local settings. The complete research and private artifacts remain outside this repository.

## Constraints

- Preserve camera profiles, Keychain service local.CamMac.camera, stable local signing, menu bar behavior and shared RTSP sessions.
- App follows macOS English/pt-BR preferences. Public documentation/release instructions stay English with a pt-BR link.
- No credentials, device addresses, private device responses or vendor implementation code in git/logs/argv.
- Capability-driven controls. Actual advertised options determine profiles, ranges and writable imaging options; device rejection is visible.
- Continuous movement always has an explicit short device timeout plus Stop; finite preset movement uses GetStatus with a 15-second watchdog plus Stop; no movement/write retry after reconnect. Explicit stop and window close must stop pending movement.
- Settings are read on demand; edits preserve unrelated fields, reject structural/type changes and conflicting edited leaves, write explicitly then verify by readback. Unknown/unsupported remains distinct from failed/unauthorized.
- Generic settings exclude operation identifiers (OP*), cloud/account/platform features, credentials/account maintenance and unknown destructive commands. Native fields expose supported local sections; no auto writes.
- Unit tests use synthetic data and mock/local servers only. Live motor tests authorized on BOTH cameras by user, bounded and followed by Stop. No live storage/network/reset/password changes for verification.

## Tasks

### 1. ONVIF client (worker, separate files)
Create Sources/CameraControl/ONVIFClient.swift and ONVIFTypes.swift; Tests/ONVIFControlTest.swift and synthetic fixtures as needed. Implement discovery, profiles/config options/presets, bounded ContinuousMove/Stop/preset save/goto, imaging options/settings and single-field validated writes/readback. HTTP Digest/WSSE credentials stay memory-only; bounded XML, no external entities or redirected credentials; exact same-host service URLs. Test protocol parsing, faults/auth, bounds, movement timeout and preservation with synthetic transport.

Contract: actor ONVIFClient init(host:String,port:Int=8899,username:String?=nil,password:String?=nil). discover()->ONVIFDevice; ptzOptions(profile:ONVIFProfile)->ONVIFPTZOptions; move(profile:ONVIFProfile,pan:Double,tilt:Double,zoom:Double,timeout:Double); stop(profile:ONVIFProfile); presets(profile:)->[ONVIFPreset]; gotoPreset(profile:,token:); savePreset(profile:,name:)->String; imaging(profile:)->[ONVIFImagingSetting]; setImaging(profile:,path:String,value:String). All operations async throws. Types Sendable; details in worker brief/work report. Worker may improve contract but must notify root before names change.

### 2. DVRIP client and JSON editing primitives (worker, separate files)
Create Sources/CameraControl/DVRIPClient.swift, DeviceJSON.swift; Tests/DVRIPControlTest.swift. Implement bounded20byteLE framing, fragmentation/coalescing, session/sequence matching, serialized requests and keepalive; get1042, capabilities1360, set1040 with named section. Exact raw config values from private APK metadata are protocol identifiers only. No vendor library/code copied. Test malformed frames, timeouts/EOF/auth, conflict-safe edits, no replay and verification.

Contract: actor DVRIPClient init(host:String,port:Int=34567,username:String,password:String); connect() async throws; disconnect() async; read(name:String,capability:Bool=false) async throws->DeviceJSON; write(name:String,original:DeviceJSON,updated:DeviceJSON) async throws->DVRIPWriteResult. DeviceJSON enum Codable,Equatable,Sendable: object([String:DeviceJSON]),array([DeviceJSON]),string(String),number(Decimal),bool(Bool),null. DVRIPWriteResult has value:DeviceJSON, requiresRestart:Bool. Validation and patch APIs finalized by worker in brief/report.

### 3. Native control window/model and entry points (root)
Create CameraControlModel.swift, CameraControlsView.swift and native window ownership as needed. Integrate camera card, cinema/popup and menu preview with Controls action. Share per-camera model/window; explicit Authenticate action uses existing credential UI, never hover. PTZ arrows use bounded nudges and independent Stop, speed slider/device limits, profiles, presets. Image forms use actual ranges/enums, manual Apply, refresh/readback. Vendor settings grouped/searchable, read on selection; structured scalar editor preserves unknown data; advanced changes reviewed explicitly. Do not mistake cloud entries for local support.

### 4. Integration verification and publication (root + independent review)
Run transport tests, existing interactive suite, new native lifecycle fixtures; strict signed bundle check. Review actual device reads; test bounded move/Stop and reversible image edit/readback on authorized cameras when authentication permits, restoring values. Update English/PT docs and version; install local signed build preserving profiles/certificate. Independent review before protected PR merge; release artifacts via existing workflow.

## Review focus

1. Late/cancelled HTTP movement must not restart after Stop; device-side timeout remains mandatory.
2. Device XML/JSON must never redirect credentials, expand entities, overflow buffers or disclose secrets through diagnostics.
3. Real devices can advertise generic/fake capabilities: unsupported and permission failures remain visible, not crashes or false success.
4. Unknown fields/channel arrays and concurrent changes must survive a leaf edit; no silent whole-config overwrite.
5. Removed/edited cameras, window close/quit and background menu views must release control sessions and issue Stop without changing existing video semantics.
