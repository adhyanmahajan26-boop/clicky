//! Each app's secrets: OAuth tokens, the client the hub registered, a pasted token, secret settings for a local command.
//!
//! They are kept in one encrypted file per app (`Connectors/vault/<id>.secret`), and the key that opens them is in the
//! system's own store: the Keychain on macOS and the Credential Manager on Windows (service `com.theo.connectors`). Linux
//! keeps the key in a file only this user can read, the way `theo-core/src/secrets.rs` keeps the gateway token, because
//! Secret Service needs a desktop keyring that servers and CI don't have. A test profile always uses the file, so tests
//! never touch the system store.
//!
//! Why not the tokens themselves in the Keychain: Windows' Credential Manager holds at most 2,560 bytes per entry, and an
//! access token plus a refresh token plus a registered client is often more than that. One small key in the system store
//! and the rest encrypted beside it works the same on all three systems.

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

use crate::files::{create_private_folder, write_file_atomically, HubPaths};

pub const KEYCHAIN_SERVICE: &str = "com.theo.connectors";
#[cfg_attr(not(any(target_os = "macos", target_os = "windows")), allow(dead_code))]
const KEYCHAIN_ACCOUNT_FOR_VAULT_KEY: &str = "vault-key";

/// Where the vault's key is kept.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyStore {
    /// The Keychain or the Credential Manager (and the key file on Linux, which has neither everywhere).
    System,
    /// A file in the hub's folder that only this user can read. Test profiles use this.
    File,
}

impl KeyStore {
    pub fn parse(text: &str) -> Option<KeyStore> {
        match text {
            "system" => Some(KeyStore::System),
            "file" => Some(KeyStore::File),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RegisteredOAuthClient {
    pub client_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client_secret: Option<String>,
    /// `none`, `client_secret_post` or `client_secret_basic`.
    #[serde(default = "token_endpoint_auth_none")]
    pub token_endpoint_auth_method: String,
    /// The loopback address the client was registered with; reused when its port is free.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub redirect_uri: Option<String>,
    /// The authorization server it was registered with.
    pub issuer: String,
    /// True when the hub registered it itself (dynamic client registration), false when the owner set a client id.
    #[serde(default)]
    pub registered_by_hub: bool,
}

fn token_endpoint_auth_none() -> String {
    "none".into()
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthTokens {
    pub access_token: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refresh_token: Option<String>,
    /// Seconds since 1970 when the access token stops working, if the server said.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthRecord {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client: Option<RegisteredOAuthClient>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokens: Option<OAuthTokens>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token_endpoint: Option<String>,
    /// The resource the tokens were issued for (the MCP server's address), sent again when refreshing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resource: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AppSecrets {
    /// A token the user pasted, sent as `Authorization: Bearer`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pasted_token: Option<String>,
    /// Secret settings for a local command, added to its environment.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub secret_environment: BTreeMap<String, String>,
    /// A client secret the owner set for an OAuth client they registered themselves.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_client_secret: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub oauth: Option<OAuthRecord>,
}

impl AppSecrets {
    pub fn is_empty(&self) -> bool {
        *self == AppSecrets::default()
    }
}

pub struct Vault {
    paths: HubPaths,
    key_store: KeyStore,
}

impl Vault {
    pub fn new(paths: HubPaths, key_store: KeyStore) -> Vault {
        Vault { paths, key_store }
    }

    fn secret_file(&self, app_id: &str) -> std::path::PathBuf {
        self.paths.vault_folder().join(format!("{app_id}.secret"))
    }

    /// The app's secrets, or empty ones when it has none. An unreadable file (the key is gone, or the file was damaged)
    /// reads as empty: the app then simply needs signing in again.
    pub fn read(&self, app_id: &str) -> AppSecrets {
        let Ok(sealed_bytes) = std::fs::read(self.secret_file(app_id)) else { return AppSecrets::default() };
        let Ok(Some(key)) = self.vault_key(false) else { return AppSecrets::default() };
        open_sealed_secrets(&key, app_id, &sealed_bytes).unwrap_or_default()
    }

    pub fn write(&self, app_id: &str, secrets: &AppSecrets) -> Result<(), String> {
        if secrets.is_empty() {
            return self.forget(app_id);
        }
        let key = self.vault_key(true)?.ok_or("The vault key couldn't be made.")?;
        let sealed_bytes = seal_secrets(&key, app_id, secrets)?;
        create_private_folder(&self.paths.vault_folder()).map_err(|error| format!("Couldn't make the vault folder: {error}"))?;
        write_file_atomically(&self.secret_file(app_id), &sealed_bytes).map_err(|error| format!("Couldn't save the sign-in: {error}"))
    }

    pub fn forget(&self, app_id: &str) -> Result<(), String> {
        match std::fs::remove_file(self.secret_file(app_id)) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(format!("Couldn't forget the sign-in: {error}")),
        }
    }

    /// The 32-byte key, made the first time it's needed for writing.
    fn vault_key(&self, create_if_missing: bool) -> Result<Option<[u8; 32]>, String> {
        let uses_system_store = self.key_store == KeyStore::System && cfg!(any(target_os = "macos", target_os = "windows"));
        if uses_system_store {
            #[cfg(any(target_os = "macos", target_os = "windows"))]
            {
                let entry = keyring::Entry::new(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT_FOR_VAULT_KEY).map_err(|error| format!("The system key store isn't available: {error}"))?;
                match entry.get_password() {
                    Ok(hex_key) => return Ok(key_from_hex(&hex_key)),
                    Err(keyring::Error::NoEntry) if create_if_missing => {
                        let new_key = new_random_key();
                        entry.set_password(&hex_from_key(&new_key)).map_err(|error| format!("Couldn't save the vault key in the system key store: {error}"))?;
                        return Ok(Some(new_key));
                    }
                    Err(keyring::Error::NoEntry) => return Ok(None),
                    Err(error) => return Err(format!("The system key store refused: {error}")),
                }
            }
        }
        let key_file = self.paths.vault_key_file();
        if let Ok(hex_key) = std::fs::read_to_string(&key_file) {
            if let Some(key) = key_from_hex(hex_key.trim()) {
                return Ok(Some(key));
            }
        }
        if !create_if_missing {
            return Ok(None);
        }
        let new_key = new_random_key();
        create_private_folder(&self.paths.hub_folder()).map_err(|error| error.to_string())?;
        write_file_atomically(&key_file, hex_from_key(&new_key).as_bytes()).map_err(|error| format!("Couldn't save the vault key: {error}"))?;
        Ok(Some(new_key))
    }
}

fn new_random_key() -> [u8; 32] {
    use rand::RngCore;
    let mut key = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut key);
    key
}

fn hex_from_key(key: &[u8; 32]) -> String {
    key.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn key_from_hex(hex_key: &str) -> Option<[u8; 32]> {
    if hex_key.len() != 64 {
        return None;
    }
    let mut key = [0u8; 32];
    for (index, byte) in key.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&hex_key[index * 2..index * 2 + 2], 16).ok()?;
    }
    Some(key)
}

/// The file is `version byte || 12-byte nonce || ciphertext`. The app id is bound in as associated data, so one app's
/// file copied over another's doesn't open.
fn seal_secrets(key: &[u8; 32], app_id: &str, secrets: &AppSecrets) -> Result<Vec<u8>, String> {
    use rand::RngCore;
    let plain_bytes = serde_json::to_vec(secrets).map_err(|error| error.to_string())?;
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    let mut nonce_bytes = [0u8; 12];
    rand::rngs::OsRng.fill_bytes(&mut nonce_bytes);
    let sealed = cipher
        .encrypt(Nonce::from_slice(&nonce_bytes), Payload { msg: &plain_bytes, aad: app_id.as_bytes() })
        .map_err(|_| "Couldn't encrypt the sign-in.".to_string())?;
    let mut file_bytes = vec![1u8];
    file_bytes.extend_from_slice(&nonce_bytes);
    file_bytes.extend_from_slice(&sealed);
    Ok(file_bytes)
}

fn open_sealed_secrets(key: &[u8; 32], app_id: &str, file_bytes: &[u8]) -> Option<AppSecrets> {
    if file_bytes.len() < 13 || file_bytes[0] != 1 {
        return None;
    }
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    let plain_bytes = cipher.decrypt(Nonce::from_slice(&file_bytes[1..13]), Payload { msg: &file_bytes[13..], aad: app_id.as_bytes() }).ok()?;
    serde_json::from_slice(&plain_bytes).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secrets_round_trip_and_never_appear_in_the_file() {
        let folder = tempfile::tempdir().unwrap();
        let vault = Vault::new(HubPaths::new(folder.path()), KeyStore::File);
        let secrets = AppSecrets { pasted_token: Some("very-secret-token-value".into()), ..Default::default() };
        vault.write("notion", &secrets).unwrap();
        assert_eq!(vault.read("notion"), secrets);
        let on_disk = std::fs::read(folder.path().join("Connectors/vault/notion.secret")).unwrap();
        assert!(!String::from_utf8_lossy(&on_disk).contains("very-secret-token-value"));
        // Another app's name doesn't open it.
        std::fs::copy(folder.path().join("Connectors/vault/notion.secret"), folder.path().join("Connectors/vault/gmail.secret")).unwrap();
        assert_eq!(vault.read("gmail"), AppSecrets::default());
        vault.forget("notion").unwrap();
        assert_eq!(vault.read("notion"), AppSecrets::default());
    }
}
