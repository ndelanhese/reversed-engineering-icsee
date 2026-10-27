use icsee_core::core::{patch, rtsp, sofia};
use serde_json::json;

#[test]
fn authentication_matches_independent_md5_pair_vector() {
    assert_eq!(sofia(""), "tlJwpbo6");
    assert_eq!(sofia("admin"), "6QNMIQGe");
}
#[test]
fn endpoint_encodes_secrets_and_rejects_injection() {
    let v = json!({"host":"192.0.2.10","port":554,"channel":1,"substream":true,"username":"name @","password":"p'&/?"});
    let uri = rtsp(&v, false).unwrap();
    assert_eq!(uri,"rtsp://name%20%40:p%27%26%2F%3F@192.0.2.10:554/user=name%20%40&channel=1&stream=1.sdp?real_stream");
    let mut bad = v;
    bad["host"] = json!("camera/evil\r\n");
    assert!(rtsp(&bad, false).is_err());
}
#[test]
fn settings_merge_preserves_unrelated_changes_and_rejects_conflicts() {
    let original = json!({"Brightness":10,"Other":[true,2]});
    let updated = json!({"Brightness":20,"Other":[true,2]});
    let fresh = json!({"Brightness":10,"Other":[false,3]});
    assert_eq!(
        patch(&original, &updated, &fresh).unwrap(),
        json!({"Brightness":20,"Other":[false,3]})
    );
    assert!(patch(
        &original,
        &updated,
        &json!({"Brightness":11,"Other":[true,2]})
    )
    .is_err());
    assert!(patch(
        &original,
        &json!({"Brightness":"20","Other":[true,2]}),
        &original
    )
    .is_err());
    assert!(patch(&original, &json!({"Brightness":20}), &original).is_err());
}
#[test]
fn readback_verifies_only_requested_leaves() {
    let a = json!({"Brightness":10,"Other":1});
    let b = json!({"Brightness":20,"Other":1});
    assert!(icsee_core::core::edits_verified(
        &a,
        &b,
        &json!({"Brightness":20,"Other":2})
    ));
    assert!(!icsee_core::core::edits_verified(
        &a,
        &b,
        &json!({"Brightness":10,"Other":2})
    ));
}
