use icsee_core::wire::Packet;
use std::io::Cursor;
fn packet() -> Packet {
    Packet {
        session: 12,
        sequence: 3,
        message: 1001,
        fragment: 1,
        end: 0,
        payload: b"{\"Ret\":100}\n\0".to_vec(),
    }
}
#[test]
fn packet_handles_reply_bit_and_explicit_count_one() {
    let p = packet();
    let bytes = p.encode().unwrap();
    assert_eq!(bytes.len(), 33);
    assert_eq!(&bytes[0..4], &[255, 0, 0, 0]);
    let q = Packet::read(&mut Cursor::new(bytes)).unwrap();
    assert_eq!(q.payload, p.payload);
    assert!(q.check(1000, 2, 12).is_ok());
    assert!(q.check(1000, 4, 12).is_err());
    assert!(q.check(1000, 2, 13).is_err());
}
#[test]
fn oversized_truncated_and_fragmented_control_packets_fail() {
    let mut p = packet();
    p.fragment = 2;
    assert!(p.check(1000, 2, 12).is_err());
    p.fragment = 0;
    let bytes = p.encode().unwrap();
    assert!(Packet::read(&mut Cursor::new(&bytes[..22])).is_err());
    let mut header = bytes[..20].to_vec();
    header[16..20].copy_from_slice(&(2_097_153_u32).to_le_bytes());
    assert!(Packet::read(&mut Cursor::new(header)).is_err());
}
