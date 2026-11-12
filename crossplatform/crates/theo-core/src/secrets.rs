//! The local API's token: in the Keychain on macOS, the Credential Manager on Windows, and a file only this user can read on
//! Linux (Secret Service needs a running desktop keyring, which servers and CI don't have).

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
    crate::store::write_atomic(token_file, token.as_bytes())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(token_file, std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}
