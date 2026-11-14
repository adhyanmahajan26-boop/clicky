# Getting Theo onto Windows and Linux computers, for free

Theo is open source and doesn't make money, so the main route costs nothing: a one-line install from a GitHub release.
Signed installers are a later option, listed at the end with what each would cost.

## The main route: one line in a terminal

| Platform | Command | What it does |
|---|---|---|
| Linux | `curl -fsSL https://github.com/<owner>/<repo>/releases/latest/download/install-linux.sh \| bash` | Downloads the AppImage, checks it against `SHA256SUMS`, installs it to `~/.local/opt/theo`, links `~/.local/bin/theo`, adds Theo to the app menu. No root. |
| Windows | `irm https://github.com/<owner>/<repo>/releases/latest/download/install.ps1 \| iex` | Downloads the per-user installer, checks it against `SHA256SUMS`, runs it silently. No administrator rights. |
| Mac | `curl -fsSL https://github.com/<owner>/<repo>/releases/latest/download/install.sh \| bash` | The Swift app's installer ([docs/INSTALL.md](../../docs/INSTALL.md)): checks the zip's checksum and who signed it. |

Both scripts take the same options as the Mac `install.sh`: a build number, an install folder, `--from` a local file with
its `--sha256`, `--no-launch`, `--force`, `--uninstall` (keeps your bots, chats and memory), `--purge` (asks first; `--yes`
skips the question). They read the same environment: `THEO_RELEASES_REPO`, `THEO_INSTALL_DIR`, `THEO_GITHUB_TOKEN` (only for
a private releases repo; falls back to `GH_TOKEN`, `GITHUB_TOKEN`, then `gh auth token`; sent as a header, never on a command
line), `THEO_GITHUB_API`.

**Where releases come from.** `install/releases-repo` is the one place this side keeps the releases repo (owner/name); it must
match `THEO_RELEASES_REPO` in the Mac side's `Config/Theo.xcconfig`, and `Tools/set-releases-repo.sh` changes both
(`Tools/install/check-release-config.py` fails when they differ). The scripts in the repo leave the repo empty and read
`releases-repo` beside themselves; `tools/collect_installers.py` writes copies with it filled in, which are the ones a
release carries, so the one-liners need no settings. `THEO_RELEASES_REPO` overrides it. A copy with no repo at all (an
unstamped script piped from somewhere) says so instead of guessing.

**A private releases repo.** GitHub answers 404 for a private repo it won't show. Without a token both scripts then say
"this build's updates are private" and that the person should ask whoever gave them Theo for an installer, instead of a
sign-in step. With a token they say the token can't read the repo; 401, rate limits and no network each get their own line.
The Linux script runs everything from `main()` at the end, so a download cut short runs nothing; the PowerShell script
likewise only acts in `Main` at the end. `tests/install_test.py` and `tests/install_ps_test.py` check all of this against a
stand-in for GitHub's API (the Windows one installs and removes the real installer on a Windows runner).

## What a release holds

One GitHub release per build, tagged `build-<yyyyMMddHHmm>`, shared with the Mac app:

| Asset | Who it's for |
|---|---|
| `Theo-<build>.zip` | Mac (the Swift app; its updater takes the first `.zip`, so nothing else in a release ends in `.zip`) |
| `Theo-<build>-windows-x64-setup.exe` | Windows, per-user installer (NSIS); what `install.ps1` uses |
| `Theo-<build>-windows-x64.msi` | Windows, for anyone who wants an MSI (installs for all users, needs admin) |
| `Theo-<build>-linux-x86_64.AppImage` | Linux, any distribution; what `install-linux.sh` uses |
| `Theo-<build>-linux-amd64.deb` | Debian and Ubuntu: `sudo apt install ./Theo-…deb` |
| `install-linux.sh`, `install.ps1` | the one-liners above, with the releases repo written in (`tools/collect_installers.py`) |
| `install.sh`, `SIGNER` | the Mac one-liner and who signed the Mac build (`Tools/release.sh`) |
| `SHA256SUMS` | every asset above, in `shasum` format (`<hex>  <name>`); the installers refuse anything that doesn't match |

`tools/collect_installers.py` names the built installers this way, writes the two install scripts beside them, and adds
them all to `SHA256SUMS`. The Mac `install.sh` skips assets whose names contain `windows` or `linux`.

The CI workflow (`.github/workflows/crossplatform.yml`) builds every installer on each push and keeps them as workflow
artifacts. It never publishes a release.

## Decisions for Addy

1. **Where releases live.** The one-liners only work for strangers if the releases repo is public. Today the repo in
   `install/releases-repo` is private. Either make it public, or make a new public repo for releases and run
   `Tools/set-releases-repo.sh <owner>/<repo>`. Nothing here changes any repo's visibility.
2. **Publishing.** When you want a public build, add the Windows and Linux assets to the same `build-…` release as the Mac
   zip (the workflow's artifacts are ready to attach), then add the two install scripts and regenerate `SHA256SUMS`.

## Package managers (also free, later)

| Where | Effort | Note |
|---|---|---|
| winget | A manifest PR to `microsoft/winget-pkgs` per release | Unsigned installers are accepted, but SmartScreen still warns on first run |
| Scoop | A JSON manifest in your own bucket repo | No review needed |
| Flathub | A Flatpak manifest and review | Sandboxing gets in the way of running `claude` and `git` from the host; needs `--talk-name=org.freedesktop.Flatpak` and `flatpak-spawn --host`. Not recommended first |
| AUR | A PKGBUILD that fetches the AppImage or `.deb` | Easy |
| Homebrew (Linux) | A tap with a formula | Easy |

## Signing (a later option, not needed to ship)

| Platform | Without signing | Options |
|---|---|---|
| Windows | SmartScreen shows "Windows protected your PC" until the installer has a reputation; you click More info, Run anyway | **SignPath Foundation**: free code signing for open-source projects (apply with the public repo; signing then runs in CI). Or Azure Trusted Signing (about $10 a month, needs an identity check), or an OV certificate from a CA (about $200–400 a year) |
| Linux | Nothing warns: AppImages and `.deb` files aren't checked. The checksum in `SHA256SUMS` is the check | Optionally sign `SHA256SUMS` with a GPG or minisign key and publish the public key |
| Mac (this Tauri build only) | Gatekeeper blocks the first open; right-click, Open, or `xattr -d com.apple.quarantine` | An Apple Developer account ($99 a year) for a Developer ID certificate and notarization. There's no free route. The Swift Mac app has the same choice |

What CI would need once there's a certificate: Windows, the SignPath (or Azure) credentials as repository secrets and a
signing step after `tauri build`; Mac, `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_PASSWORD`
(app-specific) and `APPLE_TEAM_ID`, which `tauri build` uses to sign and notarize.
