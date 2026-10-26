use icsee_core::media::index;
use std::{fs, sync::atomic::AtomicBool};

#[test]
fn hevc_index_accepts_independent_frames_without_reordering() {
    let path = std::env::temp_dir().join(format!("icsee-hevc-{}.xm", std::process::id()));
    fs::write(
        &path,
        include_bytes!("../../app/src/androidTest/assets/hevc.xm"),
    )
    .unwrap();
    let result = index(&path, &AtomicBool::new(false));
    let _ = fs::remove_file(path);
    let v = result.unwrap();
    assert_eq!(v["mime"], "video/hevc");
    assert_eq!(v["samples"].as_array().unwrap().len(), 45);
}
fn fixture() -> Vec<u8> {
    let payload = include_bytes!("../../../Tests/Fixtures/pattern.h264");
    let packed = (26_u32 << 26) | (1 << 22) | (2 << 17);
    let mut b = vec![0, 0, 1, 0xfc, 2, 15, 80, 45];
    b.extend(packed.to_le_bytes());
    b.extend((payload.len() as u32).to_le_bytes());
    b.extend(payload);
    b
}
#[test]
fn xm_index_finds_parameter_sets_and_uses_file_offsets() {
    let path = std::env::temp_dir().join(format!("icsee-synthetic-{}.xm", std::process::id()));
    fs::write(&path, fixture()).unwrap();
    let result = index(&path, &AtomicBool::new(false));
    let _ = fs::remove_file(path);
    let r = result.unwrap();
    assert_eq!(r["width"], 640);
    assert_eq!(r["height"], 360);
    assert_eq!(r["mime"], "video/avc");
    assert_eq!(r["samples"][0][0], 16);
    assert_eq!(r["csd"].as_array().unwrap().len(), 2);
}
#[test]
fn xm_rejects_truncation_and_invalid_padding() {
    let path = std::env::temp_dir().join(format!("icsee-invalid-{}.xm", std::process::id()));
    let mut b = fixture();
    b.pop();
    fs::write(&path, &b).unwrap();
    assert!(index(&path, &AtomicBool::new(false)).is_err());
    b = fixture();
    b.push(255);
    fs::write(&path, &b).unwrap();
    assert!(index(&path, &AtomicBool::new(false)).is_err());
    let _ = fs::remove_file(path);
}

#[test]
fn audio_only_suffix_cannot_bypass_the_packet_index_limit() {
    let path = std::env::temp_dir().join(format!("icsee-audio-bound-{}.xm", std::process::id()));
    let mut bytes = fixture();
    for _ in 0..200_001 {
        bytes.extend([0, 0, 1, 0xfa, 14, 2, 1, 0, 0xd5]);
    }
    fs::write(&path, bytes).unwrap();
    let result = index(&path, &AtomicBool::new(false));
    let _ = fs::remove_file(path);
    let Err(error) = result else {
        panic!("Audio packet index limit was bypassed");
    };
    assert_eq!(error, "response_too_large");
}
