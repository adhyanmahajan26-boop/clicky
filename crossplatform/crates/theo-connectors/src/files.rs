//! Small file helpers: where the hub keeps its files, writing a file so a crash never leaves half of it, keeping a file to
//! this user only, and a lock so two hub processes (a bot's `serve` and the Connectors screen's `check`) don't overwrite
//! each other's changes.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

/// Every file the hub owns lives under `<Theo's data folder>/Connectors`.
#[derive(Clone, Debug)]
pub struct HubPaths {
    pub data_folder: PathBuf,
}

impl HubPaths {
    pub fn new(data_folder: impl Into<PathBuf>) -> Self {
        Self { data_folder: data_folder.into() }
    }
    pub fn hub_folder(&self) -> PathBuf {
        self.data_folder.join("Connectors")
    }
    /// The list of apps: what the user added. Never holds a token.
    pub fn connector_list_file(&self) -> PathBuf {
        self.hub_folder().join("connectors.json")
    }
    /// What the hub last saw of each app: status, reason, when it last worked.
    pub fn connector_state_file(&self) -> PathBuf {
        self.hub_folder().join("state.json")
    }
    /// Each app's sign-in, encrypted (see `vault.rs`).
    pub fn vault_folder(&self) -> PathBuf {
        self.hub_folder().join("vault")
    }
    /// The vault's key when the system store isn't used (Linux, and test profiles).
    pub fn vault_key_file(&self) -> PathBuf {
        self.hub_folder().join("vault.key")
    }
    /// Where the apps write a ticket for each bot turn. The hub refuses a ticket anywhere else.
    pub fn ticket_folder(&self) -> PathBuf {
        self.hub_folder().join("tickets")
    }
    pub fn lock_file(&self, name: &str) -> PathBuf {
        self.hub_folder().join(format!(".{name}.lock"))
    }
}

/// Creates a folder (and its parents) that only this user can open, on Mac and Linux.
pub fn create_private_folder(folder: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(folder)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(folder, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Writes the whole file or nothing: a temporary file beside it, then a rename. On Mac and Linux the file is this user's
/// only from the moment it is created, so there is never a moment in which another account could read it.
pub fn write_file_atomically(destination: &Path, contents: &[u8]) -> std::io::Result<()> {
    if let Some(parent_folder) = destination.parent() {
        std::fs::create_dir_all(parent_folder)?;
    }
    let temporary_file = destination.with_extension(format!("tmp-{}", uuid::Uuid::new_v4().simple()));
    let mut open_options = std::fs::OpenOptions::new();
    open_options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        open_options.mode(0o600);
    }
    let write_result = (|| {
        let mut file = open_options.open(&temporary_file)?;
        file.write_all(contents)?;
        file.sync_all()?;
        Ok::<(), std::io::Error>(())
    })();
    if let Err(error) = write_result {
        let _ = std::fs::remove_file(&temporary_file);
        return Err(error);
    }
    // Windows refuses to rename over a file another process has open for a moment (an antivirus scan, a reader):
    // a few short retries cover that.
    let mut attempts_left = 20;
    loop {
        match std::fs::rename(&temporary_file, destination) {
            Ok(()) => return Ok(()),
            Err(error) if attempts_left > 0 && cfg!(windows) => {
                attempts_left -= 1;
                let _ = error;
                std::thread::sleep(Duration::from_millis(25));
            }
            Err(error) => {
                let _ = std::fs::remove_file(&temporary_file);
                return Err(error);
            }
        }
    }
}

/// A lock held by creating a file and released by removing it. A lock file older than `stale_after` belongs to a hub
/// that crashed while holding it, and is taken over.
pub struct FileLock {
    lock_file: PathBuf,
}

impl FileLock {
    pub fn acquire(lock_file: &Path, wait_at_most: Duration) -> std::io::Result<FileLock> {
        let stale_after = Duration::from_secs(60);
        if let Some(parent_folder) = lock_file.parent() {
            std::fs::create_dir_all(parent_folder)?;
        }
        let started_waiting_at = Instant::now();
        loop {
            match std::fs::OpenOptions::new().write(true).create_new(true).open(lock_file) {
                Ok(mut file) => {
                    let _ = write!(file, "{}", std::process::id());
                    return Ok(FileLock { lock_file: lock_file.to_path_buf() });
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists || error.kind() == std::io::ErrorKind::PermissionDenied => {
                    let lock_age = std::fs::metadata(lock_file)
                        .and_then(|metadata| metadata.modified())
                        .ok()
                        .and_then(|modified| SystemTime::now().duration_since(modified).ok());
                    if lock_age.map(|age| age > stale_after).unwrap_or(false) {
                        let _ = std::fs::remove_file(lock_file);
                        continue;
                    }
                    if started_waiting_at.elapsed() > wait_at_most {
                        return Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "another connector hub is busy with the same file"));
                    }
                    std::thread::sleep(Duration::from_millis(30));
                }
                Err(error) => return Err(error),
            }
        }
    }
}

impl Drop for FileLock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.lock_file);
    }
}

pub fn read_json_file<T: serde::de::DeserializeOwned>(file: &Path) -> std::io::Result<Option<T>> {
    match std::fs::read(file) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, format!("{} can't be read: {error}", file.display()))),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

pub fn write_json_file<T: serde::Serialize>(file: &Path, value: &T) -> std::io::Result<()> {
    let mut bytes = serde_json::to_vec_pretty(value).map_err(std::io::Error::other)?;
    bytes.push(b'\n');
    write_file_atomically(file, &bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_lock_waits_for_the_holder_and_takes_over_a_stale_one() {
        let folder = tempfile::tempdir().unwrap();
        let lock_file = folder.path().join(".state.lock");
        let first_lock = FileLock::acquire(&lock_file, Duration::from_secs(1)).unwrap();
        assert!(FileLock::acquire(&lock_file, Duration::from_millis(100)).is_err());
        drop(first_lock);
        let _second_lock = FileLock::acquire(&lock_file, Duration::from_millis(100)).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn written_files_are_this_users_only() {
        use std::os::unix::fs::PermissionsExt;
        let folder = tempfile::tempdir().unwrap();
        let file = folder.path().join("a").join("b.json");
        write_file_atomically(&file, b"one").unwrap();
        write_file_atomically(&file, b"two").unwrap();
        assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(std::fs::read(&file).unwrap(), b"two");
        assert_eq!(std::fs::read_dir(file.parent().unwrap()).unwrap().count(), 1);
    }
}
