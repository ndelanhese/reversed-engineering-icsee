# Local camera discovery

macOS: **Add camera → Find cameras**. Android: **Find cameras** on the dashboard. Select a result, name the camera, save, then connect with its local credentials. Discovery does not retrieve passwords or log in to cameras.

Search runs only when requested and lasts about five seconds. It sends ONVIF WS-Discovery probes over connected IPv4 LAN interfaces, merges duplicate results and fills in the camera address and advertised ONVIF service port. macOS also preserves the advertised device-service path. RTSP port `554`, device-control port `34567` and channel `1` remain iCSee defaults, not values reported by WS-Discovery. Manual/advanced setup remains available for custom ports or cameras that do not advertise discovery.

Both implementations bind probes to local interfaces, restrict replies to the interface subnet and require advertised endpoints to match the reply's source IP. Responses must correlate with the search and meet packet/XML/device-count limits. The app never follows an arbitrary URL from a discovery packet. Closing/cancelling the search stops its work. Android holds its Wi-Fi multicast lock only for the active search and does not resume a scan automatically after backgrounding.

Discovery requires the same reachable local network, enabled ONVIF discovery, and a router/access point that forwards multicast. Guest-network isolation, disabled ONVIF, IPv6-only cameras or a VPN that does not relay discovery can prevent results; manual addresses remain usable when routing permits. Android currently accepts HTTP `/onvif/device_service` announcements, matching its ONVIF client. The feature targets the existing iCSee/Xiongmai RTSP dialect; discovering another manufacturer's ONVIF device does not establish video compatibility.

## Validation

Production Swift and Rust discovery each found both owner's cameras in a live read-only LAN check. Automated tests cover actual UDP replies, duplicate devices, correlation, malformed/oversized XML, unsafe endpoints, names, deadlines and cancellation. No credentials, movement or settings writes are part of discovery tests. Android interface/lifecycle and playback tests run on an API 35 arm64 emulator; physical Samsung S21+ validation remains separate.

The Android player now stops unresponsive RTSP sessions outside the UI thread. Regressions reproduce the previous frozen **Connecting…** state with a silent RTSP peer and check Stop responsiveness, a terminal startup error, replacement and rejected authentication. A failed initial connection has one compatibility retry; it does not retry indefinitely. Cleanup capacity is bounded to avoid accumulating native players.

Protocol reference: [ONVIF Core Specification](https://developer.onvif.org/pub/core/Core_2.00.pdf), Discovery section.
