//! Control commands that live outside theo-core (dictation and Clicky in `theo-voice`, which depends on theo-core, so
//! theo-core can't call it directly). theod and the desktop app register them at start; [`crate::control::handle`] asks
//! each one in turn for a command it doesn't know itself.

use crate::harness::Harness;
use serde_json::Value;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};

/// Answers a command it knows with `Some(answer)`, and leaves the rest with `None`.
pub type ExtraHandler = Arc<dyn Fn(Arc<Harness>, Value) -> Pin<Box<dyn Future<Output = Option<Value>> + Send>> + Send + Sync>;

static HANDLERS: Mutex<Vec<(String, ExtraHandler)>> = Mutex::new(Vec::new());

/// Adds a handler under a name. Registering the same name again replaces it, so starting twice is harmless.
pub fn register(name: &str, handler: ExtraHandler) {
    let mut handlers = HANDLERS.lock().unwrap();
    handlers.retain(|(existing, _)| existing != name);
    handlers.push((name.to_string(), handler));
}

/// The first registered handler's answer for this command, if any knows it.
pub async fn handle(harness: &Arc<Harness>, cmd: &Value) -> Option<Value> {
    let handlers: Vec<ExtraHandler> = HANDLERS.lock().unwrap().iter().map(|(_, handler)| handler.clone()).collect();
    for handler in handlers {
        if let Some(answer) = handler(harness.clone(), cmd.clone()).await {
            return Some(answer);
        }
    }
    None
}
