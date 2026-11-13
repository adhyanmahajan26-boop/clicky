//! The local API's token and the owner's model API keys: in the Keychain on macOS, the Credential Manager on Windows, and a
//! file only this user can read on Linux (Secret Service needs a running desktop keyring, which servers and CI don't have).
//! Nothing here ever prints or logs a key.

use std::path::Path;

const SERVICE: &str = "com.theo.desktop.gateway";
const ACCOUNT: &str = "token";

pub fn new_token() -> String {
    use rand::RngCore;
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// `token_file` is used on Linux, and everywhere in a test profile so the system store isn't touched by tests.
pub fn read(token_file: &Path, is_test: bool) -> Option<String> {
    if !is_test {
        #[cfg(any(target_os = "macos", target_os = "windows"))]
        {
            if let Ok(entry) = keyring::Entry::new(SERVICE, ACCOUNT) {
                if let Ok(token) = entry.get_password() {
                    return Some(token);
                }
            }
            return None;
        }
    }
    let _ = (SERVICE, ACCOUNT);
    std::fs::read_to_string(token_file).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}

pub fn write(token_file: &Path, is_test: bool, token: &str) -> std::io::Result<()> {
    if !is_test {
        #[cfg(any(target_os = "macos", target_os = "windows"))]
        {
            let entry = keyring::Entry::new(SERVICE, ACCOUNT).map_err(std::io::Error::other)?;
            return entry.set_password(token).map_err(std::io::Error::other);
        }
    }
    #[cfg(unix)]
    {
        // Created only-this-user from the start: writing it with the usual permissions and tightening them after would leave a
        // moment in which another account on the machine could read the token.
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        if let Some(parent) = token_file.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let temporary = token_file.with_extension(format!("tmp-{}", uuid::Uuid::new_v4().simple()));
        let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temporary)?;
        file.write_all(token.as_bytes())?;
        file.sync_all()?;
        drop(file);
        return std::fs::rename(&temporary, token_file);
    }
    #[cfg(not(unix))]
    {
        crate::store::write_atomic(token_file, token.as_bytes())
    }
}

/// Where API keys are kept as files (Linux, and every test profile): `<data>/Keys/<provider>`, only this user's. Bots are
/// denied reading this folder (`policy::secret_read_rules`).
pub fn api_keys_folder(data_root: &Path) -> std::path::PathBuf {
    data_root.join("Keys")
}

const API_KEY_SERVICE: &str = "com.theo.desktop.apikeys";

/// A provider id is lowercase letters, digits and dashes: it names a file and a Credential Manager entry.
pub fn is_provider_id(provider: &str) -> bool {
    !provider.is_empty() && provider.len() <= 32 && provider.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

/// The saved key for a model provider (`anthropic`, `openai`, ...), if there is one.
pub fn read_api_key(data_root: &Path, is_test: bool, provider: &str) -> Option<String> {
    // Only the Keychain and the Credential Manager use the service name; Linux keeps keys in the file.
    let _ = API_KEY_SERVICE;
    if !is_provider_id(provider) {
        return None;
    }
    if !is_test {
        #[cfg(any(target_os = "macos", target_os = "windows"))]
        {
            return keyring::Entry::new(API_KEY_SERVICE, provider).ok().and_then(|entry| entry.get_password().ok()).map(|key| key.trim().to_string()).filter(|key| !key.is_empty());
        }
    }
    read(&api_keys_folder(data_root).join(provider), true)
}

/// Saves a provider's key, or removes it with `None`.
pub fn write_api_key(data_root: &Path, is_test: bool, provider: &str, key: Option<&str>) -> std::io::Result<()> {
    if !is_provider_id(provider) {
        return Err(std::io::Error::other("That isn't a provider Theo knows."));
    }
    if !is_test {
        #[cfg(any(target_os = "macos", target_os = "windows"))]
        {
            let entry = keyring::Entry::new(API_KEY_SERVICE, provider).map_err(std::io::Error::other)?;
            return match key {
                Some(key) => entry.set_password(key.trim()).map_err(std::io::Error::other),
                None => match entry.delete_credential() {
                    Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
                    Err(error) => Err(std::io::Error::other(error)),
                },
            };
        }
    }
    let folder = api_keys_folder(data_root);
    let file = folder.join(provider);
    match key {
        Some(key) => {
            std::fs::create_dir_all(&folder)?;
            crate::paths::make_private(&folder);
            write(&file, true, key.trim())
        }
        None => match std::fs::remove_file(&file) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        },
    }
}

#[cfg(test)]
mod tests {
    #[cfg(unix)]
    #[test]
    fn the_token_file_is_only_this_users() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("theo").join("gateway-token");
        super::write(&file, true, "first").unwrap();
        super::write(&file, true, "second").unwrap();
        assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(super::read(&file, true).as_deref(), Some("second"));
        // No temporary copies are left beside it.
        assert_eq!(std::fs::read_dir(file.parent().unwrap()).unwrap().count(), 1);
    }

    #[test]
    fn api_keys_are_kept_and_removed_by_provider() {
        let dir = tempfile::tempdir().unwrap();
        assert!(super::read_api_key(dir.path(), true, "openai").is_none());
        super::write_api_key(dir.path(), true, "openai", Some(" sk-test \n")).unwrap();
        assert_eq!(super::read_api_key(dir.path(), true, "openai").as_deref(), Some("sk-test"));
        super::write_api_key(dir.path(), true, "openai", None).unwrap();
        super::write_api_key(dir.path(), true, "openai", None).unwrap();
        assert!(super::read_api_key(dir.path(), true, "openai").is_none());
        // A provider id can't name a file outside the folder.
        assert!(super::write_api_key(dir.path(), true, "../evil", Some("x")).is_err());
        assert!(super::read_api_key(dir.path(), true, "..").is_none());
    }
}
