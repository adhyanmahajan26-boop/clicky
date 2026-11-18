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

**Where releases come from.** `install/releases-repo` is the one place this side keeps the releases repo (owner/name). It may
differ from `THEO_RELEASES_REPO` in the Mac side's `Config/Theo.xcconfig`, and today it does: Windows builds are published to
this public source repo's own Releases (below), and the Mac's stay in their private releases repo.
`Tools/set-releases-repo.sh [--mac | --windows-linux] <owner>/<repo>` changes either or both, and
`Tools/install/check-release-config.py` checks each is set and named nowhere else in code. The scripts in the repo leave the repo empty and read
`releases-repo` beside themselves; `tools/collect_installers.py` writes copies with it filled in, which are the ones a
release carries, so the one-liners need no settings. `THEO_RELEASES_REPO` overrides it. A copy with no repo at all (an
unstamped script piped from somewhere) says so instead of guessing.

**A private releases repo.** GitHub answers 404 for a private repo it won't show. Without a token both scripts then say
"this build's updates are private" and that the person should ask whoever gave them Theo for an installer, instead of a
sign-in step. With a token they say the token can't read the repo; 401, rate limits and no network each get their own line.
The Linux script runs everything from `main()` at the end, so a download cut short runs nothing; the PowerShell script
likewise only acts in `Main` at the end. `tests/install_test.py` and `tests/install_ps_test.py` check all of this against a
stand-in for GitHub's API (the Windows one installs and removes the real installer on a Windows runner).

## Windows builds publish themselves

`.github/workflows/windows-release.yml` runs after each successful "Theo cross-platform" run from a push to `main`. It builds
nothing: it takes that run's tested Windows installers (`theo-installers-windows-2022`, carrying the run's `THEO_BUILD`),
names them `Vello-<build>-windows-x64-setup.exe` and `.msi`, adds `install.ps1`, the tester kit (`Theo-Test.ps1`,
`RUN-TEST.cmd`, `HOW-TO-TEST.txt`) with the repo written in, writes `SHA256SUMS`, and publishes release `build-<build>` as the
latest, with the commits since the previous one as its notes. It keeps the newest 15 and removes older ones. It publishes
only when `install/releases-repo` names the repo it runs in (the job's own token can't write anywhere else), and it runs on
a Linux runner for about a minute, which is free on a public repo. To publish a particular run by hand: Actions › Windows
release › Run workflow, with that run's id.

So a Windows PC installs once (`irm https://github.com/<owner>/<repo>/releases/latest/download/install.ps1 | iex`, or the
setup `.exe` from the releases page) and then updates itself from every green `main` build: Vello checks 20 seconds after it
opens and every 6 hours, and the Update row installs the new build silently and reopens. Linux builds aren't published this
way yet (the Linux and Windows jobs bake different build numbers), so a Linux copy says no Linux build is published.

**A tester's kit.** A tester keeps `RUN-TEST.cmd`. Each run swaps `Theo-Test.ps1` for the newest published copy (checked
against `SHA256SUMS`), installs the newest build if Vello isn't installed, and has the tester press Vello's own Update button
when the installed build is older, so the updater is tested every time. At the end it can send the results back itself:
the tester pastes a results code once, `<owner>/<repo> <token>`, kept encrypted for that Windows user (DPAPI) in
`%LOCALAPPDATA%\Vello-Tester`. The script asks before each send and puts `RESULTS.txt` and the zip in
`reports/<date>-<id>/` of that repo through GitHub's contents API; without a code, or if sending fails, the tester sends the
zip as before. To make a code: create a private repo for results (with a README, so it isn't empty), then a fine-grained
personal access token (GitHub › Settings › Developer settings › Fine-grained tokens) with access to that repo only and
the permission Contents: Read and write, and send the tester `<owner>/<repo> <token>`. The worst a leaked code can do is
write to that one repo.

## What a release holds

The Mac's releases: one GitHub release per build, tagged `build-<yyyyMMddHHmm>`. When both platforms share a releases repo,
a release may carry every platform's assets:

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
artifacts. It never publishes a release. It bakes a build number into the app (`THEO_BUILD`, the run's `yyyyMMddHHmm` in
UTC, also written to `dist/BUILD`); a release's tag must be that number (`build-<THEO_BUILD>`), or the in-app updater will
keep offering the same build. A build made by hand without `THEO_BUILD` is build 0 and says "a build made by hand".

**Which release each platform takes.** The Windows and Linux installers and the in-app updater list the releases
(`/releases?per_page=100`) and take the newest published `build-<number>` release that has their own asset and a
`SHA256SUMS`; drafts and prereleases don't count, and none of them reads `/releases/latest`. The Mac's updater does use
the latest release, so:

- A release with every platform's assets can be the latest, as before.
- A release with only Windows and Linux assets must not become the latest, or Macs would find no zip: publish it with
  `gh release create build-<n> … --latest=false`. Windows and Linux still find it.
- A Mac-only release (from `Tools/release.sh`) is fine: Windows and Linux skip it and keep the newest build that has theirs.

The one-liners download `install.ps1` / `install-linux.sh` from `releases/latest/download/`, so the latest release must
carry them (any build's copy works, since the scripts look for the newest build themselves).

**In-app updates on Windows and Linux.** The Update row at the bottom of the sidebar and Settings › Updates. The per-user
Windows install updates itself silently and reopens; an AppImage replaces itself; the .msi, the .deb and hand builds open
the releases page. Details: [PLATFORMS.md](PLATFORMS.md#updates).

## Decisions for Addy

1. **Where releases live.** Windows builds are published to this public repo's Releases (decided in November 2026, so
   a tester's copy updates itself with no token). The Mac's releases repo stays private; making it public, or moving the
   Mac's releases too, is `Tools/set-releases-repo.sh --mac <owner>/<repo>`. Nothing here changes any repo's visibility.
2. **Publishing.** Windows: automatic from `main` (above). Mac: `Tools/release.sh` on the Mac Studio.

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
