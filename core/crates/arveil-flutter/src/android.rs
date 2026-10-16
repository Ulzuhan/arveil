//! What the Android activity service calls (ADR-014). The service owns a
//! thread and a watch key; this module only waits on the relay with it and
//! reports back. It opens no profile, starts no Flutter engine and touches
//! no message.

use std::sync::atomic::{AtomicI64, Ordering};
use std::time::Duration;

use arveil_app::watch::{self, Ended, WatchCredentials, WatchEvent};
use jni::JNIEnv;
use jni::objects::{JByteArray, JClass, JObject, JValue};
use jni::sys::{jint, jlong};

/// What `run` returns to Kotlin.
const STOPPED: jint = 0;
const REFUSED: jint = 1;
const INVALID: jint = 2;

/// Events passed to `Listener.onEvent`.
const LISTENING: jint = 0;
const ACTIVITY: jint = 1;
const DISCONNECTED: jint = 2;

/// The generation `run` keeps waiting for. `reserve` hands out the next
/// one and `stop` moves past it, so a stop that lands before `run` starts
/// still stops it.
static GENERATION: AtomicI64 = AtomicI64::new(0);

/// `WatchNative.reserve(): Long`
#[unsafe(no_mangle)]
pub extern "system" fn Java_io_github_ulzuhan_arveil_WatchNative_reserve<'local>(
    _env: JNIEnv<'local>,
    _class: JClass<'local>,
) -> jlong {
    GENERATION.fetch_add(1, Ordering::AcqRel) + 1
}

/// `WatchNative.stop()`: end whatever `run` is waiting.
#[unsafe(no_mangle)]
pub extern "system" fn Java_io_github_ulzuhan_arveil_WatchNative_stop<'local>(
    _env: JNIEnv<'local>,
    _class: JClass<'local>,
) {
    GENERATION.fetch_add(1, Ordering::AcqRel);
}

/// `WatchNative.run(generation, credentials, keepaliveSeconds, listener): Int`
///
/// Blocks the calling thread until stopped, refused or told to stop by the
/// listener, reconnecting meanwhile. `listener.onEvent(Int): Boolean` is
/// called on this thread.
#[unsafe(no_mangle)]
pub extern "system" fn Java_io_github_ulzuhan_arveil_WatchNative_run<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    generation: jlong,
    credentials: JByteArray<'local>,
    keepalive_seconds: jint,
    listener: JObject<'local>,
) -> jint {
    let Ok(bytes) = env.convert_byte_array(&credentials) else {
        return INVALID;
    };
    let Ok(credentials) = WatchCredentials::from_bytes(&bytes) else {
        return INVALID;
    };
    let keepalive = Duration::from_secs(keepalive_seconds.clamp(15, 900) as u64);
    let stop = || GENERATION.load(Ordering::Acquire) != generation;
    let ended = watch::serve(&credentials, keepalive, &stop, |event| {
        let code = match event {
            WatchEvent::Listening => LISTENING,
            WatchEvent::Activity => ACTIVITY,
            WatchEvent::Disconnected => DISCONNECTED,
        };
        match env.call_method(&listener, "onEvent", "(I)Z", &[JValue::Int(code)]) {
            Ok(value) => value.z().unwrap_or(false),
            Err(_) => {
                // A Kotlin exception must not unwind through Rust; it ends
                // the wait instead.
                let _ = env.exception_clear();
                false
            }
        }
    });
    match ended {
        Ended::Stopped => STOPPED,
        Ended::Refused => REFUSED,
    }
}
