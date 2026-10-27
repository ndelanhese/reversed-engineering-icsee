use icsee_core::{recordings, wire::Packet};
use serde_json::{json, Value};
use std::{
    io::Write,
    net::{TcpListener, TcpStream},
    sync::{atomic::AtomicBool, Arc},
    time::Duration,
};
fn reply(stream: &mut TcpStream, p: Packet, value: Value) {
    stream
        .write_all(
            &Packet {
                session: 42,
                sequence: p.sequence | 1,
                message: p.message + 1,
                fragment: 1,
                end: 0,
                payload: serde_json::to_vec(&value).unwrap(),
            }
            .encode()
            .unwrap(),
        )
        .unwrap();
}
fn peer(f: impl FnOnce(TcpStream) + Send + 'static) -> Value {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        let (mut s, _) = listener.accept().unwrap();
        s.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let p = Packet::read(&mut s).unwrap();
        assert_eq!(p.message, 1000);
        reply(&mut s, p, json!({"Ret":100,"SessionID":"0x0000002a"}));
        f(s)
    });
    json!({"host":"127.0.0.1","controlPort":port,"username":"fixture","password":"synthetic","day":"2026-01-02","channel":1,"year":2026,"month":1})
}
#[test]
fn camera_calendar_decodes_hex_mask_and_preserves_camera_clock() {
    let v = peer(|mut s| {
        let p = Packet::read(&mut s).unwrap();
        assert_eq!(p.message, 1446);
        reply(
            &mut s,
            p,
            json!({"Ret":100,"OPSCalendar":{"Mask":"0x80000001"}}),
        );
    });
    let r = recordings::calendar(&v, Arc::new(AtomicBool::new(false))).unwrap();
    assert_eq!(r["days"], json!([1]));
}
#[test]
fn history_queries_previous_day_keeps_overlap_and_handles_partial_status() {
    let v = peer(|mut s| {
        let p = Packet::read(&mut s).unwrap();
        let b: Value = serde_json::from_slice(&p.payload[..p.payload.len() - 2]).unwrap();
        assert_eq!(b["OPFileQuery"]["BeginTime"], "2026-01-01 00:00:00");
        reply(
            &mut s,
            p,
            json!({"Ret":110,"OPFileQuery":[{"FileName":"fixture.h264","BeginTime":"2026-01-01 23:55:00","EndTime":"2026-01-02 00:05:00","FileLength":"0x10"}]}),
        );
    });
    let r = recordings::listing(&v, Arc::new(AtomicBool::new(false))).unwrap();
    assert_eq!(r["records"].as_array().unwrap().len(), 1);
    assert_eq!(r["records"][0]["bytes"], 16384);
    assert_eq!(r["complete"], true);
}
fn transfer_fixture(complete: bool) -> (Value, std::path::PathBuf) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        let (mut control, _) = listener.accept().unwrap();
        control
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let login = Packet::read(&mut control).unwrap();
        reply(
            &mut control,
            login,
            json!({"Ret":100,"SessionID":"0x0000002a"}),
        );
        let (mut media, _) = listener.accept().unwrap();
        media
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let claim = Packet::read(&mut media).unwrap();
        assert_eq!(claim.message, 1424);
        let start = Packet::read(&mut control).unwrap();
        assert_eq!(start.message, 1420);
        reply(&mut control, start, json!({"Ret":100}));
        // Exercise media arriving before the Claim acknowledgement.
        media
            .write_all(
                &Packet {
                    session: 42,
                    sequence: 0,
                    message: 1426,
                    fragment: 0,
                    end: u8::from(complete),
                    payload: b"synthetic-video-bytes".to_vec(),
                }
                .encode()
                .unwrap(),
            )
            .unwrap();
        reply(&mut media, claim, json!({"Ret":100}));
        if !complete {
            drop(media);
        }
        let stop = Packet::read(&mut control).unwrap();
        assert_eq!(stop.message, 1420);
        reply(&mut control, stop, json!({"Ret":100}));
    });
    let path = std::env::temp_dir().join(format!(
        "icsee-transfer-{}-{complete}.xm",
        std::process::id()
    ));
    let _ = std::fs::remove_file(&path);
    (
        json!({"host":"127.0.0.1","controlPort":port,"username":"fixture","password":"synthetic","path":path,"recording":{"file":"fixture.xm","begin":"2026-01-01 00:00:00","end":"2026-01-01 00:05:00","substream":false}}),
        path,
    )
}
#[test]
fn download_claim_buffers_early_media_and_requires_explicit_completion() {
    let (v, path) = transfer_fixture(true);
    let r = recordings::download(&v, Arc::new(AtomicBool::new(false))).unwrap();
    assert_eq!(r["bytes"], 21);
    assert_eq!(std::fs::read(&path).unwrap(), b"synthetic-video-bytes");
    std::fs::remove_file(path).unwrap();
    let (v, path) = transfer_fixture(false);
    assert!(recordings::download(&v, Arc::new(AtomicBool::new(false))).is_err());
    assert!(!path.exists());
}
