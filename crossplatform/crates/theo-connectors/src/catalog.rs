//! The starter catalog: apps a user can add with one click. It is data (`catalog.json` beside this crate's
//! `Cargo.toml`), built into the program, and a `catalog.json` placed next to the program replaces it, so the list can
//! change without a new build.

use serde::{Deserialize, Serialize};

use crate::model::AppEntry;

const BUILT_IN_CATALOG: &str = include_str!("../catalog.json");

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CatalogEntry {
    /// Shown under the app's name.
    #[serde(default)]
    pub description: String,
    /// How Theo reaches it, in words ("Your Claude account (needs Claude Code)").
    #[serde(default)]
    pub via: String,
    /// What was tested, and when.
    #[serde(default)]
    pub tested: String,
    #[serde(flatten)]
    pub app: AppEntry,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Catalog {
    pub version: u32,
    #[serde(default)]
    pub note: String,
    pub apps: Vec<CatalogEntry>,
}

pub fn load_catalog() -> Catalog {
    let replacement = std::env::current_exe()
        .ok()
        .and_then(|program| program.parent().map(|folder| folder.join("catalog.json")))
        .and_then(|file| std::fs::read_to_string(file).ok())
        .and_then(|text| serde_json::from_str::<Catalog>(&text).ok());
    replacement.unwrap_or_else(|| serde_json::from_str(BUILT_IN_CATALOG).expect("the built-in catalog is valid JSON"))
}

pub fn catalog_entry(catalog_id: &str) -> Option<CatalogEntry> {
    load_catalog().apps.into_iter().find(|entry| entry.app.id == catalog_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_built_in_catalog_is_valid() {
        let catalog: Catalog = serde_json::from_str(BUILT_IN_CATALOG).unwrap();
        assert!(!catalog.apps.is_empty());
        for entry in &catalog.apps {
            entry.app.validate().unwrap();
            assert!(entry.app.fields_from_newer_versions.is_empty(), "{} has a field the hub doesn't know", entry.app.id);
        }
        // The Mac app's ids stay working for bots saved before the hub.
        for mac_app_id in ["gmail", "notion", "calendar", "drive", "docs", "sheets"] {
            assert!(catalog.apps.iter().any(|entry| entry.app.id == mac_app_id), "{mac_app_id}");
        }
    }
}
