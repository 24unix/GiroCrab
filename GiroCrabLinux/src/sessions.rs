//! Bank dialogs (SyncSession / TransferSession) for QML. The Swift app keeps
//! the session object in `AppModel.activeSession`; here it lives in a registry
//! and QML holds its numeric handle. Every step runs on a worker thread
//! (`Core.callAsync`) and blocks on one shared Tokio runtime.

use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};

use base64::Engine as _;
use girocrab_core::{SyncSession, TransferSession};
use serde_json::Value;

pub static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("tokio runtime")
});

#[derive(Clone)]
pub enum Session {
    Sync(Arc<SyncSession>),
    Transfer(Arc<TransferSession>),
}

static SESSIONS: LazyLock<Mutex<HashMap<u64, Session>>> = LazyLock::new(Default::default);
static NEXT: Mutex<u64> = Mutex::new(0);

pub fn register(s: Session) -> u64 {
    let mut n = NEXT.lock().unwrap();
    *n += 1;
    SESSIONS.lock().unwrap().insert(*n, s);
    *n
}

pub fn get(id: u64) -> Result<Session, String> {
    SESSIONS
        .lock()
        .unwrap()
        .get(&id)
        .cloned()
        .ok_or_else(|| crate::i18n::tr("Der Bankdialog ist bereits beendet."))
}

pub fn remove(id: u64) {
    SESSIONS.lock().unwrap().remove(&id);
}

/// Lock (`AppModel.endBankDialogsForLock`): every bank dialog leaves the
/// registry at once, so no later step can reach it, and is cancelled. The
/// cancel waits for a step still talking to the bank, so it runs on its own
/// thread (Swift: `Task { await session?.cancel() }`) and never blocks the GUI.
pub fn cancel_all() {
    let drained: Vec<Session> = SESSIONS.lock().unwrap().drain().map(|(_, s)| s).collect();
    if drained.is_empty() {
        return;
    }
    std::thread::spawn(move || {
        RUNTIME.block_on(async {
            for s in drained {
                match s {
                    Session::Sync(s) => s.cancel().await,
                    Session::Transfer(t) => {
                        let _ = t.cancel().await;
                    }
                }
            }
        })
    });
}

/// The challenge image (photoTAN / QR) as a data URL QML can show directly.
pub fn with_image_url(mut step: Value) -> Value {
    let images = ["NeedsChallenge", "StillWaiting"];
    for k in images {
        if let Some(ch) = step.get_mut(k).and_then(|s| s.get_mut("challenge")) {
            if let Some(bytes) = ch.get("image").and_then(|i| i.as_array()) {
                let raw: Vec<u8> = bytes
                    .iter()
                    .filter_map(|b| b.as_u64().map(|b| b as u8))
                    .collect();
                let mime = if raw.starts_with(b"\x89PNG") {
                    "image/png"
                } else if raw.starts_with(b"GIF") {
                    "image/gif"
                } else {
                    "image/jpeg"
                };
                ch["image_url"] = Value::String(format!(
                    "data:{mime};base64,{}",
                    base64::engine::general_purpose::STANDARD.encode(&raw)
                ));
            }
            if let Some(o) = ch.as_object_mut() {
                o.remove("image");
            }
        }
    }
    step
}
