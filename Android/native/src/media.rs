use crate::{core::Result, wire::check_cancel};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    fs::File,
    io::{Read, Seek},
    path::Path,
    sync::atomic::AtomicBool,
};
struct Bits {
    bytes: Vec<u8>,
    offset: usize,
}
impl Bits {
    fn new(source: &[u8]) -> Self {
        let mut bytes = Vec::new();
        let mut zeros = 0;
        for &b in source {
            if zeros >= 2 && b == 3 {
                zeros = 0;
                continue;
            }
            bytes.push(b);
            zeros = if b == 0 { zeros + 1 } else { 0 };
        }
        Self { bytes, offset: 0 }
    }
    fn read(&mut self, n: usize) -> Result<u32> {
        if n > 31 || self.offset + n > self.bytes.len() * 8 {
            return Err("invalid_media".into());
        }
        let mut v = 0;
        for _ in 0..n {
            v = v << 1 | u32::from((self.bytes[self.offset / 8] >> (7 - self.offset % 8)) & 1);
            self.offset += 1;
        }
        Ok(v)
    }
    fn skip(&mut self, n: usize) -> Result<()> {
        if self.offset + n > self.bytes.len() * 8 {
            return Err("invalid_media".into());
        }
        self.offset += n;
        Ok(())
    }
    fn ue(&mut self) -> Result<u32> {
        let mut zeros = 0;
        while self.read(1)? == 0 {
            zeros += 1;
            if zeros > 30 {
                return Err("invalid_media".into());
            }
        }
        Ok((1 << zeros) - 1 + self.read(zeros)?)
    }
}
fn hevc_reordering(nal: &[u8]) -> Result<()> {
    let mut b = Bits::new(&nal[2..]);
    b.skip(4)?;
    let layers = b.read(3)? as usize;
    if layers > 6 {
        return Err("invalid_media".into());
    }
    b.skip(1 + 96)?;
    let mut flags = Vec::new();
    for _ in 0..layers {
        flags.push((b.read(1)?, b.read(1)?));
    }
    if layers > 0 {
        b.skip((8 - layers) * 2)?;
    }
    for (p, l) in flags {
        if p == 1 {
            b.skip(88)?;
        }
        if l == 1 {
            b.skip(8)?;
        }
    }
    b.ue()?;
    let chroma = b.ue()?;
    if chroma > 3 {
        return Err("invalid_media".into());
    }
    if chroma == 3 {
        b.skip(1)?;
    }
    b.ue()?;
    b.ue()?;
    if b.read(1)? == 1 {
        for _ in 0..4 {
            b.ue()?;
        }
    }
    b.ue()?;
    b.ue()?;
    b.ue()?;
    let all = b.read(1)? == 1;
    for _ in if all { 0..=layers } else { layers..=layers } {
        b.ue()?;
        if b.ue()? != 0 {
            return Err("reordered_video".into());
        }
        b.ue()?;
    }
    Ok(())
}
fn units(b: &[u8]) -> Result<Vec<&[u8]>> {
    let mut starts = Vec::new();
    let mut i = 0;
    while i + 2 < b.len() {
        if b[i..].starts_with(&[0, 0, 0, 1]) {
            starts.push((i, 4));
            i += 4;
        } else if b[i..].starts_with(&[0, 0, 1]) {
            starts.push((i, 3));
            i += 3;
        } else {
            i += 1;
        }
    }
    if starts.is_empty() || b[..starts[0].0].iter().any(|b| *b != 0) {
        return Err("invalid_media".into());
    }
    starts
        .iter()
        .enumerate()
        .map(|(i, (start, len))| {
            let mut end = starts.get(i + 1).map(|p| p.0).unwrap_or(b.len());
            let start = start + len;
            while end > start && b[end - 1] == 0 {
                end -= 1;
            }
            if end <= start {
                Err("invalid_media".into())
            } else {
                Ok(&b[start..end])
            }
        })
        .collect()
}
fn camera_clock(n: u32) -> Result<i64> {
    let d = chrono::NaiveDate::from_ymd_opt(2000 + (n >> 26) as i32, n >> 22 & 15, n >> 17 & 31)
        .and_then(|d| d.and_hms_opt(n >> 12 & 31, n >> 6 & 63, n & 63))
        .ok_or("invalid_time")?;
    Ok(d.and_utc().timestamp())
}
pub fn index(path: &Path, cancel: &AtomicBool) -> Result<Value> {
    let mut file = File::open(path).map_err(|_| "file_io")?;
    let length = file.metadata().map_err(|_| "file_io")?.len();
    if length > 2 * 1024 * 1024 * 1024 {
        return Err("response_too_large".into());
    }
    let mut configuration = None;
    let mut parameters = BTreeMap::<u8, Vec<u8>>::new();
    let mut samples = Vec::<(u64, u32, bool, Option<i64>)>::new();
    let mut audio = Vec::new();
    let mut audio_config = None;
    let mut audio_unsupported = false;
    let mut previous_key = None;
    loop {
        check_cancel(cancel)?;
        let offset = file.stream_position().map_err(|_| "file_io")?;
        if offset == length {
            break;
        }
        let mut header = [0_u8; 16];
        file.read_exact(&mut header[..1])
            .map_err(|_| "invalid_media")?;
        if header[0] == 255 {
            let remaining = length - offset;
            if samples.is_empty() || remaining > 1023 || length % 1024 != 0 {
                return Err("invalid_media".into());
            }
            let mut pad = Vec::new();
            file.read_to_end(&mut pad).map_err(|_| "file_io")?;
            if pad.iter().any(|b| *b != 255) {
                return Err("invalid_media".into());
            }
            break;
        }
        file.read_exact(&mut header[1..8])
            .map_err(|_| "invalid_media")?;
        let kind = header[3];
        if header[..3] != [0, 0, 1] || ![0xfc, 0xfd, 0xfe, 0xfa, 0xf9].contains(&kind) {
            return Err("invalid_media".into());
        }
        let size = if [0xfc, 0xfe].contains(&kind) { 16 } else { 8 };
        if size == 16 {
            file.read_exact(&mut header[8..16])
                .map_err(|_| "invalid_media")?;
        }
        let count = if size == 16 {
            u32::from_le_bytes(header[12..16].try_into().unwrap())
        } else if kind == 0xfd {
            u32::from_le_bytes(header[4..8].try_into().unwrap())
        } else {
            u32::from(u16::from_le_bytes([header[6], header[7]]))
        };
        if count == 0
            || count > 16 * 1024 * 1024
            || offset + size as u64 + u64::from(count) > length
        {
            return Err("invalid_media".into());
        }
        let mut payload = vec![0; count as usize];
        file.read_exact(&mut payload).map_err(|_| "invalid_media")?;
        if kind == 0xfa {
            if audio.len() >= 200_000 {
                return Err("response_too_large".into());
            }
            let c = header[4] & 15;
            if ![10, 14].contains(&c)
                || header[5] != 2
                || audio_config.map(|v| v != c).unwrap_or(false)
            {
                audio_unsupported = true;
            }
            audio_config = Some(c);
            audio.push(json!([offset + 8, count]));
            continue;
        }
        if ![0xfc, 0xfd].contains(&kind) {
            continue;
        }
        let timestamp = if kind == 0xfc {
            let c = (
                header[4] & 15,
                header[5] & 31,
                (((u32::from(header[4] >> 4) & 3) << 8) | u32::from(header[6])) * 8,
                (((u32::from(header[4] >> 6) & 3) << 8) | u32::from(header[7])) * 8,
            );
            if ![2, 3].contains(&c.0) || c.1 == 0 || c.1 > 30 || c.2 == 0 || c.3 == 0 {
                return Err("unsupported_video".into());
            }
            if configuration.map(|old| old != c).unwrap_or(false) {
                return Err("configuration_changed".into());
            }
            configuration = Some(c);
            let t = camera_clock(u32::from_le_bytes(header[8..12].try_into().unwrap()))?;
            if previous_key.map(|old| t < old).unwrap_or(false) {
                return Err("invalid_time".into());
            }
            previous_key = Some(t);
            Some(t)
        } else {
            None
        };
        let codec = configuration.ok_or("missing_parameters")?.0;
        let mut key = false;
        let mut slice = false;
        for nal in units(&payload)? {
            let first = nal[0];
            if first & 128 != 0 {
                return Err("invalid_media".into());
            }
            let t = if codec == 2 {
                first & 31
            } else {
                first >> 1 & 63
            };
            if codec == 3
                && (nal.len() < 2
                    || nal[1] & 7 == 0
                    || ((first & 1) << 5 | nal[1] >> 3) != 0
                    || t > 40)
            {
                return Err("invalid_media".into());
            }
            let parameter = if codec == 2 {
                [7, 8].contains(&t)
            } else {
                [32, 33, 34].contains(&t)
            };
            if parameter {
                if let Some(old) = parameters.get(&t) {
                    if old != nal {
                        return Err("configuration_changed".into());
                    }
                }
                if codec == 3 && t == 33 {
                    hevc_reordering(nal)?;
                }
                parameters.insert(t, nal.to_vec());
            } else if codec == 2 {
                if ![1, 5, 6, 9, 10, 11, 12].contains(&t) {
                    return Err("unsupported_video".into());
                }
                if [1, 5].contains(&t) {
                    let mut b = Bits::new(&nal[1..]);
                    b.ue()?;
                    let st = b.ue()?;
                    if st > 9 {
                        return Err("invalid_media".into());
                    }
                    if st % 5 == 1 {
                        return Err("reordered_video".into());
                    }
                    slice = true;
                    key |= t == 5;
                }
            } else if t <= 31 {
                slice = true;
                key |= (16..=21).contains(&t);
            }
        }
        if slice {
            if samples.is_empty() && !key {
                return Err("missing_parameters".into());
            }
            samples.push((offset + size as u64, count, key, timestamp));
        }
        if samples.len() > 100_000 || audio.len() > 200_000 {
            return Err("response_too_large".into());
        }
    }
    let (codec, fps, width, height) = configuration.ok_or("unsupported_video")?;
    if samples.is_empty() {
        return Err("unsupported_video".into());
    }
    let types = if codec == 2 {
        vec![7, 8]
    } else {
        vec![32, 33, 34]
    };
    let sets = types
        .iter()
        .map(|t| {
            parameters
                .get(t)
                .map(|p| {
                    let mut b = vec![0, 0, 0, 1];
                    b.extend(p);
                    b
                })
                .ok_or("missing_parameters".to_owned())
        })
        .collect::<Result<Vec<_>>>()?;
    let csd = if codec == 2 {
        sets.iter().map(|s| B64.encode(s)).collect::<Vec<_>>()
    } else {
        vec![B64.encode(sets.concat())]
    };
    let declared = 1.0 / f64::from(fps);
    let mut span = 0.0;
    let mut last = None;
    let (mut n, mut sx, mut sy, mut sxx, mut sxy) = (1.0, 0.0, 0.0, 0.0, 0.0);
    let mut observed_index = 0;
    for (i, s) in samples.iter().enumerate() {
        if let Some(t) = s.3 {
            if let Some((old_index, old_time)) = last {
                let delta = (t - old_time) as f64;
                if delta > 0.0 {
                    let nominal = (i - old_index) as f64 * declared;
                    span += delta.min(nominal + 1.0).min(if delta > nominal + 1.000001 {
                        nominal
                    } else {
                        delta
                    });
                    let x = i as f64;
                    n += 1.0;
                    sx += x;
                    sy += span;
                    sxx += x * x;
                    sxy += x * span;
                    observed_index = i;
                }
            }
            last = Some((i, t));
        }
    }
    let denominator = n * sxx - sx * sx;
    let estimate = if denominator > 0.0 {
        (n * sxy - sx * sy) / denominator
    } else {
        declared
    };
    let period = if span >= 10.0
        && ((observed_index as f64) * declared - span).abs() > 1.0
        && estimate.is_finite()
        && estimate >= declared * 0.5
        && estimate <= declared * 2.0
    {
        estimate
    } else {
        declared
    };
    let mut pts = 0.0;
    let mut anchor = None;
    let mut result = Vec::with_capacity(samples.len());
    for (i, s) in samples.iter().enumerate() {
        if let Some(t) = s.3 {
            if let Some((old_index, old_time)) = anchor {
                let delta = (t - old_time) as f64;
                let nominal = (i - old_index) as f64 * period;
                if delta > nominal + 1.000001 {
                    pts += delta - nominal;
                }
            }
            anchor = Some((i, t));
        }
        result.push(json!([s.0, s.1, (pts * 1_000_000.0).round() as u64, s.2]));
        pts += period;
    }
    Ok(
        json!({"mime":if codec==2{"video/avc"}else{"video/hevc"},"width":width,"height":height,"csd":csd,"samples":result,"durationUs":(pts*1_000_000.0).round() as u64,"audio":audio,"audioCodec":if audio_unsupported{None}else{audio_config},"timingApproximate":true}),
    )
}
