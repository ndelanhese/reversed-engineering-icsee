use crate::{
    core::{self, Result},
    media, onvif, recordings,
    wire::{self, Session},
};
use serde_json::{json, Value};
use std::{
    path::Path,
    sync::{atomic::AtomicBool, Arc},
    time::Duration,
};

pub fn dispatch(v: &Value, cancel: Arc<AtomicBool>) -> Result<Value> {
    wire::check_cancel(&cancel)?;
    let op = core::text(v, "op")?;
    match op {
        "rtsp" => Ok(json!({"uri":core::rtsp(v,v["compatibility"].as_bool().unwrap_or(false))?})),
        "settings_catalog" => {
            serde_json::from_str(include_str!("settings.json")).map_err(|_| "internal".into())
        }
        "recordings" => recordings::listing(v, cancel),
        "calendar" => recordings::calendar(v, cancel),
        "download" => recordings::download(v, cancel),
        "index_media" => media::index(Path::new(core::text(v, "path")?), &cancel),
        "camera_time" | "storage" => {
            let name = if op == "camera_time" {
                "OPTimeQuery"
            } else {
                "StorageInfo"
            };
            let mut s = Session::login(v, cancel)?;
            let r = s.exchange(
                if op == "camera_time" { 1452 } else { 1020 },
                json!({"Name":name}),
                false,
            )?;
            wire::check_return(&r, false)?;
            Ok(json!({"value":r.get(name).ok_or("unsupported")?}))
        }
        "settings_read" | "settings_write" => {
            let name = core::text(v, "name")?;
            let catalog: Value =
                serde_json::from_str(include_str!("settings.json")).map_err(|_| "internal")?;
            let section = catalog
                .as_array()
                .unwrap()
                .iter()
                .find(|s| s["name"] == name)
                .ok_or("unsupported")?;
            if op == "settings_write" && section["readOnly"] == true {
                return Err("read_only".into());
            }
            let mut s = Session::login(v, cancel)?;
            let fresh = s.read_setting(name, section["capability"] == true)?;
            if op == "settings_read" {
                return Ok(json!({"value":fresh}));
            }
            let updated = core::patch(&v["original"], &v["updated"], &fresh)?;
            if updated == fresh {
                return Ok(json!({"value":fresh,"verified":true,"requiresRestart":false}));
            }
            let mut body = json!({"Name":name});
            body[name] = updated.clone();
            let response = s
                .exchange(1040, body, false)
                .map_err(|_| "write_uncertain")?;
            let status = wire::check_return(&response, false)?;
            let readback = s.read_setting(name, false).map_err(|_| "write_uncertain")?;
            // Compare edited leaves only; a device may update unrelated status fields.
            let verified = core::edits_verified(&v["original"], &v["updated"], &readback);
            if !verified && status != 150 {
                return Err("verification".into());
            }
            Ok(json!({"value":readback,"verified":verified,"requiresRestart":status==150}))
        }
        "reboot" => {
            if v["confirmed"] != true {
                return Err("invalid_input".into());
            }
            let mut s = Session::login(v, Arc::new(AtomicBool::new(false)))?;
            let r = s.exchange(
                1450,
                json!({"Name":"OPMachine","OPMachine":{"Action":"Reboot"}}),
                false,
            )?;
            wire::check_return(&r, false)?;
            std::thread::sleep(Duration::from_secs(15));
            Ok(json!({"requiresReconnect":true}))
        }
        s if s.starts_with("onvif_") => onvif::operation(v, cancel),
        _ => Err("unsupported".into()),
    }
}
