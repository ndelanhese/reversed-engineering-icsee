use crate::{
    core::{self, Result},
    wire::{self, Session},
};
use chrono::{Datelike, NaiveDate, NaiveDateTime};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    fs::{self, OpenOptions},
    io::Write,
    sync::{atomic::AtomicBool, Arc},
    time::{Duration, Instant},
};
pub fn clock(s: &str) -> Result<NaiveDateTime> {
    if s.len() != 19 {
        return Err("invalid_time".into());
    }
    NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S").map_err(|_| "invalid_time".into())
}
fn record(raw: &Value, channel: u64, sub: bool) -> Result<Value> {
    let file = core::text(raw, "FileName")?;
    if file.is_empty() || file.len() > 4096 {
        return Err("invalid_response".into());
    }
    let begin = clock(core::text(raw, "BeginTime")?)?;
    let end = clock(core::text(raw, "EndTime")?)?;
    if end < begin {
        return Err("invalid_response".into());
    }
    let c = raw
        .get("Channel")
        .map(wire::unsigned)
        .transpose()?
        .unwrap_or(channel);
    let s = raw
        .get("StreamType")
        .map(wire::unsigned)
        .transpose()?
        .unwrap_or(u64::from(sub));
    if c > 255 || s > 1 {
        return Err("invalid_response".into());
    }
    let bytes = raw
        .get("FileLength")
        .map(|v| -> Result<u64> {
            wire::unsigned(v)?
                .checked_mul(1024)
                .ok_or("invalid_response".into())
        })
        .transpose()?;
    Ok(
        json!({"file":file,"begin":begin.to_string(),"end":end.to_string(),"bytes":bytes,"channel":c,"substream":s==1}),
    )
}
pub fn listing(v: &Value, cancel: Arc<AtomicBool>) -> Result<Value> {
    let date =
        NaiveDate::parse_from_str(core::text(v, "day")?, "%Y-%m-%d").map_err(|_| "invalid_time")?;
    let start = date.and_hms_opt(0, 0, 0).ok_or("invalid_time")?;
    let end = start
        .checked_add_signed(chrono::Duration::seconds(86_399))
        .ok_or("invalid_time")?;
    let mut cursor = start
        .checked_sub_signed(chrono::Duration::days(1))
        .ok_or("invalid_time")?;
    let channel = v["channel"]
        .as_u64()
        .unwrap_or(1)
        .checked_sub(1)
        .filter(|n| *n <= 255)
        .ok_or("invalid_input")?;
    let sub = v["substream"].as_bool().unwrap_or(false);
    let mut session = Session::login(v, cancel.clone())?;
    let deadline = Instant::now() + Duration::from_secs(45);
    let mut records = BTreeMap::new();
    let mut complete = false;
    for _ in 0..128 {
        wire::check_cancel(&cancel)?;
        if Instant::now() > deadline {
            break;
        }
        session.keep_alive()?;
        let reply=session.exchange(1440,json!({"Name":"OPFileQuery","OPFileQuery":{"BeginTime":cursor.to_string(),"EndTime":end.to_string(),"Channel":channel,"DriverTypeMask":"0x0000FFFF","Event":"*","StreamType":if sub{"0x00000001"}else{"0x00000000"},"Type":"h264"}}),false)?;
        let status = wire::check_return(&reply, true)?;
        if [109, 119].contains(&status) {
            complete = true;
            break;
        }
        let page = reply["OPFileQuery"]
            .as_array()
            .filter(|p| p.len() <= 8192)
            .ok_or("invalid_response")?;
        let mut next = cursor;
        for raw in page {
            let r = record(raw, channel, sub)?;
            let begin = clock(r["begin"].as_str().unwrap())?;
            let finish = clock(r["end"].as_str().unwrap())?;
            if begin > next {
                next = begin;
            }
            if begin <= end && finish >= start {
                let id = format!(
                    "{}|{}|{}|{}",
                    r["file"], r["begin"], r["channel"], r["substream"]
                );
                records.insert(id, r);
            }
            if records.len() > 8192 {
                return Err("response_too_large".into());
            }
        }
        if page.is_empty() || status == 110 || (page.len() < 64 && status != 111) {
            complete = true;
            break;
        }
        if next <= cursor || next > end {
            break;
        }
        cursor = next;
    }
    let mut records: Vec<Value> = records.into_values().collect();
    records.sort_by(|a, b| {
        a["begin"]
            .as_str()
            .cmp(&b["begin"].as_str())
            .then(a["file"].as_str().cmp(&b["file"].as_str()))
    });
    Ok(json!({"records":records,"complete":complete}))
}
pub fn calendar(v: &Value, cancel: Arc<AtomicBool>) -> Result<Value> {
    let year = v["year"]
        .as_i64()
        .filter(|y| (2000..=2099).contains(y))
        .ok_or("invalid_time")? as i32;
    let month = v["month"]
        .as_u64()
        .filter(|m| (1..=12).contains(m))
        .ok_or("invalid_time")? as u32;
    let mut session = Session::login(v, cancel)?;
    let reply=session.exchange(1446,json!({"Name":"OPSCalendar","OPSCalendar":{"Year":year,"Month":month,"Event":"*","FileType":"h264","Rev":""}}),false)?;
    wire::check_return(&reply, false)?;
    let mask = wire::unsigned(&reply["OPSCalendar"]["Mask"])?;
    if mask > u32::MAX as u64 {
        return Err("invalid_response".into());
    }
    let days: Vec<_> = (1..=31)
        .filter(|day| {
            NaiveDate::from_ymd_opt(year, month, *day)
                .map(|d| d.month() == month)
                .unwrap_or(false)
                && mask & (1 << (*day - 1)) != 0
        })
        .collect();
    Ok(json!({"days":days}))
}
fn playback(r: &Value, action: &str) -> Result<Value> {
    let file = core::text(r, "file")?;
    let begin = core::text(r, "begin")?;
    let end = core::text(r, "end")?;
    if file.is_empty() || file.len() > 4096 || clock(end)? < clock(begin)? {
        return Err("invalid_input".into());
    }
    Ok(
        json!({"Name":"OPPlayBack","OPPlayBack":{"Action":action,"StartTime":begin,"EndTime":end,"Parameter":{"PlayMode":"ByName","FileName":file,"StreamType":u8::from(r["substream"].as_bool().unwrap_or(false)),"Value":0,"TransMode":"TCP"}}}),
    )
}
pub fn download(v: &Value, cancel: Arc<AtomicBool>) -> Result<Value> {
    let r = &v["recording"];
    let claim = playback(r, "Claim")?;
    let start = playback(r, "DownloadStart")?;
    let stop = playback(r, "DownloadStop")?;
    let path = core::text(v, "path")?;
    let mut control = Session::login(v, cancel.clone())?;
    let mut media = Session::connect(v, control.session, cancel.clone())?;
    let mut created = false;
    let mut compatibility = false;
    let result = (|| {
        let seq = media.send(1424, claim.clone())?;
        wire::check_return(&control.exchange(1420, start.clone(), false)?, false)?;
        let ack = media.reply(1424, seq, true)?;
        match wire::check_return(&ack, false) {
            Ok(_) => {}
            Err(e) if e == "unsupported" && !media.has_buffered_media() => {
                control.cleanup(stop.clone());
                media = Session::login(v, cancel.clone())?;
                compatibility = true;
                wire::check_return(&media.exchange(1424, claim, true)?, false)?;
                wire::check_return(&media.exchange(1420, start, true)?, false)?;
            }
            Err(e) => return Err(e),
        }
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(path).map_err(|_| "file_io")?;
        created = true;
        let deadline = Instant::now() + Duration::from_secs(1800);
        let mut count = 0_u64;
        loop {
            wire::check_cancel(&cancel)?;
            if Instant::now() > deadline {
                return Err("timeout".into());
            }
            control.keep_alive()?;
            let p = media.media()?;
            if p.message == 1423 {
                break;
            }
            count = count
                .checked_add(p.payload.len() as u64)
                .filter(|n| *n <= 8 * 1024 * 1024 * 1024)
                .ok_or("response_too_large")?;
            file.write_all(&p.payload).map_err(|_| "file_io")?;
            if p.payload.is_empty() || p.end != 0 {
                break;
            }
        }
        if count == 0 {
            return Err("incomplete_transfer".into());
        }
        wire::check_cancel(&cancel)?;
        file.sync_all().map_err(|_| "file_io")?;
        Ok(json!({"bytes":count}))
    })();
    control.cleanup(stop.clone());
    if compatibility {
        media.cleanup(stop);
    }
    if result.is_err() && created {
        let _ = fs::remove_file(path);
    }
    result
}
