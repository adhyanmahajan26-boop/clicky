//! In-app updates for Windows and Linux (the Mac's `UpdateController` and ClickyCore `UpdateFeed`).
//!
//! A build knows its own number from `THEO_BUILD`, set when it's built for a release (0 for a build made by hand). Releases
//! live in the repo named by `install/releases-repo`, compiled in, one per build, tagged `build-<number>` and shared with the
//! Mac. The Mac's updater reads GitHub's "latest release" and takes its first `.zip`, so a Windows-only or Linux-only release
//! (published with "latest" left off) must not be the one Windows looks for there: Theo lists the releases instead and takes
//! the newest `build-*` one that carries this platform's own installer and a `SHA256SUMS`. The download is checked against
//! that file before anything runs. A private releases repo needs a GitHub token (Settings › Updates, kept in the Credential
//! Manager) or `gh` signed in; a public one needs nothing.
//!
//! This file is the pure rules plus the check and the checked download. Running the installer and opening Theo again is the
//! desktop app's part (`app/src-tauri/src/updater.rs`); a test profile records the install instead.

use crate::harness::Harness;
use once_cell::sync::Lazy;
use serde::Serialize;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

/// How often Theo looks for a newer build while it runs (the Mac's 6 hours), after a first look 20 seconds in.
pub const CHECK_INTERVAL: Duration = Duration::from_secs(6 * 60 * 60);
pub const FIRST_CHECK_DELAY: Duration = Duration::from_secs(20);

/// The releases repo this side of Theo is published to (`install/releases-repo`, the file `Tools/set-releases-repo.sh` keeps
/// in step with the Mac's `Config/Theo.xcconfig`).
const BUNDLED_RELEASES_REPO: &str = include_str!("../../../install/releases-repo");

/// "202611140300", "build-202611140300" or nothing → this build's number; 0 for a build made by hand.
pub fn build_from_text(text: Option<&str>) -> u64 {
    let text = text.unwrap_or("").trim();
    let digits = text.strip_prefix("build-").unwrap_or(text);
    if digits.is_empty() || !digits.chars().all(|c| c.is_ascii_digit()) {
        return 0;
    }
    digits.parse().unwrap_or(0)
}

/// This build's number, baked in at build time from `THEO_BUILD` (crates/theo-core/build.rs rebuilds when it changes).
pub fn this_build() -> u64 {
    build_from_text(option_env!("THEO_BUILD"))
}

/// "0.1.0 (build 202611140300)", or "0.1.0 (a build made by hand)".
pub fn version_label(build: u64) -> String {
    let version = env!("CARGO_PKG_VERSION");
    if build == 0 { format!("{version} (a build made by hand)") } else { format!("{version} (build {build})") }
}

/// "owner/name" when the text looks like a GitHub repo, else None (an empty file says so instead of asking a wrong URL).
pub fn checked_repository(text: &str) -> Option<String> {
    let repository = text.trim();
    let parts: Vec<&str> = repository.split('/').collect();
    let allowed = |c: char| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.';
    if parts.len() == 2 && parts.iter().all(|part| !part.is_empty() && part.chars().all(allowed)) {
        Some(repository.to_string())
    } else {
        None
    }
}

/// The repo this build was made for. `THEO_RELEASES_REPO` overrides it, as for the install scripts; a test profile may set
/// `test.updates.repo`.
pub fn releases_repo(h: &Harness) -> Option<String> {
    if let Some(repo) = h.settings.string("test.updates.repo") {
        return checked_repository(&repo);
    }
    if let Some(repo) = std::env::var("THEO_RELEASES_REPO").ok().filter(|r| !r.trim().is_empty()) {
        return checked_repository(&repo);
    }
    checked_repository(BUNDLED_RELEASES_REPO)
}

/// GitHub's API, or a stand-in (`test.updates.api` in a test profile, `THEO_GITHUB_API` as for the install scripts).
fn api_base(h: &Harness) -> String {
    h.settings.string("test.updates.api")
        .or_else(|| std::env::var("THEO_GITHUB_API").ok().filter(|a| !a.trim().is_empty()))
        .unwrap_or_else(|| "https://api.github.com".to_string())
        .trim_end_matches('/')
        .to_string()
}

/// The end of the name of the installer this computer updates with (`tools/collect_installers.py` names them). None: no
/// build for this platform updates itself (the Tauri Mac build, Windows on ARM).
pub fn platform_asset_suffix(os: &str, arch: &str) -> Option<&'static str> {
    match (os, arch) {
        ("windows", "x86_64") => Some("-windows-x64-setup.exe"),
        ("linux", "x86_64") => Some("-linux-x86_64.AppImage"),
        ("linux", "aarch64") => Some("-linux-aarch64.AppImage"),
        _ => None,
    }
}

pub fn this_platform_suffix() -> Option<&'static str> {
    platform_asset_suffix(std::env::consts::OS, std::env::consts::ARCH)
}

/// What the platform is called in a sentence.
pub fn platform_words() -> &'static str {
    match std::env::consts::OS {
        "windows" => "Windows",
        "linux" => "Linux",
        "macos" => "this Mac build",
        _ => "this computer",
    }
}

/// "build-202610271200" → 202610271200. Anything else isn't a Theo build.
pub fn build_number_from_tag(tag: &str) -> Option<u64> {
    let digits = tag.trim().strip_prefix("build-")?;
    if digits.is_empty() || !digits.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    digits.parse().ok()
}

/// One release this platform can update to.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Release {
    pub build: u64,
    pub tag: String,
    pub asset_name: String,
    /// The API address of the installer (needed for a private repo, with a token and `Accept: application/octet-stream`).
    pub asset_api_url: String,
    /// The plain download address (a public repo).
    pub asset_download_url: String,
    pub sums_api_url: String,
    pub sums_download_url: String,
    pub notes: String,
    pub page: String,
}

/// The newest release in GitHub's release list that is a `build-*` release (not a draft or a pre-release) with this
/// platform's installer and a `SHA256SUMS`. Never "the latest release": that one may be a Mac-only or another platform's.
pub fn pick_newest(releases: &Value, suffix: &str) -> Option<Release> {
    let mut best: Option<Release> = None;
    for release in releases.as_array().into_iter().flatten() {
        if release["draft"].as_bool() == Some(true) || release["prerelease"].as_bool() == Some(true) {
            continue;
        }
        let tag = release["tag_name"].as_str().unwrap_or_default();
        let Some(build) = build_number_from_tag(tag) else { continue };
        let assets = release["assets"].as_array().cloned().unwrap_or_default();
        let named = |wanted: &dyn Fn(&str) -> bool| assets.iter().find(|a| a["name"].as_str().map(wanted).unwrap_or(false)).cloned();
        let lower_suffix = suffix.to_lowercase();
        let Some(installer) = named(&|name: &str| name.to_lowercase().ends_with(&lower_suffix)) else { continue };
        let Some(sums) = named(&|name: &str| name == "SHA256SUMS") else { continue };
        if best.as_ref().map(|b| b.build >= build).unwrap_or(false) {
            continue;
        }
        let text = |value: &Value, key: &str| value[key].as_str().unwrap_or_default().to_string();
        best = Some(Release {
            build,
            tag: tag.to_string(),
            asset_name: text(&installer, "name"),
            asset_api_url: text(&installer, "url"),
            asset_download_url: text(&installer, "browser_download_url"),
            sums_api_url: text(&sums, "url"),
            sums_download_url: text(&sums, "browser_download_url"),
            notes: release_notes(release["body"].as_str().unwrap_or_default()),
            page: text(release, "html_url"),
        });
    }
    best
}

/// The release's notes without its checksum lines, short enough for a tooltip.
fn release_notes(body: &str) -> String {
    let lines: Vec<&str> = body.lines().map(str::trim).filter(|l| !l.to_lowercase().starts_with("sha256:")).collect();
    let notes = lines.join("\n").trim().to_string();
    notes.chars().take(1500).collect()
}

/// The checksum `SHA256SUMS` gives `name` ("<hex>  <name>", or "<hex> *<name>" from a binary-mode tool), lowercase.
pub fn checksum_for(sums: &str, name: &str) -> Option<String> {
    for line in sums.lines() {
        let mut words = line.split_whitespace();
        let (Some(hex), Some(file)) = (words.next(), words.next()) else { continue };
        if file.trim_start_matches('*') == name && hex.len() == 64 && hex.chars().all(|c| c.is_ascii_hexdigit()) {
            return Some(hex.to_lowercase());
        }
    }
    None
}

pub fn is_newer(release_build: u64, current_build: u64) -> bool {
    release_build > current_build
}

/// What a failed check tells the person, from GitHub's answer (the Mac's `UpdateFeed.checkFailureMessage`). GitHub answers
/// 404 both for a repo that doesn't exist and for a private repo the request can't see, so without a token the honest answer
/// is that this build's updates are private, not a sign-in instruction most people can't follow.
pub fn check_failure_message(status: u16, sent_token: bool, repository: Option<&str>) -> String {
    let repository = repository.unwrap_or("the updates repo");
    match status {
        404 if !sent_token => format!(
            "This build's updates are private, so this computer can't see them. If you were given access to {repository}, paste a GitHub token that can read it below. Otherwise, new builds come from whoever gave you Theo."
        ),
        404 => format!("No updates found: {repository} has no published build yet, or the saved GitHub token can't read it."),
        401 => "GitHub refused the saved token. Paste a new one below, or remove it if the updates are public.".to_string(),
        403 | 429 => "GitHub is limiting how often this computer can check for updates. Theo tries again later by itself.".to_string(),
        _ => format!("The update check answered {status}."),
    }
}

/// How this copy of Theo was installed, which says how it can update itself.
#[derive(Clone, Debug, PartialEq)]
pub enum InstallKind {
    /// The per-user Windows installer: run the new one silently over the same folder.
    WindowsForThisUser { folder: PathBuf },
    /// The .msi, for everyone on the PC: needs an administrator, so the new .msi from the release page.
    WindowsForEveryone,
    /// An AppImage: replace the file.
    AppImage { file: PathBuf },
    /// The .deb, or a build made by hand, or the Tauri Mac build: the release page.
    Elsewhere,
}

/// `exe`: this program. `has_uninstaller`: the per-user installer's `uninstall.exe` is beside it. `appimage`: the AppImage
/// runtime's `APPIMAGE` variable.
pub fn install_kind(os: &str, exe: &Path, has_uninstaller: bool, program_files: &[PathBuf], appimage: Option<&Path>) -> InstallKind {
    match os {
        "windows" => {
            let lower = exe.to_string_lossy().to_lowercase();
            if program_files.iter().any(|folder| !folder.as_os_str().is_empty() && lower.starts_with(&folder.to_string_lossy().to_lowercase())) {
                InstallKind::WindowsForEveryone
            } else if has_uninstaller {
                InstallKind::WindowsForThisUser { folder: exe.parent().map(Path::to_path_buf).unwrap_or_default() }
            } else {
                InstallKind::Elsewhere
            }
        }
        "linux" => match appimage {
            Some(file) if file.is_absolute() => InstallKind::AppImage { file: file.to_path_buf() },
            _ => InstallKind::Elsewhere,
        },
        _ => InstallKind::Elsewhere,
    }
}

/// How this copy of Theo was installed, read from where it runs.
pub fn this_install_kind() -> InstallKind {
    let exe = std::env::current_exe().unwrap_or_default();
    let has_uninstaller = exe.parent().map(|dir| dir.join("uninstall.exe").exists()).unwrap_or(false);
    let program_files: Vec<PathBuf> = ["ProgramFiles", "ProgramFiles(x86)", "ProgramW6432"].iter().filter_map(|v| std::env::var_os(v)).map(PathBuf::from).collect();
    let appimage = std::env::var_os("APPIMAGE").map(PathBuf::from);
    install_kind(std::env::consts::OS, &exe, has_uninstaller, &program_files, appimage.as_deref())
}

fn powershell_quoted(text: &str) -> String {
    format!("'{}'", text.replace('\'', "''"))
}

/// The PowerShell script that waits for Theo (`pid`) to quit, runs the per-user installer silently over the same folder,
/// notes the build for install.ps1, and opens Theo again (the Mac's `UpdateFeed.installScript`). `/D=` must come last and
/// unquoted: NSIS takes the rest of the line as the folder, spaces and all.
pub fn windows_install_script(pid: u32, setup: &Path, folder: &Path, exe: &Path, build: u64, data_root: &Path) -> String {
    let log = data_root.join("Logs").join("update.log");
    let marker = data_root.join("INSTALLED_BUILD");
    let arguments = format!("/S /UPDATE /D={}", folder.display());
    format!(
        "# Theo's update to build {build}: waits for Theo (process {pid}) to quit, installs the new build over it and opens Theo again.\r\n\
$ErrorActionPreference = 'Continue'\r\n\
$log = {log}\r\n\
function Note([string]$text) {{ try {{ Add-Content -Path $log -Value ((Get-Date -Format o) + \"`t\" + $text) }} catch {{ }} }}\r\n\
for ($i = 0; $i -lt 300; $i++) {{ if (-not (Get-Process -Id {pid} -ErrorAction SilentlyContinue)) {{ break }}; Start-Sleep -Milliseconds 200 }}\r\n\
Note 'installing build {build}'\r\n\
$code = 1\r\n\
try {{ $proc = Start-Process -FilePath {setup} -ArgumentList {arguments} -Wait -PassThru; $code = $proc.ExitCode }} catch {{ Note (\"the installer didn't start: \" + $_) }}\r\n\
if ($code -eq 0) {{ Set-Content -Path {marker} -Value '{build}'; Note 'installed build {build}' }} else {{ Note (\"the installer stopped with code \" + $code) }}\r\n\
Start-Process -FilePath {exe}\r\n",
        log = powershell_quoted(&log.to_string_lossy()),
        setup = powershell_quoted(&setup.to_string_lossy()),
        arguments = powershell_quoted(&arguments),
        marker = powershell_quoted(&marker.to_string_lossy()),
        exe = powershell_quoted(&exe.to_string_lossy()),
    )
}

fn shell_quoted(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

/// Linux: once Theo (`pid`) has quit, open the new AppImage (it was swapped in while Theo still ran, which is safe: the
/// running copy keeps its own open file).
pub fn appimage_relaunch_script(pid: u32, appimage: &Path) -> String {
    format!("for i in $(seq 1 300); do kill -0 {pid} 2>/dev/null || break; sleep 0.2; done; exec {} >/dev/null 2>&1", shell_quoted(&appimage.to_string_lossy()))
}

/// Puts a checked AppImage in place of the running one: copied beside it, made runnable, then renamed over it, so a cut
/// copy never replaces a working one. The install script's `BUILD` file beside it is kept in step.
pub fn replace_appimage(new_file: &Path, target: &Path, build: u64) -> Result<(), String> {
    let folder = target.parent().ok_or("The AppImage has no folder.")?;
    let staged = folder.join(format!(".{}.new", target.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "Theo.AppImage".into())));
    std::fs::copy(new_file, &staged).map_err(|e| format!("couldn't write beside {} ({e})", target.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o755)).map_err(|e| e.to_string())?;
    }
    std::fs::rename(&staged, target).map_err(|e| {
        let _ = std::fs::remove_file(&staged);
        format!("couldn't replace {} ({e})", target.display())
    })?;
    let build_file = folder.join("BUILD");
    if build_file.exists() {
        let _ = std::fs::write(&build_file, format!("{build}\n"));
    }
    Ok(())
}

// MARK: - The check and the download

#[derive(Clone, Debug, PartialEq)]
pub enum Phase {
    Idle,
    Checking,
    UpToDate,
    Available,
    Installing(String),
    Failed(String),
}

#[derive(Clone, Debug)]
struct UpdateState {
    phase: Phase,
    release: Option<Release>,
    checked_at: Option<chrono::DateTime<chrono::Utc>>,
    /// Said once after Theo opens on the build it just updated to.
    just_updated: Option<u64>,
}

static STATE: Lazy<Mutex<UpdateState>> = Lazy::new(|| Mutex::new(UpdateState { phase: Phase::Idle, release: None, checked_at: None, just_updated: None }));

fn set_phase(phase: Phase) {
    STATE.lock().unwrap().phase = phase;
}

/// The token for a private releases repo: the one saved in Settings › Updates, else this computer's own GitHub sign-in
/// (`gh auth token`), as on the Mac. A public repo needs neither. A test profile never asks gh.
async fn access_token(h: &Harness) -> Option<String> {
    if let Some(token) = crate::secrets::read_update_token(&h.paths.root, h.settings.is_test) {
        return Some(token);
    }
    if h.settings.is_test {
        return None;
    }
    let gh = crate::engine::locate("gh")?;
    let (code, stdout, _) = crate::engine::run_briefly(&gh, &["auth", "token", "--hostname", "github.com"], &crate::paths::home(), Duration::from_secs(15)).await?;
    let token = stdout.trim().to_string();
    (code == 0 && !token.is_empty() && !token.contains(char::is_whitespace)).then_some(token)
}

fn request(address: &str, accept: &str, token: Option<&str>) -> ureq::Request {
    let request = crate::apichat::http_agent(address).get(address).set("Accept", accept).set("X-GitHub-Api-Version", "2022-11-28");
    match token {
        Some(token) => request.set("Authorization", &format!("Bearer {token}")),
        None => request,
    }
}

/// Looks for a newer build. `quietly` (the checks Theo makes by itself): a failure leaves things as they were.
pub async fn check(h: &Harness, quietly: bool) -> Value {
    let previous = {
        let state = STATE.lock().unwrap();
        if matches!(state.phase, Phase::Installing(_)) {
            drop(state);
            return report(h);
        }
        state.clone()
    };
    if !quietly {
        set_phase(Phase::Checking);
    }
    let fail = |message: String| {
        let mut state = STATE.lock().unwrap();
        if quietly { *state = previous.clone(); } else { state.phase = Phase::Failed(message); }
    };
    let Some(suffix) = this_platform_suffix() else {
        fail(format!("Theo can't update itself on {} yet. New builds are on the releases page.", platform_words()));
        return report(h);
    };
    let Some(repo) = releases_repo(h) else {
        fail("This build doesn't say where its updates come from, so it can't check for new ones.".into());
        return report(h);
    };
    let token = access_token(h).await;
    let address = format!("{}/repos/{repo}/releases?per_page=100", api_base(h));
    let sent_token = token.is_some();
    let answer = tokio::task::spawn_blocking(move || {
        match request(&address, "application/vnd.github+json", token.as_deref()).timeout(Duration::from_secs(30)).call() {
            Ok(response) => response.into_string().map(|body| (200u16, body)).map_err(|e| e.to_string()),
            Err(ureq::Error::Status(status, _)) => Ok((status, String::new())),
            Err(error) => Err(crate::apichat::transport_problem(&error)),
        }
    }).await.unwrap_or_else(|e| Err(e.to_string()));
    let (status, body) = match answer {
        Ok(answer) => answer,
        Err(problem) => {
            fail(format!("Couldn't reach the updates repo: {problem}"));
            return report(h);
        }
    };
    if status != 200 {
        fail(check_failure_message(status, sent_token, Some(&repo)));
        return report(h);
    }
    let releases: Value = serde_json::from_str(&body).unwrap_or(Value::Null);
    let Some(release) = pick_newest(&releases, suffix) else {
        fail(format!("No {} build is published in {repo} yet.", platform_words()));
        return report(h);
    };
    {
        let mut state = STATE.lock().unwrap();
        state.phase = if is_newer(release.build, this_build()) { Phase::Available } else { Phase::UpToDate };
        state.release = Some(release);
        state.checked_at = Some(chrono::Utc::now());
    }
    report(h)
}

/// Where downloads wait until they're installed.
fn updates_dir(h: &Harness) -> PathBuf {
    h.paths.root.join("Updates")
}

fn download_to(address_api: &str, address_plain: &str, token: Option<&str>, file: &Path) -> Result<(), String> {
    // A private repo: the API address with the token. A public one: the plain address, no token sent anywhere.
    let request = match token {
        Some(token) if !address_api.is_empty() => request(address_api, "application/octet-stream", Some(token)),
        _ => request(if address_plain.is_empty() { address_api } else { address_plain }, "application/octet-stream", None),
    };
    let response = request.timeout(Duration::from_secs(900)).call().map_err(|e| match e {
        ureq::Error::Status(status, _) => format!("the download answered {status}"),
        other => crate::apichat::transport_problem(&other),
    })?;
    let mut out = std::fs::File::create(file).map_err(|e| e.to_string())?;
    std::io::copy(&mut response.into_reader(), &mut out).map_err(|e| format!("the download was cut short ({e})"))?;
    Ok(())
}

pub fn sha256_of(file: &Path) -> std::io::Result<String> {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    let mut input = std::fs::File::open(file)?;
    std::io::copy(&mut input, &mut hasher)?;
    Ok(hasher.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

/// Downloads the waiting build's installer and checks it against the release's `SHA256SUMS`. A file that doesn't match is
/// deleted and nothing runs.
pub async fn download(h: &Harness) -> Result<(PathBuf, Release), String> {
    let release = {
        let state = STATE.lock().unwrap();
        match (&state.phase, &state.release) {
            (Phase::Installing(_), _) => return Err("An update is already under way.".into()),
            (_, Some(release)) if is_newer(release.build, this_build()) => release.clone(),
            _ => return Err("There's no newer build to install. Check for updates first.".into()),
        }
    };
    set_phase(Phase::Installing(format!("Downloading build {}…", release.build)));
    let token = access_token(h).await;
    let folder = updates_dir(h);
    let _ = std::fs::remove_dir_all(&folder);
    let result = {
        let release = release.clone();
        let folder = folder.clone();
        tokio::task::spawn_blocking(move || -> Result<PathBuf, String> {
            std::fs::create_dir_all(&folder).map_err(|e| e.to_string())?;
            crate::paths::make_private(&folder);
            // The name comes from GitHub: only its last part, so it can't point outside the folder.
            let safe_name = Path::new(&release.asset_name).file_name().map(|n| n.to_string_lossy().to_string()).filter(|n| !n.starts_with('.')).ok_or("the release's installer has no usable name")?;
            let installer = folder.join(&safe_name);
            download_to(&release.asset_api_url, &release.asset_download_url, token.as_deref(), &installer)?;
            let sums_file = folder.join("SHA256SUMS");
            download_to(&release.sums_api_url, &release.sums_download_url, token.as_deref(), &sums_file)?;
            let sums = std::fs::read_to_string(&sums_file).map_err(|e| e.to_string())?;
            let expected = checksum_for(&sums, &release.asset_name).ok_or_else(|| format!("SHA256SUMS doesn't list {}, so it isn't installed", release.asset_name))?;
            let actual = sha256_of(&installer).map_err(|e| e.to_string())?;
            if actual != expected {
                let _ = std::fs::remove_file(&installer);
                return Err("the download doesn't match its checksum, so it isn't installed".into());
            }
            Ok(installer)
        }).await.unwrap_or_else(|e| Err(e.to_string()))
    };
    match result {
        Ok(file) => {
            set_phase(Phase::Installing("Installing…".into()));
            Ok((file, release))
        }
        Err(problem) => {
            let message = format!("Update failed: {problem}.");
            {
                let mut state = STATE.lock().unwrap();
                state.phase = Phase::Failed(message.clone());
            }
            Err(message)
        }
    }
}

/// The app couldn't hand over to the installer after the download: say why, keep the build on offer.
pub fn install_failed(message: &str) {
    set_phase(Phase::Failed(message.to_string()));
}

/// The app is about to quit and run the installer: remembered, so the next start can say whether it worked.
pub fn note_pending(h: &Harness, build: u64) {
    let _ = std::fs::create_dir_all(updates_dir(h));
    let _ = std::fs::write(updates_dir(h).join("pending"), build.to_string());
}

/// At start: if Theo quit to install a build, whether it's that build now. Called once by the app.
pub fn after_launch(h: &Harness) {
    let pending = updates_dir(h).join("pending");
    let Some(wanted) = std::fs::read_to_string(&pending).ok().map(|t| build_from_text(Some(&t))) else { return };
    let _ = std::fs::remove_dir_all(updates_dir(h));
    let mut state = STATE.lock().unwrap();
    if this_build() >= wanted {
        state.just_updated = Some(this_build());
    } else {
        state.phase = Phase::Failed(format!("The update to build {wanted} didn't finish, so this is still build {}. Check again to retry; Logs/update.log says what happened.", this_build()));
    }
}

/// A test profile never replaces anything: it downloads and checks the build, then writes what the Update button would do
/// in `Logs/opened.log`.
async fn record_install(h: &Harness) -> Result<Value, String> {
    let (file, release) = download(h).await?;
    let folder = h.paths.logs_dir();
    let _ = std::fs::create_dir_all(&folder);
    use std::io::Write;
    if let Ok(mut log) = std::fs::OpenOptions::new().create(true).append(true).open(folder.join("opened.log")) {
        let _ = writeln!(log, "update install build {} {}", release.build, release.asset_name);
    }
    set_phase(Phase::Available);
    Ok(json!({"recorded": true, "build": release.build, "file": file, "verified": true}))
}

fn phase_words(phase: &Phase) -> (&'static str, String) {
    match phase {
        Phase::Idle => ("idle", "Theo checks when it starts and every 6 hours. Updating keeps your bots, chats and settings.".into()),
        Phase::Checking => ("checking", "Checking…".into()),
        Phase::UpToDate => ("upToDate", "You have the newest build.".into()),
        Phase::Available => ("available", "A newer build is ready. Theo quits, updates itself and reopens, keeping your bots, chats and settings.".into()),
        Phase::Installing(message) => ("installing", message.clone()),
        Phase::Failed(message) => ("failed", message.clone()),
    }
}

/// Everything Settings › Updates and the sidebar's Update row show. Never the token, only whether one is saved.
pub fn report(h: &Harness) -> Value {
    let state = STATE.lock().unwrap().clone();
    let (word, mut message) = phase_words(&state.phase);
    // Right after an update, until the next check: say it worked.
    if let (Some(build), Phase::Idle | Phase::UpToDate) = (state.just_updated, &state.phase) {
        message = format!("Updated to build {build}. Your bots, chats and settings are as they were.");
    }
    let repo = releases_repo(h);
    let kind = this_install_kind();
    let available = state.release.as_ref().filter(|r| is_newer(r.build, this_build()) && matches!(state.phase, Phase::Available | Phase::Installing(_) | Phase::Failed(_)));
    json!({
        "build": this_build(),
        "version": env!("CARGO_PKG_VERSION"),
        "label": version_label(this_build()),
        "repo": repo,
        "page": repo.as_ref().map(|r| format!("https://github.com/{r}/releases")),
        "platform": platform_words(),
        "supported": this_platform_suffix().is_some(),
        "installsItself": matches!(kind, InstallKind::WindowsForThisUser { .. } | InstallKind::AppImage { .. }),
        "installKind": match kind { InstallKind::WindowsForThisUser { .. } => "windowsForThisUser", InstallKind::WindowsForEveryone => "windowsForEveryone", InstallKind::AppImage { .. } => "appImage", InstallKind::Elsewhere => "elsewhere" },
        "state": word,
        "message": message,
        "available": available.map(|r| json!({"build": r.build, "tag": r.tag, "asset": r.asset_name, "notes": r.notes, "page": r.page})),
        "newest": state.release.as_ref().map(|r| r.build),
        "checkedAt": state.checked_at.map(|t| t.to_rfc3339()),
        "justUpdated": state.just_updated,
        "hasToken": crate::secrets::read_update_token(&h.paths.root, h.settings.is_test).is_some(),
        "autoCheck": !h.settings.is_test,
    })
}

/// The `updates` control command: `{action: state | check | token {token} | removeToken | install | openPage}`.
/// `install` here is the test profile's: the desktop app installs through its own `install_update` command.
pub async fn control(h: &Harness, cmd: &Value) -> Result<Value, String> {
    match cmd.get("action").and_then(|a| a.as_str()).unwrap_or("state") {
        "state" => Ok(report(h)),
        "check" => Ok(check(h, false).await),
        "token" => {
            let token = cmd.get("token").and_then(|t| t.as_str()).unwrap_or_default().trim().to_string();
            if token.is_empty() || token.len() > 255 || token.chars().any(|c| c.is_whitespace() || c.is_control()) {
                return Err("Paste the whole token: one line, no spaces.".into());
            }
            crate::secrets::write_update_token(&h.paths.root, h.settings.is_test, Some(&token)).map_err(|e| format!("The token wasn't saved: {e}"))?;
            Ok(check(h, false).await)
        }
        "removeToken" => {
            crate::secrets::write_update_token(&h.paths.root, h.settings.is_test, None).map_err(|e| e.to_string())?;
            Ok(report(h))
        }
        "install" => {
            if !h.settings.is_test {
                return Err("Theo's window installs updates: use the Update button there.".into());
            }
            record_install(h).await
        }
        "openPage" => {
            let page = releases_repo(h).map(|r| format!("https://github.com/{r}/releases")).ok_or("This build doesn't say where its updates come from.")?;
            crate::hub::open_in_browser(h, &page);
            Ok(json!({"opened": page}))
        }
        _ => Err("The updates actions are state, check, token, removeToken, install and openPage.".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn asset(name: &str) -> Value {
        json!({"name": name, "url": format!("https://api.github.com/assets/{name}"), "browser_download_url": format!("https://github.com/o/r/releases/download/x/{name}")})
    }

    fn release(tag: &str, names: &[&str]) -> Value {
        json!({"tag_name": tag, "draft": false, "prerelease": false, "body": "Fixes.\r\nsha256: abc", "html_url": format!("https://github.com/o/r/releases/tag/{tag}"),
               "assets": names.iter().map(|n| asset(n)).collect::<Vec<_>>()})
    }

    #[test]
    fn a_build_number_comes_from_the_build() {
        assert_eq!(build_from_text(None), 0);
        assert_eq!(build_from_text(Some("")), 0);
        assert_eq!(build_from_text(Some("202611140300")), 202611140300);
        assert_eq!(build_from_text(Some("build-202611140300")), 202611140300);
        assert_eq!(build_from_text(Some("ci-12")), 0);
        assert!(version_label(0).contains("made by hand"));
        assert!(version_label(5).ends_with("(build 5)"));
    }

    #[test]
    fn tags_are_builds_only_when_they_say_so() {
        assert_eq!(build_number_from_tag("build-202610271200"), Some(202610271200));
        assert_eq!(build_number_from_tag("v1.2"), None);
        assert_eq!(build_number_from_tag("build-"), None);
        assert_eq!(build_number_from_tag("build-12a"), None);
    }

    #[test]
    fn the_newest_release_with_this_platforms_installer_wins_not_the_latest() {
        let suffix = "-windows-x64-setup.exe";
        let releases = json!([
            // The newest is Mac-only: the Mac's "latest". Windows skips it.
            release("build-300", &["Theo-300.zip", "SHA256SUMS", "install.sh"]),
            // A Linux-only one, newer than the last Windows build.
            release("build-250", &["Theo-250-linux-x86_64.AppImage", "SHA256SUMS"]),
            release("build-200", &["Theo-200.zip", "Theo-200-windows-x64-setup.exe", "Theo-200-windows-x64.msi", "SHA256SUMS"]),
            release("build-100", &["Theo-100-windows-x64-setup.exe", "SHA256SUMS"]),
        ]);
        let picked = pick_newest(&releases, suffix).unwrap();
        assert_eq!(picked.build, 200);
        assert_eq!(picked.asset_name, "Theo-200-windows-x64-setup.exe");
        assert!(picked.sums_api_url.ends_with("/SHA256SUMS"));
        assert_eq!(picked.notes, "Fixes.");
        assert_eq!(pick_newest(&releases, "-linux-x86_64.AppImage").unwrap().build, 250);
    }

    #[test]
    fn order_doesnt_matter_and_drafts_prereleases_and_unchecked_builds_are_skipped() {
        let suffix = "-windows-x64-setup.exe";
        let mut draft = release("build-900", &["Theo-900-windows-x64-setup.exe", "SHA256SUMS"]);
        draft["draft"] = json!(true);
        let mut beta = release("build-800", &["Theo-800-windows-x64-setup.exe", "SHA256SUMS"]);
        beta["prerelease"] = json!(true);
        let releases = json!([
            release("build-100", &["Theo-100-windows-x64-setup.exe", "SHA256SUMS"]),
            draft, beta,
            release("build-700", &["Theo-700-windows-x64-setup.exe"]),
            release("nightly", &["Theo-nightly-windows-x64-setup.exe", "SHA256SUMS"]),
            release("build-150", &["Theo-150-windows-x64-setup.exe", "SHA256SUMS"]),
        ]);
        assert_eq!(pick_newest(&releases, suffix).unwrap().build, 150);
        assert!(pick_newest(&json!([]), suffix).is_none());
        assert!(pick_newest(&json!({"message": "Not Found"}), suffix).is_none());
    }

    #[test]
    fn newer_means_a_higher_build() {
        assert!(is_newer(202611140300, 202611130000));
        assert!(!is_newer(202611130000, 202611130000));
        assert!(is_newer(1, 0));
    }

    #[test]
    fn sha256sums_lines_are_read_by_exact_name() {
        let hex = "a".repeat(64);
        let sums = format!("{hex}  Theo-1-windows-x64-setup.exe\n{}  Theo-1-windows-x64.msi\n{} *Theo-1-linux-x86_64.AppImage\nnot a line\n", "b".repeat(64), "C".repeat(64));
        assert_eq!(checksum_for(&sums, "Theo-1-windows-x64-setup.exe"), Some(hex));
        assert_eq!(checksum_for(&sums, "Theo-1-linux-x86_64.AppImage"), Some("c".repeat(64)));
        assert_eq!(checksum_for(&sums, "Theo-1-windows-x64-setup"), None);
        assert_eq!(checksum_for("abc  Theo.exe", "Theo.exe"), None);
    }

    #[test]
    fn a_private_repo_is_said_plainly() {
        let private = check_failure_message(404, false, Some("o/r"));
        assert!(private.contains("updates are private") && private.contains("o/r") && !private.contains("auth login"));
        assert!(check_failure_message(404, true, Some("o/r")).contains("can't read it"));
        assert!(check_failure_message(401, true, None).contains("refused the saved token"));
        assert!(check_failure_message(429, false, None).contains("limiting"));
        assert_eq!(check_failure_message(500, false, None), "The update check answered 500.");
    }

    #[test]
    fn repos_look_like_owner_and_name() {
        assert_eq!(checked_repository(" owner/theo-releases\n").as_deref(), Some("owner/theo-releases"));
        assert!(checked_repository("").is_none());
        assert!(checked_repository("owner").is_none());
        assert!(checked_repository("a/b/c").is_none());
        assert!(checked_repository("$(THEO_RELEASES_REPO)").is_none());
        assert!(checked_repository(BUNDLED_RELEASES_REPO).is_some());
    }

    #[test]
    fn each_platform_updates_with_its_own_installer() {
        assert_eq!(platform_asset_suffix("windows", "x86_64"), Some("-windows-x64-setup.exe"));
        assert_eq!(platform_asset_suffix("linux", "x86_64"), Some("-linux-x86_64.AppImage"));
        assert_eq!(platform_asset_suffix("windows", "aarch64"), None);
        assert_eq!(platform_asset_suffix("macos", "aarch64"), None);
    }

    #[test]
    fn how_theo_was_installed_says_how_it_updates() {
        // Windows paths, written so they also split into folders when the test runs elsewhere.
        let (sep, drive) = if cfg!(windows) { ("\\", "C:") } else { ("/", "/c") };
        let windows_path = |parts: &[&str]| PathBuf::from(format!("{drive}{sep}{}", parts.join(sep)));
        let program_files = vec![windows_path(&["Program Files"]), windows_path(&["Program Files (x86)"])];
        let per_user = windows_path(&["Users", "Some One", "AppData", "Local", "Theo", "theo-desktop.exe"]);
        assert_eq!(install_kind("windows", &per_user, true, &program_files, None), InstallKind::WindowsForThisUser { folder: windows_path(&["Users", "Some One", "AppData", "Local", "Theo"]) });
        let lower_case = PathBuf::from(windows_path(&["program files", "Theo", "theo-desktop.exe"]).to_string_lossy().to_lowercase());
        assert_eq!(install_kind("windows", &lower_case, true, &program_files, None), InstallKind::WindowsForEveryone);
        assert_eq!(install_kind("windows", &windows_path(&["src", "target", "release", "theo-desktop.exe"]), false, &program_files, None), InstallKind::Elsewhere);
        assert_eq!(install_kind("linux", Path::new("/tmp/.mount_x/usr/bin/theo-desktop"), false, &[], Some(Path::new("/home/a/.local/opt/theo/Theo.AppImage"))),
                   InstallKind::AppImage { file: PathBuf::from("/home/a/.local/opt/theo/Theo.AppImage") });
        assert_eq!(install_kind("linux", Path::new("/usr/bin/theo-desktop"), false, &[], None), InstallKind::Elsewhere);
    }

    #[test]
    fn the_windows_script_waits_installs_over_the_same_folder_and_reopens() {
        let script = windows_install_script(4242, Path::new(r"C:\Users\my user's\AppData\Roaming\Theo-Desktop\Updates\Theo-7-windows-x64-setup.exe"),
                                            Path::new(r"C:\Users\my user's\AppData\Local\Theo"), Path::new(r"C:\Users\my user's\AppData\Local\Theo\theo-desktop.exe"), 7,
                                            Path::new(r"C:\Users\my user's\AppData\Roaming\Theo-Desktop"));
        assert!(script.contains("Get-Process -Id 4242"));
        assert!(script.contains(r"-ArgumentList '/S /UPDATE /D=C:\Users\my user''s\AppData\Local\Theo'"));
        assert!(script.contains(r"-FilePath 'C:\Users\my user''s\AppData\Roaming\Theo-Desktop\Updates\Theo-7-windows-x64-setup.exe'"));
        let marker = Path::new(r"C:\Users\my user's\AppData\Roaming\Theo-Desktop").join("INSTALLED_BUILD").to_string_lossy().replace('\'', "''");
        assert!(script.contains(&format!("Set-Content -Path '{marker}' -Value '7'")));
        assert!(script.trim_end().ends_with(r"Start-Process -FilePath 'C:\Users\my user''s\AppData\Local\Theo\theo-desktop.exe'"));
    }

    #[test]
    fn an_appimage_is_swapped_whole_and_its_build_noted() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("Theo.AppImage");
        std::fs::write(&target, "old").unwrap();
        std::fs::write(dir.path().join("BUILD"), "1\n").unwrap();
        let new = dir.path().join("download");
        std::fs::write(&new, "new").unwrap();
        replace_appimage(&new, &target, 9).unwrap();
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "new");
        assert_eq!(std::fs::read_to_string(dir.path().join("BUILD")).unwrap(), "9\n");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&target).unwrap().permissions().mode() & 0o777, 0o755);
        }
        let script = appimage_relaunch_script(7, Path::new("/home/o'neil/Theo.AppImage"));
        assert!(script.contains("kill -0 7") && script.contains(r"exec '/home/o'\''neil/Theo.AppImage'"));
    }

    #[test]
    fn a_checksum_is_of_the_whole_file() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("x");
        std::fs::write(&file, "abc").unwrap();
        assert_eq!(sha256_of(&file).unwrap(), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    }
}
