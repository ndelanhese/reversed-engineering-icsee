use crate::{
    core::{self, Result},
    wire::check_cancel,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde_json::{json, Value};
use sha1::{Digest, Sha1};
use sha2::Sha256;
use std::{
    collections::BTreeMap,
    io::Read,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
use xmltree::{Element, XMLNode};
const SOAP: &str = "http://www.w3.org/2003/05/soap-envelope";
const LIMIT: usize = 2 * 1024 * 1024;
pub fn escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}
pub fn safe_service(address: &str, host: &str, port: u16) -> Result<String> {
    let url = url::Url::parse(address).map_err(|_| "invalid_response")?;
    if url.scheme() != "http"
        || url
            .host_str()
            .map(|h| h.trim_matches(['[', ']']).eq_ignore_ascii_case(host))
            != Some(true)
        || url.port_or_known_default() != Some(port)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
        || !url.path().starts_with("/onvif/")
        || address.len() > 2048
    {
        return Err("invalid_response".into());
    }
    Ok(url.to_string())
}
pub fn parse(source: &str) -> Result<Element> {
    let upper = source.to_ascii_uppercase();
    if source.len() > LIMIT || upper.contains("<!DOCTYPE") || upper.contains("<!ENTITY") {
        return Err("invalid_response".into());
    }
    // Reject deep input before the recursive tree builder allocates it.
    let mut depth = 0_usize;
    let mut nodes = 0_usize;
    for event in xml::reader::EventReader::from_str(source) {
        match event.map_err(|_| "invalid_response")? {
            xml::reader::XmlEvent::StartElement { .. } => {
                depth += 1;
                nodes += 1;
                if depth > 48 || nodes > 20_000 {
                    return Err("response_too_large".into());
                }
            }
            xml::reader::XmlEvent::EndElement { .. } => {
                depth = depth.checked_sub(1).ok_or("invalid_response")?;
            }
            _ => {}
        }
    }
    let e = Element::parse(source.as_bytes()).map_err(|_| "invalid_response")?;
    fn check(e: &Element, depth: usize, count: &mut usize) -> bool {
        *count += 1;
        depth <= 48
            && *count <= 20_000
            && e.children
                .iter()
                .filter_map(XMLNode::as_element)
                .all(|c| check(c, depth + 1, count))
    }
    if !check(&e, 0, &mut 0) {
        return Err("response_too_large".into());
    }
    Ok(e)
}
fn child<'a>(e: &'a Element, n: &str) -> Option<&'a Element> {
    e.children
        .iter()
        .filter_map(XMLNode::as_element)
        .find(|c| c.name == n)
}
fn children<'a>(e: &'a Element, n: &str) -> Vec<&'a Element> {
    e.children
        .iter()
        .filter_map(XMLNode::as_element)
        .filter(|c| c.name == n)
        .collect()
}
fn value(e: &Element) -> String {
    e.get_text()
        .map(|s| s.into_owned())
        .unwrap_or_default()
        .trim()
        .to_owned()
}
fn field(e: &Element, n: &str) -> String {
    child(e, n).map(value).unwrap_or_default()
}
fn at<'a>(e: &'a Element, path: &[&str]) -> Option<&'a Element> {
    if path.is_empty() {
        Some(e)
    } else {
        at(child(e, path[0])?, &path[1..])
    }
}
fn change(e: &mut Element, path: &[&str], v: &str) -> Result<()> {
    if path.is_empty() {
        e.children = vec![XMLNode::Text(v.to_owned())];
        return Ok(());
    }
    let c = e
        .children
        .iter_mut()
        .filter_map(XMLNode::as_mut_element)
        .find(|c| c.name == path[0])
        .ok_or("conflict")?;
    change(c, &path[1..], v)
}
fn serialize(e: &Element) -> Result<String> {
    let mut out = Vec::new();
    e.write_with_config(
        &mut out,
        xmltree::EmitterConfig::new().write_document_declaration(false),
    )
    .map_err(|_| "invalid_response")?;
    String::from_utf8(out).map_err(|_| "invalid_response".into())
}
fn namespace(service: &str) -> (&str, &str) {
    match service {
        "media" => ("http://www.onvif.org/ver10/media/wsdl", "trt"),
        "ptz" => ("http://www.onvif.org/ver20/ptz/wsdl", "tptz"),
        "imaging" => ("http://www.onvif.org/ver20/imaging/wsdl", "timg"),
        _ => ("http://www.onvif.org/ver10/device/wsdl", "tds"),
    }
}
fn random() -> Result<Vec<u8>> {
    let mut b = vec![0; 16];
    getrandom::getrandom(&mut b).map_err(|_| "internal")?;
    Ok(b)
}
fn wsse(user: &str, password: &str) -> Result<String> {
    let nonce = random()?;
    let date = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let mut hash = Sha1::new();
    hash.update(&nonce);
    hash.update(date.as_bytes());
    hash.update(password.as_bytes());
    let hash = B64.encode(hash.finalize());
    let nonce = B64.encode(nonce);
    let base = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-";
    Ok(format!("<wsse:Security s:mustUnderstand=\"1\" xmlns:wsse=\"{base}wssecurity-secext-1.0.xsd\" xmlns:wsu=\"{base}wssecurity-utility-1.0.xsd\"><wsse:UsernameToken><wsse:Username>{}</wsse:Username><wsse:Password Type=\"{base}username-token-profile-1.0#PasswordDigest\">{hash}</wsse:Password><wsse:Nonce EncodingType=\"{base}soap-message-security-1.0#Base64Binary\">{nonce}</wsse:Nonce><wsu:Created>{date}</wsu:Created></wsse:UsernameToken></wsse:Security>",escape(user)))
}
fn digest_fields(s: &str) -> Result<BTreeMap<String, String>> {
    if !s.to_ascii_lowercase().starts_with("digest ") || s.len() > 8192 {
        return Err("authentication".into());
    }
    let mut parts = Vec::new();
    let mut quoted = false;
    let mut start = 7;
    for (i, c) in s.char_indices().skip(7) {
        if c == '"' {
            quoted = !quoted;
        }
        if c == ',' && !quoted {
            parts.push(&s[start..i]);
            start = i + 1;
        }
    }
    parts.push(&s[start..]);
    let mut fields = BTreeMap::new();
    for p in parts {
        let (k, v) = p.trim().split_once('=').ok_or("authentication")?;
        fields.insert(
            k.trim().to_lowercase(),
            v.trim().trim_matches('"').to_owned(),
        );
    }
    if !fields.contains_key("realm") || fields.get("nonce").map(String::is_empty) != Some(false) {
        return Err("authentication".into());
    }
    Ok(fields)
}
fn digest_header(
    f: &BTreeMap<String, String>,
    user: &str,
    password: &str,
    uri: &str,
    nc: u32,
) -> Result<String> {
    let algorithm = f
        .get("algorithm")
        .map(String::as_str)
        .unwrap_or("MD5")
        .to_ascii_uppercase();
    if !["MD5", "MD5-SESS", "SHA-256", "SHA-256-SESS"].contains(&algorithm.as_str()) {
        return Err("authentication".into());
    }
    let hash = |s: &str| {
        if algorithm.starts_with("SHA-256") {
            format!("{:x}", Sha256::digest(s.as_bytes()))
        } else {
            format!("{:x}", md5::compute(s.as_bytes()))
        }
    };
    let quote = |s: &str| -> Result<String> {
        if s.chars().any(char::is_control) {
            return Err("invalid_input".into());
        }
        Ok(format!(
            "\"{}\"",
            s.replace('\\', "\\\\").replace('"', "\\\"")
        ))
    };
    let realm = f.get("realm").ok_or("authentication")?;
    let nonce = f.get("nonce").ok_or("authentication")?;
    let cnonce = B64.encode(random()?);
    let nc = format!("{nc:08x}");
    let mut ha1 = hash(&format!("{user}:{realm}:{password}"));
    if algorithm.ends_with("-SESS") {
        ha1 = hash(&format!("{ha1}:{nonce}:{cnonce}"));
    }
    let ha2 = hash(&format!("POST:{uri}"));
    let qop = f.contains_key("qop");
    if qop && !f["qop"].split(',').any(|s| s.trim() == "auth") {
        return Err("authentication".into());
    }
    let response = if qop {
        hash(&format!("{ha1}:{nonce}:{nc}:{cnonce}:auth:{ha2}"))
    } else {
        hash(&format!("{ha1}:{nonce}:{ha2}"))
    };
    let mut out = format!(
        "Digest username={}, realm={}, nonce={}, uri={}, response={}, algorithm={algorithm}",
        quote(user)?,
        quote(realm)?,
        quote(nonce)?,
        quote(uri)?,
        quote(&response)?
    );
    if qop {
        out += &format!(", qop=auth, nc={nc}");
    }
    if qop || algorithm.ends_with("-SESS") {
        out += &format!(", cnonce={}", quote(&cnonce)?);
    }
    if let Some(o) = f.get("opaque") {
        out += &format!(", opaque={}", quote(o)?);
    }
    Ok(out)
}
struct Client<'a> {
    v: &'a Value,
    cancel: Arc<AtomicBool>,
    agent: ureq::Agent,
    endpoints: BTreeMap<String, String>,
    digest: BTreeMap<String, String>,
    nc: u32,
}
impl<'a> Client<'a> {
    fn new(v: &'a Value, cancel: Arc<AtomicBool>) -> Result<Self> {
        core::host(v)?;
        core::port(v, "onvifPort", 8899)?;
        Ok(Self {
            v,
            cancel,
            agent: ureq::AgentBuilder::new()
                .timeout(Duration::from_secs(5))
                .redirects(0)
                .max_idle_connections(0)
                .build(),
            endpoints: BTreeMap::new(),
            digest: BTreeMap::new(),
            nc: 0,
        })
    }
    fn soap(
        &mut self,
        service: &str,
        action: &str,
        body: &str,
        read_only: bool,
    ) -> Result<Element> {
        check_cancel(&self.cancel)?;
        let host = core::host(self.v)?;
        let port = core::port(self.v, "onvifPort", 8899)?;
        let h = if host.contains(':') {
            format!("[{host}]")
        } else {
            host.to_owned()
        };
        let address = if service == "device" {
            format!("http://{h}:{port}/onvif/device_service")
        } else {
            self.endpoints.get(service).ok_or("unsupported")?.clone()
        };
        let url = url::Url::parse(&address).map_err(|_| "invalid_response")?;
        let uri = format!(
            "{}{}",
            url.path(),
            url.query().map(|q| format!("?{q}")).unwrap_or_default()
        );
        let (ns, prefix) = namespace(service);
        let user = core::text(self.v, "username")?;
        let password = core::text(self.v, "password")?;
        for attempt in 0..2 {
            check_cancel(&self.cancel)?;
            let envelope=format!("<s:Envelope xmlns:s=\"{SOAP}\" xmlns:tt=\"http://www.onvif.org/ver10/schema\" xmlns:tds=\"http://www.onvif.org/ver10/device/wsdl\" xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\" xmlns:tptz=\"http://www.onvif.org/ver20/ptz/wsdl\" xmlns:timg=\"http://www.onvif.org/ver20/imaging/wsdl\"><s:Header>{}</s:Header><s:Body><{prefix}:{action}>{body}</{prefix}:{action}></s:Body></s:Envelope>",wsse(user,password)?);
            if envelope.len() > LIMIT {
                return Err("invalid_input".into());
            }
            let mut request = self
                .agent
                .post(&address)
                .set(
                    "Content-Type",
                    &format!("application/soap+xml; charset=utf-8; action=\"{ns}/{action}\""),
                )
                .set("SOAPAction", &format!("\"{ns}/{action}\""));
            if !self.digest.is_empty() {
                self.nc += 1;
                request = request.set(
                    "Authorization",
                    &digest_header(&self.digest, user, password, &uri, self.nc)?,
                );
            }
            let response = match request.send_string(&envelope) {
                Ok(r) => r,
                Err(ureq::Error::Status(_, r)) => r,
                Err(_) => return Err("unreachable".into()),
            };
            if response.status() == 401 {
                if attempt == 0 && read_only {
                    self.digest = digest_fields(
                        response
                            .header("WWW-Authenticate")
                            .ok_or("authentication")?,
                    )?;
                    self.nc = 0;
                    continue;
                }
                return Err("authentication".into());
            }
            if response.status() == 403 {
                return Err("forbidden".into());
            }
            if !(200..300).contains(&response.status()) {
                return Err("rejected".into());
            }
            let mut bytes = Vec::new();
            response
                .into_reader()
                .take((LIMIT + 1) as u64)
                .read_to_end(&mut bytes)
                .map_err(|_| "invalid_response")?;
            let e = parse(std::str::from_utf8(&bytes).map_err(|_| "invalid_response")?)?;
            if e.name != "Envelope"
                || ![
                    Some(SOAP),
                    Some("http://schemas.xmlsoap.org/soap/envelope/"),
                ]
                .contains(&e.namespace.as_deref())
            {
                return Err("invalid_response".into());
            }
            let b = child(&e, "Body").ok_or("invalid_response")?;
            if let Some(f) = child(b, "Fault") {
                let fault = serialize(f)?;
                return Err(if fault.contains("NotAuthorized")
                    || fault.contains("FailedAuthentication")
                {
                    "authentication"
                } else if fault.contains("ActionNotSupported")
                    || fault.contains("OptionalActionNotImplemented")
                {
                    "unsupported"
                } else {
                    "rejected"
                }
                .into());
            }
            return child(b, &format!("{action}Response"))
                .filter(|c| c.namespace.as_deref() == Some(ns))
                .cloned()
                .ok_or("invalid_response".into());
        }
        Err("authentication".into())
    }
    fn discover(&mut self) -> Result<Vec<Value>> {
        let r = self.soap(
            "device",
            "GetServices",
            "<tds:IncludeCapability>false</tds:IncludeCapability>",
            true,
        )?;
        for service in children(&r, "Service") {
            let kind = match field(service, "Namespace").as_str() {
                "http://www.onvif.org/ver10/media/wsdl" => "media",
                "http://www.onvif.org/ver20/ptz/wsdl" => "ptz",
                "http://www.onvif.org/ver20/imaging/wsdl" => "imaging",
                _ => continue,
            };
            self.endpoints.insert(
                kind.into(),
                safe_service(
                    &field(service, "XAddr"),
                    core::host(self.v)?,
                    core::port(self.v, "onvifPort", 8899)?,
                )?,
            );
        }
        let r = self.soap("media", "GetProfiles", "", true)?;
        Ok(children(&r,"Profiles").iter().filter_map(|p|p.attributes.get("token").map(|token|json!({"token":token,"name":field(p,"Name"),"source":at(p,&["VideoSourceConfiguration","SourceToken"]).map(value),"ptz":child(p,"PTZConfiguration").and_then(|p|p.attributes.get("token"))}))).collect())
    }
    fn options(&mut self, p: &Value) -> Result<Element> {
        let token = p["ptz"].as_str().ok_or("unsupported")?;
        self.soap(
            "ptz",
            "GetConfigurationOptions",
            &format!(
                "<tptz:ConfigurationToken>{}</tptz:ConfigurationToken>",
                escape(token)
            ),
            true,
        )
    }
    fn stop(&mut self, body: &str) -> Result<Element> {
        let old = self.cancel.clone();
        self.cancel = Arc::new(AtomicBool::new(false));
        let r = self.soap(
            "ptz",
            "Stop",
            &format!("{body}<tptz:PanTilt>true</tptz:PanTilt><tptz:Zoom>true</tptz:Zoom>"),
            false,
        );
        self.cancel = old;
        r
    }
}
fn range(e: Option<&Element>) -> Option<(f64, f64)> {
    let e = e?;
    let a = field(e, "Min").parse::<f64>().ok()?;
    let b = field(e, "Max").parse::<f64>().ok()?;
    if a.is_finite() && b.is_finite() && a <= b {
        Some((a, b))
    } else {
        None
    }
}
fn seconds(s: &str) -> Result<f64> {
    s.strip_prefix("PT")
        .and_then(|s| s.strip_suffix('S'))
        .and_then(|s| s.parse::<f64>().ok())
        .filter(|n| n.is_finite() && *n > 0.0)
        .ok_or("unsupported".into())
}
fn image_fields(settings: &Element, options: &Element) -> Vec<Value> {
    fn walk(
        s: &Element,
        o: Option<&Element>,
        path: String,
        advertised: Vec<String>,
        out: &mut Vec<Value>,
    ) {
        let kids: Vec<_> = s.children.iter().filter_map(XMLNode::as_element).collect();
        if kids.is_empty() {
            let r = range(o);
            let mut choices: Vec<_> = o
                .map(|o| children(o, "Items").iter().map(|e| value(e)).collect())
                .unwrap_or_default();
            if choices.is_empty() {
                choices = advertised;
            }
            out.push(json!({"path":path,"value":value(s),"range":r.map(|(a,b)|vec![a,b]),"choices":choices,"writable":r.is_some()||!choices.is_empty()}));
        } else {
            for c in kids {
                let p = if path.is_empty() {
                    c.name.clone()
                } else {
                    format!("{path}/{}", c.name)
                };
                let choices = o
                    .map(|o| {
                        children(o, &c.name)
                            .iter()
                            .filter(|e| e.children.iter().all(|n| n.as_element().is_none()))
                            .map(|e| value(e))
                            .filter(|v| !v.is_empty())
                            .collect()
                    })
                    .unwrap_or_default();
                walk(c, o.and_then(|o| child(o, &c.name)), p, choices, out);
            }
        }
    }
    let mut out = Vec::new();
    walk(settings, Some(options), String::new(), Vec::new(), &mut out);
    for f in &mut out {
        if f["path"] == "IrCutFilter" {
            let choices: Vec<_> = children(options, "IrCutFilterModes")
                .iter()
                .map(|e| value(e))
                .collect();
            if !choices.is_empty() {
                f["choices"] = json!(choices);
                f["writable"] = json!(true);
            }
        }
    }
    out
}

pub fn operation(v: &Value, cancel: Arc<AtomicBool>) -> Result<Value> {
    let op = core::text(v, "op")?;
    let mut client = Client::new(v, cancel.clone())?;
    let mut profiles = client.discover()?;
    if op == "onvif_discover" {
        for p in &mut profiles {
            if let Ok(o) = client.options(p) {
                let c = child(&o, "PTZConfigurationOptions").ok_or("invalid_response")?;
                p["pan"] = json!(range(at(
                    c,
                    &["Spaces", "ContinuousPanTiltVelocitySpace", "XRange"]
                )));
                p["tilt"] = json!(range(at(
                    c,
                    &["Spaces", "ContinuousPanTiltVelocitySpace", "YRange"]
                )));
                p["zoom"] = json!(range(at(
                    c,
                    &["Spaces", "ContinuousZoomVelocitySpace", "XRange"]
                )));
            }
        }
        return Ok(json!({"profiles":profiles}));
    }
    let token = core::text(v, "profile")?;
    let p = profiles
        .iter()
        .find(|p| p["token"] == token)
        .ok_or("unsupported")?;
    let body = format!("<tptz:ProfileToken>{}</tptz:ProfileToken>", escape(token));
    match op {
        "onvif_stop" => {
            client.stop(&body)?;
            Ok(json!({}))
        }
        "onvif_move" => {
            let o = client.options(p)?;
            let o = child(&o, "PTZConfigurationOptions").ok_or("invalid_response")?;
            let min = seconds(
                &at(o, &["PTZTimeout", "Min"])
                    .map(value)
                    .unwrap_or("PT0.1S".into()),
            )?;
            let max = seconds(
                &at(o, &["PTZTimeout", "Max"])
                    .map(value)
                    .unwrap_or("PT1S".into()),
            )?;
            if min > 1.0 || max < min {
                return Err("unsupported".into());
            }
            let timeout = 0.3_f64.max(min).min(max).min(1.0);
            let pan = v["pan"].as_f64().unwrap_or(0.0);
            let tilt = v["tilt"].as_f64().unwrap_or(0.0);
            let zoom = v["zoom"].as_f64().unwrap_or(0.0);
            for (n, path) in [
                (
                    pan,
                    vec!["Spaces", "ContinuousPanTiltVelocitySpace", "XRange"],
                ),
                (
                    tilt,
                    vec!["Spaces", "ContinuousPanTiltVelocitySpace", "YRange"],
                ),
                (
                    zoom,
                    vec!["Spaces", "ContinuousZoomVelocitySpace", "XRange"],
                ),
            ] {
                if !n.is_finite() {
                    return Err("invalid_input".into());
                }
                if n != 0.0 {
                    let (a, b) = range(at(o, &path)).ok_or("unsupported")?;
                    if n < a || n > b {
                        return Err("invalid_input".into());
                    }
                }
            }
            let mut velocity = String::new();
            if pan != 0.0 || tilt != 0.0 {
                velocity += &format!("<tt:PanTilt x=\"{pan}\" y=\"{tilt}\"/>");
            }
            if zoom != 0.0 {
                velocity += &format!("<tt:Zoom x=\"{zoom}\"/>");
            }
            let result=client.soap("ptz","ContinuousMove",&format!("{body}<tptz:Velocity>{velocity}</tptz:Velocity><tptz:Timeout>PT{timeout}S</tptz:Timeout>"),false);
            let deadline = Instant::now() + Duration::from_secs_f64(timeout);
            if result.is_ok() {
                while Instant::now() < deadline && !cancel.load(Ordering::Relaxed) {
                    std::thread::sleep(Duration::from_millis(20));
                }
            }
            let stop = client.stop(&body);
            result?;
            stop?;
            check_cancel(&cancel)?;
            Ok(json!({}))
        }
        "onvif_presets" => {
            let r = client.soap("ptz", "GetPresets", &body, true)?;
            Ok(
                json!({"presets":children(&r,"Preset").iter().filter_map(|p|p.attributes.get("token").map(|t|json!({"token":t,"name":field(p,"Name")}))).collect::<Vec<_>>()}),
            )
        }
        "onvif_save_preset" => {
            let r = client.soap(
                "ptz",
                "SetPreset",
                &format!(
                    "{body}<tptz:PresetName>{}</tptz:PresetName>",
                    escape(core::text(v, "name")?)
                ),
                false,
            )?;
            Ok(json!({"token":field(&r,"PresetToken")}))
        }
        "onvif_goto_preset" => {
            let result: Result<Value> = (|| {
                client.soap(
                    "ptz",
                    "GotoPreset",
                    &format!(
                        "{body}<tptz:PresetToken>{}</tptz:PresetToken>",
                        escape(core::text(v, "preset")?)
                    ),
                    false,
                )?;
                let deadline = Instant::now() + Duration::from_secs(15);
                while Instant::now() < deadline {
                    check_cancel(&cancel)?;
                    let r = client.soap("ptz", "GetStatus", &body, true)?;
                    let m = at(&r, &["PTZStatus", "MoveStatus"]).ok_or("unsupported")?;
                    let pan = field(m, "PanTilt");
                    let zoom = field(m, "Zoom");
                    if (!pan.is_empty() || !zoom.is_empty())
                        && (pan.is_empty() || pan == "IDLE")
                        && (zoom.is_empty() || zoom == "IDLE")
                    {
                        return Ok(json!({}));
                    }
                    std::thread::sleep(Duration::from_millis(250));
                }
                Err("timeout".into())
            })();
            let stop = client.stop(&body);
            let r = result?;
            stop?;
            Ok(r)
        }
        "onvif_imaging" | "onvif_set_imaging" => {
            let source = p["source"].as_str().ok_or("unsupported")?;
            let body = format!(
                "<timg:VideoSourceToken>{}</timg:VideoSourceToken>",
                escape(source)
            );
            let settings = client.soap("imaging", "GetImagingSettings", &body, true)?;
            let mut settings = child(&settings, "ImagingSettings")
                .ok_or("invalid_response")?
                .clone();
            let options = client.soap("imaging", "GetOptions", &body, true)?;
            let options = child(&options, "ImagingOptions").ok_or("invalid_response")?;
            let fields = image_fields(&settings, options);
            if op == "onvif_set_imaging" {
                let changes = v["changes"]
                    .as_array()
                    .filter(|a| a.len() <= 128)
                    .ok_or("invalid_input")?;
                for edit in changes {
                    let path = core::text(edit, "path")?;
                    let old = core::text(edit, "original")?;
                    let new = core::text(edit, "value")?;
                    let f = fields
                        .iter()
                        .find(|f| f["path"] == path && f["writable"] == true)
                        .ok_or("read_only")?;
                    if f["value"] != old {
                        return Err("conflict".into());
                    }
                    if let Some(r) = f["range"].as_array() {
                        let n = new.parse::<f64>().map_err(|_| "invalid_input")?;
                        if !n.is_finite()
                            || n < r[0].as_f64().unwrap()
                            || n > r[1].as_f64().unwrap()
                        {
                            return Err("invalid_input".into());
                        }
                    } else if !f["choices"].as_array().unwrap().iter().any(|v| v == new) {
                        return Err("invalid_input".into());
                    }
                    change(&mut settings, &path.split('/').collect::<Vec<_>>(), new)?;
                }
                client
                    .soap(
                        "imaging",
                        "SetImagingSettings",
                        &format!(
                            "{body}{}<timg:ForcePersistence>true</timg:ForcePersistence>",
                            serialize(&settings)?
                        ),
                        false,
                    )
                    .map_err(|_| "write_uncertain")?;
                let readback = client
                    .soap("imaging", "GetImagingSettings", &body, true)
                    .map_err(|_| "write_uncertain")?;
                let readback = child(&readback, "ImagingSettings").ok_or("write_uncertain")?;
                for edit in changes {
                    let path = core::text(edit, "path")?;
                    if at(readback, &path.split('/').collect::<Vec<_>>())
                        .map(value)
                        .as_deref()
                        != edit["value"].as_str()
                    {
                        return Err("verification".into());
                    }
                }
                Ok(json!({"fields":image_fields(readback,options)}))
            } else {
                Ok(json!({"fields":fields}))
            }
        }
        _ => Err("unsupported".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn imaging_enumerations_keep_all_advertised_choices() {
        let settings=parse("<ImagingSettings><WhiteBalance><Mode>AUTO</Mode></WhiteBalance><Brightness>10</Brightness><Unknown>value</Unknown></ImagingSettings>").unwrap();
        let options=parse("<Options><WhiteBalance><Mode>AUTO</Mode><Mode>MANUAL</Mode></WhiteBalance><Brightness><Min>0</Min><Max>100</Max></Brightness></Options>").unwrap();
        let fields = image_fields(&settings, &options);
        let mode = fields
            .iter()
            .find(|f| f["path"] == "WhiteBalance/Mode")
            .unwrap();
        assert_eq!(mode["choices"], json!(["AUTO", "MANUAL"]));
        assert_eq!(mode["writable"], true);
        assert_eq!(
            fields.iter().find(|f| f["path"] == "Unknown").unwrap()["writable"],
            false
        );
    }
}
