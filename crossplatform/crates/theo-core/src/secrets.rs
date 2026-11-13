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
}
