//! Theo comes as three products, each on or off by itself (the Mac's ClickyCore `TheoProducts`): Theo (bots, teams,
//! routines, coding runs, the local API), Clicky (the screen companion) and Dictation (talk, and the words are typed). The
//! choice is kept in settings.json as `products.theo`, `products.clicky` and `products.dictation`. With nothing saved Theo is
//! on and Clicky and Dictation are off, so an update leaves an existing computer as it was. Setup's "Pick products" step and
//! Settings › Products change it; the voice features read it through `setupState` or the `products` command.

use crate::harness::Harness;
use serde_json::{json, Value};

pub struct Product {
    pub id: &'static str,
    pub title: &'static str,
    /// One line under the name.
    pub tagline: &'static str,
    /// What you get, shortest first.
    pub points: [&'static str; 3],
    /// What it needs before it works, shown on its card.
    pub requirement: Option<&'static str>,
    /// With no saved choice.
    pub on_by_default: bool,
}

/// In the order Setup and Settings show them.
pub const PRODUCTS: [Product; 3] = [
    Product {
        id: "theo",
        title: "Theo",
        tagline: "Your own team of bots that chat, run routines and hand coding work to your agents.",
        points: ["Make bots with their own looks, teams and schedules", "Hand a fix to Claude Code, Codex, Cursor and more", "Runs come back with a branch and a draft PR"],
        requirement: None,
        on_by_default: true,
    },
    Product {
        id: "clicky",
        title: "Clicky",
        tagline: "A companion on your screen that sees what you see, points at things and answers out loud.",
        points: ["Hold a shortcut (Ctrl + Alt on Windows) and ask", "Flies to the button you need and circles it", "Answers out loud in the computer's own voice"],
        requirement: Some("Uses any brain you set up: an API key or a signed-in agent"),
        on_by_default: false,
    },
    Product {
        id: "dictation",
        title: "Dictation",
        tagline: "Talk in any app. Clean, punctuated words are typed where your cursor is.",
        points: ["Hold a shortcut anywhere, talk, let go", "Fillers and \u{201C}um\u{201D}s are tidied away", "Hindi, Hinglish and 10 Indian languages with a Sarvam key"],
        requirement: Some("A Sarvam API key makes it better; it's optional"),
        on_by_default: false,
    },
];

pub fn setting_key(id: &str) -> String {
    format!("products.{id}")
}

pub fn product(id: &str) -> Option<&'static Product> {
    PRODUCTS.iter().find(|p| p.id == id)
}

/// A saved choice wins; with none, the product's own default (Theo on, Clicky and Dictation off).
pub fn is_on_from(stored: Option<bool>, product: &Product) -> bool {
    stored.unwrap_or(product.on_by_default)
}

fn stored(h: &Harness, id: &str) -> Option<bool> {
    h.settings.get(&setting_key(id)).and_then(|value| match value {
        Value::Bool(on) => Some(on),
        Value::Number(n) => n.as_f64().map(|n| n != 0.0),
        Value::String(s) => match s.as_str() {
            "1" | "true" | "yes" | "on" => Some(true),
            "0" | "false" | "no" | "off" => Some(false),
            _ => None,
        },
        _ => None,
    })
}

pub fn is_on(h: &Harness, id: &str) -> bool {
    product(id).map(|p| is_on_from(stored(h, id), p)).unwrap_or(false)
}

/// `{theo: true, clicky: false, dictation: false}`.
pub fn choices(h: &Harness) -> Value {
    let mut map = serde_json::Map::new();
    for p in PRODUCTS.iter() {
        map.insert(p.id.to_string(), Value::Bool(is_on(h, p.id)));
    }
    Value::Object(map)
}

/// Every product with its words and whether it's on, for Setup and Settings.
pub fn report(h: &Harness) -> Value {
    let list: Vec<Value> = PRODUCTS.iter().map(|p| json!({
        "id": p.id, "title": p.title, "tagline": p.tagline, "points": p.points, "requirement": p.requirement,
        "on": is_on(h, p.id), "saved": stored(h, p.id).is_some(),
    })).collect();
    json!({"products": list, "on": choices(h), "anyOn": PRODUCTS.iter().any(|p| is_on(h, p.id))})
}

/// Setup can only be finished with at least one product on (the Mac's `TheoProductChoice.canFinish`).
pub fn can_finish(on: &[bool]) -> bool {
    on.iter().any(|x| *x)
}

/// Finishing setup saves every product as a choice, so a later change to the defaults never switches one by itself.
pub fn save_choices(h: &Harness) {
    for p in PRODUCTS.iter() {
        if stored(h, p.id).is_none() {
            h.settings.set(&setting_key(p.id), Value::Bool(p.on_by_default));
        }
    }
}

/// The `products` control command: `{action: "state"}` (the default) or `{action: "set", product, on}`.
pub fn control(h: &Harness, cmd: &Value) -> Result<Value, String> {
    match cmd.get("action").and_then(|a| a.as_str()).unwrap_or("state") {
        "state" => Ok(report(h)),
        "set" => {
            let id = cmd.get("product").and_then(|p| p.as_str()).unwrap_or_default();
            if product(id).is_none() {
                return Err("The products are theo, clicky and dictation.".into());
            }
            let Some(on) = cmd.get("on").and_then(|o| o.as_bool()) else { return Err("Needs on: true or false.".into()) };
            h.settings.set(&setting_key(id), Value::Bool(on));
            Ok(report(h))
        }
        _ => Err("The products actions are state and set.".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn with_nothing_saved_only_theo_is_on() {
        assert!(is_on_from(None, product("theo").unwrap()));
        assert!(!is_on_from(None, product("clicky").unwrap()));
        assert!(!is_on_from(None, product("dictation").unwrap()));
        assert!(is_on_from(Some(true), product("dictation").unwrap()));
        assert!(!is_on_from(Some(false), product("theo").unwrap()));
    }

    #[test]
    fn the_keys_are_the_agreed_ones() {
        let keys: Vec<String> = PRODUCTS.iter().map(|p| setting_key(p.id)).collect();
        assert_eq!(keys, ["products.theo", "products.clicky", "products.dictation"]);
    }

    #[test]
    fn setup_needs_one_product_on() {
        assert!(!can_finish(&[false, false, false]));
        assert!(can_finish(&[false, true, false]));
    }

    #[test]
    fn choices_are_saved_and_read_back() {
        let dir = tempfile::tempdir().unwrap();
        let h = Harness::new(dir.path().join("theo"), true);
        assert_eq!(choices(&h), json!({"theo": true, "clicky": false, "dictation": false}));
        control(&h, &json!({"action": "set", "product": "clicky", "on": true})).unwrap();
        assert!(is_on(&h, "clicky"));
        assert!(control(&h, &json!({"action": "set", "product": "studio", "on": true})).is_err());
        h.settings.set("products.dictation", json!("on"));
        assert!(is_on(&h, "dictation"));
        save_choices(&h);
        assert_eq!(h.settings.get("products.theo"), Some(json!(true)));
    }
}
