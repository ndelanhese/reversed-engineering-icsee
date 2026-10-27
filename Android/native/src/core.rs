use serde_json::Value;
pub type Result<T> = std::result::Result<T, String>;
pub fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    let s = v[key].as_str().ok_or("invalid_input")?;
    if s.len() > 8192 || s.chars().any(|c| c.is_control()) {
        return Err("invalid_input".into());
    }
    Ok(s)
}
pub fn port(v: &Value, key: &str, default: u16) -> Result<u16> {
    match v.get(key) {
        None => Ok(default),
        Some(n) => n
            .as_u64()
            .filter(|n| *n > 0 && *n <= 65535)
            .map(|n| n as u16)
            .ok_or("invalid_input".into()),
    }
}
pub fn host(v: &Value) -> Result<&str> {
    let s = text(v, "host")?;
    if s.is_empty()
        || s.len() > 253
        || !s.as_bytes()[0].is_ascii_alphanumeric()
        || !s
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b".-:".contains(&c))
    {
        return Err("invalid_input".into());
    }
    Ok(s)
}
pub fn sofia(password: &str) -> String {
    const ALPHABET: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    md5::compute(password.as_bytes())
        .0
        .chunks_exact(2)
        .map(|p| ALPHABET[(usize::from(p[0]) + usize::from(p[1])) % 62] as char)
        .collect()
}
pub fn escape_uri(s: &str) -> String {
    s.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}
pub fn rtsp(v: &Value, compatibility: bool) -> Result<String> {
    let h = host(v)?;
    let p = port(v, "port", 554)?;
    let channel = v.get("channel").and_then(Value::as_u64).unwrap_or(1);
    let username = text(v, "username")?;
    let password = text(v, "password")?;
    if !(1..=64).contains(&channel) || username.is_empty() {
        return Err("invalid_input".into());
    }
    let h = if h.contains(':') {
        format!("[{h}]")
    } else {
        h.to_owned()
    };
    let auth = if compatibility {
        format!("&password={}", sofia(password))
    } else {
        String::new()
    };
    let u = escape_uri(username);
    let pw = escape_uri(password);
    let sub = u8::from(v["substream"].as_bool().unwrap_or(false));
    Ok(format!(
        "rtsp://{u}:{pw}@{h}:{p}/user={u}{auth}&channel={channel}&stream={sub}.sdp?real_stream"
    ))
}
pub fn secret_key(key: &str) -> bool {
    let k = key.to_ascii_lowercase();
    ["password", "passwd", "pwd", "secret", "token", "privatekey"]
        .iter()
        .any(|s| k.contains(s))
}
pub fn patch(original: &Value, updated: &Value, fresh: &Value) -> Result<Value> {
    if original == updated {
        return Ok(fresh.clone());
    }
    match (original, updated, fresh) {
        (Value::Object(a), Value::Object(b), Value::Object(c))
            if a.len() == b.len() && a.keys().all(|k| b.contains_key(k)) =>
        {
            let mut out = c.clone();
            for (k, old) in a {
                if old != &b[k] && secret_key(k) {
                    return Err("read_only".into());
                }
                out.insert(k.clone(), patch(old, &b[k], c.get(k).ok_or("conflict")?)?);
            }
            Ok(Value::Object(out))
        }
        (Value::Array(a), Value::Array(b), Value::Array(c))
            if a.len() == b.len() && a.len() == c.len() =>
        {
            Ok(Value::Array(
                a.iter()
                    .zip(b)
                    .zip(c)
                    .map(|((a, b), c)| patch(a, b, c))
                    .collect::<Result<Vec<_>>>()?,
            ))
        }
        (Value::Bool(_), Value::Bool(_), _)
        | (Value::Number(_), Value::Number(_), _)
        | (Value::String(_), Value::String(_), _)
            if original == fresh =>
        {
            Ok(updated.clone())
        }
        _ => Err("conflict".into()),
    }
}
pub fn edits_verified(original: &Value, updated: &Value, current: &Value) -> bool {
    if original == updated {
        return true;
    }
    match (original, updated, current) {
        (Value::Object(a), Value::Object(b), Value::Object(c)) => a.iter().all(|(k, v)| {
            b.get(k)
                .zip(c.get(k))
                .is_some_and(|(b, c)| edits_verified(v, b, c))
        }),
        (Value::Array(a), Value::Array(b), Value::Array(c)) => {
            a.len() == b.len()
                && a.len() == c.len()
                && a.iter()
                    .zip(b)
                    .zip(c)
                    .all(|((a, b), c)| edits_verified(a, b, c))
        }
        _ => updated == current,
    }
}
