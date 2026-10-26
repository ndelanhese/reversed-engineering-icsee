use jni::{
    objects::{JObject, JString},
    sys::{jlong, jstring},
    JNIEnv,
};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, AtomicI64, Ordering},
        Arc, Mutex, OnceLock,
    },
};
static TOKENS: OnceLock<Mutex<HashMap<i64, Arc<AtomicBool>>>> = OnceLock::new();
static NEXT: AtomicI64 = AtomicI64::new(1);
fn tokens() -> &'static Mutex<HashMap<i64, Arc<AtomicBool>>> {
    TOKENS.get_or_init(|| Mutex::new(HashMap::new()))
}
#[no_mangle]
pub extern "system" fn Java_io_github_ndelanhese_reversedicsee_NativeCore_newToken(
    _: JNIEnv,
    _: JObject,
) -> jlong {
    let Ok(mut map) = tokens().lock() else {
        return 0;
    };
    if map.len() >= 64 {
        return 0;
    }
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    map.insert(id, Arc::new(AtomicBool::new(false)));
    id
}
#[no_mangle]
pub extern "system" fn Java_io_github_ndelanhese_reversedicsee_NativeCore_cancel(
    _: JNIEnv,
    _: JObject,
    id: jlong,
) {
    if let Ok(map) = tokens().lock() {
        if let Some(c) = map.get(&id) {
            c.store(true, Ordering::Relaxed);
        }
    }
}
#[no_mangle]
pub extern "system" fn Java_io_github_ndelanhese_reversedicsee_NativeCore_call(
    mut env: JNIEnv,
    _: JObject,
    id: jlong,
    request: JString,
) -> jstring {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let c = tokens()
            .lock()
            .map_err(|_| "internal")?
            .get(&id)
            .cloned()
            .ok_or("cancelled")?;
        let input: String = env
            .get_string(&request)
            .map_err(|_| "invalid_input")?
            .into();
        if input.len() > 4 * 1024 * 1024 {
            return Err("invalid_input".to_owned());
        }
        let v: Value = serde_json::from_str(&input).map_err(|_| "invalid_input")?;
        crate::engine::dispatch(&v, c)
    }))
    .unwrap_or_else(|_| Err("internal".into()));
    if let Ok(mut map) = tokens().lock() {
        map.remove(&id);
    }
    let value = match result {
        Ok(v) => json!({"ok":v}),
        Err(e) => json!({"error":e}),
    };
    let mut output = value.to_string();
    if output.len() > 16 * 1024 * 1024 {
        output = json!({"error":"response_too_large"}).to_string();
    }
    env.new_string(output)
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}
