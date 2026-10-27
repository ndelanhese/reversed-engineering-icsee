//! Bounded, credential-free ONVIF WS-Discovery on explicitly supplied LAN interfaces.
use crate::{core::Result, wire::check_cancel};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    net::{Ipv4Addr, SocketAddr, SocketAddrV4, UdpSocket},
    sync::{atomic::AtomicBool, Arc},
    time::{Duration, Instant},
};
use xmltree::{Element, XMLNode};

const SOAP: &str = "http://www.w3.org/2003/05/soap-envelope";
const ADDRESSING: &str = "http://schemas.xmlsoap.org/ws/2004/08/addressing";
const DISCOVERY: &str = "http://schemas.xmlsoap.org/ws/2005/04/discovery";
const MAX_PACKET: usize = 65_507;
const MAX_DEVICES: usize = 64;

#[derive(Clone, Copy)]
struct Interface {
    address: Ipv4Addr,
    prefix: u32,
}
impl Interface {
    fn contains(self, peer: Ipv4Addr) -> bool {
        let mask = u32::MAX.checked_shl(32 - self.prefix).unwrap_or(0);
        let peer_bits = u32::from(peer);
        peer_bits & mask == u32::from(self.address) & mask
            && !peer.is_unspecified()
            && !peer.is_multicast()
            && !peer.is_broadcast()
            && (self.address.is_loopback() || !peer.is_loopback())
            && (self.prefix >= 31 || peer_bits & !mask != 0 && peer_bits & !mask != !mask)
    }
}
fn interfaces(v: &Value) -> Result<Vec<Interface>> {
    let list = v["interfaces"]
        .as_array()
        .filter(|a| !a.is_empty() && a.len() <= 16)
        .ok_or("invalid_input")?;
    let mut out = Vec::new();
    for item in list {
        let address = item["address"]
            .as_str()
            .and_then(|s| s.parse::<Ipv4Addr>().ok())
            .ok_or("invalid_input")?;
        let prefix = item["prefixLength"]
            .as_u64()
            .filter(|p| (1..=32).contains(p))
            .ok_or("invalid_input")? as u32;
        if address.is_unspecified()
            || address.is_multicast()
            || address.is_broadcast()
            || address.is_loopback()
        {
            return Err("invalid_input".into());
        }
        if !out.iter().any(|i: &Interface| i.address == address) {
            out.push(Interface { address, prefix });
        }
    }
    Ok(out)
}
fn child<'a>(e: &'a Element, name: &str, namespace: &str) -> Option<&'a Element> {
    e.children
        .iter()
        .filter_map(XMLNode::as_element)
        .find(|c| c.name == name && c.namespace.as_deref() == Some(namespace))
}
fn text(e: &Element) -> String {
    e.get_text()
        .map(|s| s.trim().to_owned())
        .unwrap_or_default()
}
fn scope_name(scopes: &str) -> Option<String> {
    let scope = scopes
        .split_whitespace()
        .find_map(|s| s.strip_prefix("onvif://www.onvif.org/name/"))?;
    if scope.len() > 384 {
        return None;
    }
    let mut bytes = Vec::new();
    let mut input = scope.as_bytes().iter().copied();
    while let Some(b) = input.next() {
        bytes.push(if b == b'%' {
            let hi = (input.next()? as char).to_digit(16)?;
            let lo = (input.next()? as char).to_digit(16)?;
            (hi * 16 + lo) as u8
        } else {
            b
        });
    }
    let decoded = String::from_utf8(bytes).ok()?;
    let mut utf16_units = 0;
    let name: String = decoded
        .chars()
        .filter(|c| {
            !c.is_control()
                && !matches!(*c, '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
        })
        .take(80)
        .take_while(|c| {
            utf16_units += c.len_utf16();
            utf16_units <= 120
        })
        .collect();
    let name = name.trim();
    (!name.is_empty()).then(|| name.to_owned())
}
fn endpoint_port(address: &str, peer: Ipv4Addr) -> Option<u16> {
    if address.len() > 2048 || address.chars().any(char::is_control) {
        return None;
    }
    let url = url::Url::parse(address).ok()?;
    if url.scheme() != "http" || url.host() != Some(url::Host::Ipv4(peer))
        || !url.username().is_empty() || url.password().is_some()
        || url.query().is_some() || url.fragment().is_some()
        // The existing ONVIF client uses this fixed device-service path.
        || url.path() != "/onvif/device_service"
    {
        return None;
    }
    url.port_or_known_default().filter(|p| *p != 0)
}
fn parse_response(bytes: &[u8], peer: Ipv4Addr, interface: Interface, id: &str) -> Vec<Value> {
    if bytes.len() > MAX_PACKET || !interface.contains(peer) {
        return vec![];
    }
    let Ok(source) = std::str::from_utf8(bytes) else {
        return vec![];
    };
    let upper = source.to_ascii_uppercase();
    if upper.contains("<!DOCTYPE") || upper.contains("<!ENTITY") {
        return vec![];
    }
    let mut depth = 0_usize;
    let mut count = 0_usize;
    for event in xml::reader::EventReader::from_str(source) {
        match event {
            Ok(xml::reader::XmlEvent::StartElement { .. }) => {
                depth += 1;
                count += 1;
                if depth > 32 || count > 1024 {
                    return vec![];
                }
            }
            Ok(xml::reader::XmlEvent::EndElement { .. }) => {
                depth = depth.saturating_sub(1);
            }
            Err(_) => return vec![],
            _ => {}
        }
    }
    let Ok(envelope) = Element::parse(bytes) else {
        return vec![];
    };
    if envelope.name != "Envelope" || envelope.namespace.as_deref() != Some(SOAP) {
        return vec![];
    }
    let Some(header) = child(&envelope, "Header", SOAP) else {
        return vec![];
    };
    if child(header, "RelatesTo", ADDRESSING).map(text).as_deref() != Some(id) {
        return vec![];
    }
    let Some(matches) =
        child(&envelope, "Body", SOAP).and_then(|body| child(body, "ProbeMatches", DISCOVERY))
    else {
        return vec![];
    };
    let mut devices = Vec::new();
    for matched in matches
        .children
        .iter()
        .filter_map(XMLNode::as_element)
        .filter(|c| c.name == "ProbeMatch" && c.namespace.as_deref() == Some(DISCOVERY))
        .take(MAX_DEVICES)
    {
        let Some(addresses) = child(matched, "XAddrs", DISCOVERY).map(text) else {
            continue;
        };
        let Some(port) = addresses
            .split_whitespace()
            .take(16)
            .find_map(|address| endpoint_port(address, peer))
        else {
            continue;
        };
        let name = child(matched, "Scopes", DISCOVERY)
            .and_then(|e| scope_name(&text(e)))
            .unwrap_or_else(|| format!("Camera {peer}"));
        // RTSP and DVRIP ports are app defaults; WS-Discovery advertises only ONVIF.
        devices.push(json!({"name":name,"host":peer.to_string(),"port":554,"controlPort":34567,"onvifPort":port,"source":"onvif"}));
    }
    devices
}
fn probe(id: &str) -> String {
    format!("<s:Envelope xmlns:s=\"{SOAP}\" xmlns:a=\"{ADDRESSING}\" xmlns:d=\"{DISCOVERY}\" xmlns:dn=\"http://www.onvif.org/ver10/network/wsdl\"><s:Header><a:MessageID>{id}</a:MessageID><a:To s:mustUnderstand=\"1\">urn:schemas-xmlsoap-org:ws:2005:04:discovery</a:To><a:Action s:mustUnderstand=\"1\">{DISCOVERY}/Probe</a:Action></s:Header><s:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></s:Body></s:Envelope>")
}
fn message_id() -> Result<String> {
    let mut bytes = [0_u8; 16];
    getrandom::getrandom(&mut bytes).map_err(|_| "internal")?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    Ok(format!(
        "uuid:{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    ))
}
#[cfg(unix)]
fn bind_interface(socket: &UdpSocket, address: Ipv4Addr) -> std::io::Result<()> {
    use std::os::fd::AsRawFd;
    let address = libc::in_addr {
        s_addr: u32::from_ne_bytes(address.octets()),
    };
    // IP_MULTICAST_IF pins outbound multicast to this LAN rather than the default/VPN route.
    let status = unsafe {
        libc::setsockopt(
            socket.as_raw_fd(),
            libc::IPPROTO_IP,
            libc::IP_MULTICAST_IF,
            (&address as *const libc::in_addr).cast(),
            std::mem::size_of_val(&address) as libc::socklen_t,
        )
    };
    if status == -1 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}
fn scan(
    interfaces: &[Interface],
    cancel: &AtomicBool,
    target: SocketAddrV4,
    duration: Duration,
) -> Result<Vec<Value>> {
    let deadline = Instant::now() + duration;
    let id = message_id()?;
    let probe = probe(&id);
    let mut sockets = Vec::new();
    for interface in interfaces {
        check_cancel(cancel)?;
        let ready = (|| -> std::io::Result<UdpSocket> {
            let socket = UdpSocket::bind(SocketAddrV4::new(interface.address, 0))?;
            bind_interface(&socket, interface.address)?;
            socket.set_multicast_ttl_v4(1)?;
            socket.set_nonblocking(true)?;
            socket.send_to(probe.as_bytes(), target)?;
            Ok(socket)
        })();
        if let Ok(socket) = ready {
            sockets.push((socket, *interface));
        }
    }
    if sockets.is_empty() {
        return Err("unreachable".into());
    }
    let mut devices = BTreeMap::new();
    let mut buffer = [0; MAX_PACKET + 1];
    let mut packets = 0;
    let mut next_probe = Instant::now() + Duration::from_secs(1);
    let mut sends = 1;
    while Instant::now() < deadline && packets < 512 && devices.len() < MAX_DEVICES {
        check_cancel(cancel)?;
        let resend = sends < 3 && Instant::now() >= next_probe;
        for (socket, interface) in &sockets {
            check_cancel(cancel)?;
            if Instant::now() >= deadline || packets >= 512 || devices.len() >= MAX_DEVICES {
                break;
            }
            if let Ok((len, SocketAddr::V4(peer))) = socket.recv_from(&mut buffer) {
                packets += 1;
                for device in parse_response(&buffer[..len], *peer.ip(), *interface, &id) {
                    devices.entry(*peer.ip()).or_insert(device);
                    if devices.len() >= MAX_DEVICES {
                        break;
                    }
                }
            }
            if resend {
                let _ = socket.send_to(probe.as_bytes(), target);
            }
        }
        if resend {
            sends += 1;
            next_probe = Instant::now() + Duration::from_secs(1);
        }
        std::thread::sleep(
            Duration::from_millis(20).min(deadline.saturating_duration_since(Instant::now())),
        );
    }
    check_cancel(cancel)?;
    Ok(devices.into_values().collect())
}
pub fn operation(v: &Value, cancel: Arc<AtomicBool>) -> Result<Value> {
    check_cancel(&cancel)?;
    let interfaces = interfaces(v)?;
    let devices = scan(
        &interfaces,
        &cancel,
        SocketAddrV4::new(Ipv4Addr::new(239, 255, 255, 250), 3702),
        Duration::from_secs(5),
    )?;
    Ok(json!({"devices":devices}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn interface() -> Interface {
        Interface {
            address: Ipv4Addr::new(192, 168, 1, 10),
            prefix: 24,
        }
    }
    fn reply(id: &str, address: &str, scopes: &str) -> String {
        format!("<s:Envelope xmlns:s='http://www.w3.org/2003/05/soap-envelope' xmlns:a='http://schemas.xmlsoap.org/ws/2004/08/addressing' xmlns:d='http://schemas.xmlsoap.org/ws/2005/04/discovery'><s:Header><a:RelatesTo>{id}</a:RelatesTo></s:Header><s:Body><d:ProbeMatches><d:ProbeMatch><d:XAddrs>{address}</d:XAddrs><d:Scopes>{scopes}</d:Scopes></d:ProbeMatch></d:ProbeMatches></s:Body></s:Envelope>")
    }
    #[test]
    fn accepts_only_matching_probe_and_peer_bound_onvif_endpoint() {
        let xml = reply(
            "uuid:test",
            "http://192.168.1.20:8899/onvif/device_service",
            "onvif://www.onvif.org/name/Front%20Door",
        );
        let found = parse_response(
            xml.as_bytes(),
            Ipv4Addr::new(192, 168, 1, 20),
            interface(),
            "uuid:test",
        );
        assert_eq!(
            found,
            vec![
                json!({"name":"Front Door","host":"192.168.1.20","port":554,"controlPort":34567,"onvifPort":8899,"source":"onvif"})
            ]
        );
        assert!(parse_response(
            xml.as_bytes(),
            Ipv4Addr::new(192, 168, 1, 20),
            interface(),
            "uuid:other"
        )
        .is_empty());
    }
    #[test]
    fn rejects_outside_lan_foreign_hosts_and_unsafe_endpoints() {
        for host in [
            "http://192.168.1.21/onvif/device_service",
            "http://evil.test/onvif/device_service",
            "http://u:p@192.168.1.20/onvif/device_service",
            "http://192.168.1.20:0/onvif/device_service",
            "http://192.168.1.20/onvif/device_service?q=x",
            "https://192.168.1.20/onvif/device_service",
            "http://192.168.1.20/other",
        ] {
            assert!(
                parse_response(
                    reply("id", host, "").as_bytes(),
                    Ipv4Addr::new(192, 168, 1, 20),
                    interface(),
                    "id"
                )
                .is_empty(),
                "{host}"
            );
        }
        assert!(parse_response(
            reply("id", "http://192.168.2.20/onvif/device_service", "").as_bytes(),
            Ipv4Addr::new(192, 168, 2, 20),
            interface(),
            "id"
        )
        .is_empty());
    }
    #[test]
    fn rejects_malformed_entities_deep_and_large_packets() {
        let valid = reply("id", "http://192.168.1.20/onvif/device_service", "");
        let deep = valid.replace(
            "<d:Scopes>",
            &format!("{}{}<d:Scopes>", "<x>".repeat(40), "</x>".repeat(40)),
        );
        let large = valid.replace("<d:Scopes>", &format!("<d:Scopes>{}", "x".repeat(65508)));
        let entities = format!(
            "<!DOCTYPE s:Envelope [<!ENTITY x 'bad'>]>{}",
            valid.replace("<d:Scopes>", "<d:Scopes>&x;")
        );
        for xml in ["<broken>".to_string(), entities, deep, large] {
            assert!(parse_response(
                xml.as_bytes(),
                Ipv4Addr::new(192, 168, 1, 20),
                interface(),
                "id"
            )
            .is_empty());
        }
    }
    #[test]
    fn respects_actual_prefix_network_and_broadcast_boundaries() {
        let interface = Interface {
            address: Ipv4Addr::new(192, 168, 2, 10),
            prefix: 23,
        };
        assert!(interface.contains(Ipv4Addr::new(192, 168, 3, 20)));
        assert!(!interface.contains(Ipv4Addr::new(192, 168, 4, 20)));
        assert!(!interface.contains(Ipv4Addr::new(192, 168, 2, 0)));
        assert!(!interface.contains(Ipv4Addr::new(192, 168, 3, 255)));
    }
    #[test]
    fn sanitizes_scope_name_and_bounds_malformed_work() {
        let scopes = format!(
            "onvif://www.onvif.org/name/%00Door%E2%80%AE{}",
            "x".repeat(90)
        );
        let found = parse_response(
            reply("id", "http://192.168.1.20/onvif/device_service", &scopes).as_bytes(),
            Ipv4Addr::new(192, 168, 1, 20),
            interface(),
            "id",
        );
        let name = found[0]["name"].as_str().unwrap();
        assert!(name.starts_with("Door"));
        assert_eq!(name.chars().count(), 80);
        assert!(!name.contains('\u{202e}'));
        let nodes = reply("id", "http://192.168.1.20/onvif/device_service", "").replace(
            "<d:Scopes>",
            &format!("{}<d:Scopes>", "<item/>".repeat(1100)),
        );
        assert!(parse_response(
            nodes.as_bytes(),
            Ipv4Addr::new(192, 168, 1, 20),
            interface(),
            "id"
        )
        .is_empty());
    }
    #[test]
    fn discovery_names_fit_android_utf16_profile_limit() {
        let scopes = format!("onvif://www.onvif.org/name/{}", "😀".repeat(80));
        let found = parse_response(
            reply("id", "http://192.168.1.20/onvif/device_service", &scopes).as_bytes(),
            Ipv4Addr::new(192, 168, 1, 20),
            interface(),
            "id",
        );
        let name = found[0]["name"].as_str().unwrap();
        assert!(name.encode_utf16().count() <= 120);
        assert_eq!(name, "😀".repeat(60));
    }
    fn loopback() -> Interface {
        Interface {
            address: Ipv4Addr::LOCALHOST,
            prefix: 8,
        }
    }
    #[test]
    fn udp_discovery_ignores_malformed_packets_and_deduplicates_replies() {
        let server = UdpSocket::bind("127.0.0.1:0").unwrap();
        server
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let target = match server.local_addr().unwrap() {
            SocketAddr::V4(a) => a,
            _ => unreachable!(),
        };
        let responder = std::thread::spawn(move || {
            let mut bytes = [0; 4096];
            let (len, peer) = server.recv_from(&mut bytes).unwrap();
            let request = Element::parse(&bytes[..len]).unwrap();
            let header = child(&request, "Header", SOAP).unwrap();
            let id = text(child(header, "MessageID", ADDRESSING).unwrap());
            let body = child(&request, "Body", SOAP).unwrap();
            assert!(child(body, "Probe", DISCOVERY).is_some());
            server.send_to(b"<malformed>", peer).unwrap();
            let packet = reply(
                &id,
                "http://127.0.0.1:8899/onvif/device_service",
                "onvif://www.onvif.org/name/Test%20Cam",
            );
            server.send_to(packet.as_bytes(), peer).unwrap();
            server.send_to(packet.as_bytes(), peer).unwrap();
        });
        let devices = scan(
            &[loopback()],
            &AtomicBool::new(false),
            target,
            Duration::from_millis(200),
        )
        .unwrap();
        responder.join().unwrap();
        assert_eq!(
            devices,
            vec![
                json!({"name":"Test Cam","host":"127.0.0.1","port":554,"controlPort":34567,"onvifPort":8899,"source":"onvif"})
            ]
        );
    }
    #[test]
    fn no_response_finishes_at_deadline_and_cancellation_interrupts_scan() {
        let server = UdpSocket::bind("127.0.0.1:0").unwrap();
        let target = match server.local_addr().unwrap() {
            SocketAddr::V4(a) => a,
            _ => unreachable!(),
        };
        let start = Instant::now();
        assert!(scan(
            &[loopback()],
            &AtomicBool::new(false),
            target,
            Duration::from_millis(100)
        )
        .unwrap()
        .is_empty());
        assert!(start.elapsed() < Duration::from_secs(1));
        let cancelled = Arc::new(AtomicBool::new(false));
        let signal = cancelled.clone();
        let canceller = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(50));
            signal.store(true, std::sync::atomic::Ordering::Relaxed);
        });
        let start = Instant::now();
        assert_eq!(
            scan(&[loopback()], &cancelled, target, Duration::from_secs(5)).unwrap_err(),
            "cancelled"
        );
        assert!(start.elapsed() < Duration::from_millis(500));
        canceller.join().unwrap();
    }
    #[test]
    fn validates_interface_input_before_sending() {
        for interfaces in [
            json!([]),
            json!([{"address":"127.0.0.1","prefixLength":8}]),
            json!([{"address":"192.168.1.2","prefixLength":0}]),
            json!([{"address":"invalid","prefixLength":24}]),
        ] {
            assert_eq!(
                operation(
                    &json!({"interfaces":interfaces}),
                    Arc::new(AtomicBool::new(false))
                )
                .unwrap_err(),
                "invalid_input"
            );
        }
    }
}
