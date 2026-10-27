use icsee_core::onvif::{escape, parse, safe_service};
#[test]
fn soap_escapes_credentials_and_refuses_foreign_service_addresses() {
    assert_eq!(escape("a<&\"'"), "a&lt;&amp;&quot;&apos;");
    assert_eq!(
        safe_service("http://192.0.2.1:8899/onvif/ptz_service", "192.0.2.1", 8899).unwrap(),
        "http://192.0.2.1:8899/onvif/ptz_service"
    );
    for url in [
        "http://evil.test:8899/onvif/ptz_service",
        "http://192.0.2.1:80/onvif/ptz_service",
        "http://user@192.0.2.1:8899/onvif/device_service",
        "http://192.0.2.1:8899/private",
    ] {
        assert!(safe_service(url, "192.0.2.1", 8899).is_err());
    }
}
#[test]
fn xml_rejects_entities_and_accepts_bounded_namespaced_soap() {
    assert!(parse("<!DOCTYPE s [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><s>&x;</s>").is_err());
    assert!(parse(
        "<s:Envelope xmlns:s='http://www.w3.org/2003/05/soap-envelope'><s:Body/></s:Envelope>"
    )
    .is_ok());
    assert!(parse(&format!("{}{}", "<x>".repeat(80), "</x>".repeat(80))).is_err());
}
