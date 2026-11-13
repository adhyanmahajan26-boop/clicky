# Installing Theo from Terminal

Theo installs the way OpenClaw and Hermes do: one line in Terminal, no paid Apple
Developer account, no notarization.

```bash
curl -fsSL https://github.com/<releases repo>/releases/latest/download/install.sh | bash
```

Run the same line again to upgrade. To remove Theo:

```bash
curl -fsSL https://github.com/<releases repo>/releases/latest/download/install.sh | bash -s -- --uninstall
```

`<releases repo>` is the GitHub repo the builds are published to. For builds made from this repo it is
`THEO_RELEASES_REPO` in [Config/Theo.xcconfig](../Config/Theo.xcconfig), the one place it is set on the Mac side (the
Windows and Linux installers read `crossplatform/install/releases-repo`; `Tools/set-releases-repo.sh` changes both).
The install.sh attached to a release has that repo written in, so the line above needs no settings.

If the releases repo is **private**, a stranger can't install or update from it: the installer and Theo's Update button
both say "this build's updates are private" rather than asking for a GitHub sign-in. Someone who does have access can set
`THEO_GITHUB_TOKEN` (or be signed in with `gh`) for the installer, or paste a token in Settings › Updates for the app.

`--uninstall` keeps chats, bots and settings; `--uninstall --purge` also moves them to the
Trash and removes Theo's saved keys and macOS permissions (it asks first). Other options:
`--version <build>`, `--dir <folder>`, `--no-launch`, `--force`, `--from <zip> --sha256 <hex>`,
`--allow-new-signer`; `--help` lists them.

With Homebrew, once the tap repo exists (see below):

```bash
brew install --cask <owner>/theo/theo
```

## Why this works without an Apple Developer account

macOS only runs its "Apple could not verify Theo" check (Gatekeeper) on files that carry the
quarantine flag, and only browsers, Mail, AirDrop and the like set that flag. `curl` doesn't, so
an app fetched by the script opens normally. `spctl --assess` rejects Theo (it isn't notarized),
which is exactly what a double-clicked browser download would run into.

Because Gatekeeper isn't checking, the script does the checking itself, and stops without
changing anything if any check fails:

1. The zip's SHA-256 must match the release's `SHA256SUMS` asset (or, for releases made before
   the installer existed, the `sha256:` line in the release notes).
2. The app inside must have a valid signature (`codesign --verify --deep --strict`).
3. It must be Theo (bundle id `com.personal.clicky`) and satisfy Theo's **signer rule**, a code
   requirement naming who signs Theo. The first one found is used:
   1. `THEO_SIGNER_REQUIREMENT`, if set;
   2. the rule `Tools/release.sh` wrote into the install.sh it published with the release;
   3. the release's `SIGNER` file, only if the release's `SHA256SUMS` lists it and it matches;
   4. none, which is only allowed when upgrading (the next check then decides).

   A rule is accepted only in one of two forms, and anything looser is refused:
   `identifier "com.personal.clicky" and anchor apple generic and certificate leaf[subject.OU] = "<team>"`
   (an Apple certificate of one team), or
   `identifier "com.personal.clicky" and certificate leaf = H"<SHA-1>"` (one self-signed certificate).
   `Tools/install/signer-requirement.sh` prints the right one for a signed app.
4. When Theo is already installed, the new app must also satisfy the **installed Theo's own
   designated requirement**, the rule macOS keeps its permissions against (Theo's Update button
   checks the same). So a release whose zip and `SIGNER` were both replaced still can't replace an
   installed Theo. A deliberate change of signer needs `--allow-new-signer`, and macOS then asks for
   the permissions again.

The checksum guards against a broken or swapped download; the signer rule guards against a
release asset that was replaced with something else, since only Theo's signing key can produce
that signature. No Apple team is written in the repo's copy of the script: a fork that signs with
its own team publishes its own `SIGNER` file and install.sh, and nothing in the script changes.

The install itself is copy-then-rename beside the destination, so a failure never leaves a
half-replaced app; on an upgrade the running Theo is asked to quit (SIGTERM, the same way the
test suites stop it) and is reopened afterwards. A `Clicky --mcp` helper (Theo's MCP server, run by
Claude Code, T3 Code or OpenCode) is left running: it belongs to another session, keeps the old copy until that
session restarts it, and quitting it would cut that session's tools. `/Applications` is used when it's writable
without a password (it is for administrator accounts), otherwise `~/Applications`. No `sudo`.

## Permissions (Accessibility, Screen Recording, Microphone)

macOS remembers a permission against the app's *designated requirement*, not its path. Theo is
signed with the free Apple Development certificate, so its requirement is

```
identifier "com.personal.clicky" and anchor apple generic
  and certificate leaf[subject.CN] = "Apple Development: … (9SN623JAY3)" and …
```

That is the same for every build signed with that certificate, so **permissions carry over on
every upgrade**, whether it comes from this script, Homebrew or Theo's own Update button.
(Checked: builds 202611051828, 202611121716 and a fresh build all have the identical
requirement, and `codesign -v -R` confirms each satisfies the others'.)

An ad-hoc signature (`codesign -s -`) would not: its requirement is the build's own hash
(`cdhash H"…"`), so macOS would treat every update as a new app and ask for every permission
again. `Tools/release.sh` refuses to publish a build that isn't signed with the Apple
Development identity.

What a new user sees on first launch:

- Theo opens with no warning dialog, and its Setup guide starts (brain, voice, permissions).
- **Microphone**: a standard macOS "Allow / Don't Allow" box.
- **Accessibility** and **Screen & System Audio Recording**: macOS can't grant these from a
  dialog. It shows a prompt that opens System Settings › Privacy & Security, where the user
  switches Theo on. The entry may be listed as **Clicky** (the bundle's internal name).
  Screen recording takes effect after Theo restarts.
- Recent macOS versions also show a periodic reminder that an app can still record the screen;
  that is a macOS policy for every app and doesn't depend on signing.

After that, upgrades don't prompt again. Uninstalling without `--purge` keeps the permissions,
so a later reinstall doesn't prompt either; `--purge` resets them (`tccutil reset All`).

`Tools/release.sh` refuses to publish a build that doesn't satisfy the installed Theo's
designated requirement (so a changed certificate can't silently reset everyone's permissions),
and writes the build's own signer rule into the release's `SIGNER` file and install.sh. Theo's own updater checks the same thing:
the new app must satisfy the running app's designated requirement.

## When the Apple Development certificate expires or is renewed

The certificate (`Apple Development: … (9SN623JAY3)`, team `9JAQUUW553`) is valid from
24 Oct 2026 to **24 Oct 2027**. Theo builds are signed without a secure timestamp and carry no
provisioning profile.

| Question | Answer | How we know |
|---|---|---|
| Does an installed Theo keep opening after the certificate expires? | Expected yes. macOS only checks certificate dates through Gatekeeper, which doesn't run for apps without the quarantine flag, and Theo has no provisioning profile (the thing that does stop development builds). | A test copy signed with a certificate that expired 4 minutes earlier launched and stayed up. That test used a self-signed certificate; the Apple-issued case can't be tested on the Studio before Oct 2027 without changing the clock. |
| Do builds signed with the renewed certificate keep everyone's permissions? | Yes, as long as the renewed certificate has the same name. Apple names it after the Apple ID and the developer id (`9SN623JAY3`), which don't change on renewal. | Not testable until renewal. `release.sh` now checks it before publishing: a build that doesn't satisfy the installed Theo's requirement is refused, with both requirements printed. |
| Does install.sh's signer check pass with the renewed certificate? | Yes: the published rule pins the team (`9JAQUUW553`), not the certificate. | Same as above; `release.sh` writes the rule from the build itself. |
| Can old releases still be installed after Oct 2027? | Possibly not: without a secure timestamp, `codesign --verify` judges an Apple certificate's dates at the current time (`security verify-cert -d 2027-12-01` reports the certificate expired). Only `--version <old build>` is affected; the latest release will be signed with the renewed certificate. | Signing with `--timestamp` fixes this. Tested: it works with this certificate and keeps the identical designated requirement. Not changed in `release.sh` yet; left as a decision. |

Two things would reset everyone's permissions once: renewing under a different Apple ID or
name, or Apple revoking the certificate (better to let an old one expire than to revoke it in
Xcode). Apple issues Apple Development certificates for development, not for distributing
software to the public, and a free account's certificate has to be renewed every year.

## Signing options

The Apple Development certificate shows the developer's name and Apple ID email
to anyone who runs `codesign -dvv` on a public download, and it ties every build to a yearly
renewal under that Apple ID. A **self-signed code-signing certificate** avoids both while
keeping permissions stable. Tested on the Studio with a throwaway certificate in a scratch
keychain (nothing was added to the login keychain, and real builds weren't re-signed):

- Signed with `codesign --options runtime --preserve-metadata=entitlements,identifier`, Theo
  verifies (`codesign --verify --deep --strict`), launches and stays up (isolated test profile).
- Its designated requirement is `identifier "com.personal.clicky" and certificate leaf = H"<sha1>"`:
  identical for two different builds, and each satisfies the other's, so macOS keeps
  permissions across updates exactly as it does today.
- A new certificate with the same name but a new key does *not* satisfy it, so the private key
  must be backed up; losing it is the one thing that resets permissions.
- `--timestamp` works with it too (Apple's timestamp server doesn't care who issued the
  certificate), and a 20-year validity makes expiry a non-issue.
- install.sh accepts it in the `certificate leaf = H"<sha1>"` form (release.sh writes it from the
  build); the tests confirm it accepts the pinned certificate and refuses both a same-named
  certificate with another key and an Apple Development build.
- Theo's updater now compares designated requirements instead of team ids, so it accepts
  self-signed updates (a self-signed certificate has no team id, so the old team check would
  have refused every one).

| | Apple Development (today) | Self-signed |
|---|---|---|
| Name and email in every download | Yes | No (just the certificate name you choose) |
| Permissions kept across updates | Yes | Yes |
| Renewal | Yearly, through Xcode and the Apple ID | None needed for 20 years |
| What resets permissions | Different name or Apple ID, revocation | Losing the private key |
| Gatekeeper on a browser download | Blocked (not notarized) | Blocked (same) |
| curl / Homebrew install | Works | Works |
| Switching cost | None | existing installs (today, only the developer's own Macs) grant the permissions once more, and update by running the install line once (the installed updater refuses a new signer, by design) |

**Recommendation: switch to self-signed before the first public release.** Today only the developer's own Macs would have to re-grant permissions; after launch, every user would. Steps when the switch is
decides:

```bash
# 1. Create the certificate (20 years) and keep theo-signing.p12 + its password somewhere safe.
openssl req -new -x509 -newkey rsa:2048 -nodes -keyout theo-signing.key -out theo-signing.pem -days 7300 \
  -subj "/CN=Theo Code Signing" -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -inkey theo-signing.key -in theo-signing.pem -name "Theo Code Signing" -out theo-signing.p12
security import theo-signing.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
# 2. Its pin for install.sh:
echo "identifier \"com.personal.clicky\" and certificate leaf = H\"$(openssl x509 -in theo-signing.pem -noout -fingerprint -sha1 | cut -d= -f2 | tr -d : | tr A-F a-f)\""
```

3. In `release.sh`, re-sign the built app with `codesign --force --deep --options runtime
   --timestamp --preserve-metadata=entitlements,identifier -s "Theo Code Signing"` instead of
   requiring the Apple Development authority, and run the first release with
   `CLICKY_ALLOW_NEW_SIGNER=1`. Existing installs then update once with `install.sh --allow-new-signer`.
4. Nothing to change in install.sh: release.sh writes the step-2 rule into the `SIGNER` file and
   the published script (`Tools/install/signer-requirement.sh`).

(Checked: these `openssl` flags work with the LibreSSL that ships with macOS.)

## Signing your own builds

No Apple team is committed. `Config/Theo.xcconfig` (the base of the Xcode project's settings)
leaves `DEVELOPMENT_TEAM` empty and includes `Config/Signing.local.xcconfig` if it exists, which
git ignores. So:

- **Anyone, and CI**, can build: Xcode signs to run locally (or CI builds with signing off). Such
  a build is fine for trying Theo, but macOS asks for its permissions again after each rebuild,
  and `Tools/release.sh` refuses to publish it.
- **To keep permissions across rebuilds and to publish**, set your own team once:
  `Tools/setup-signing.sh` (it finds the team of the Apple Development certificate in your
  keychain; a free Apple ID works) or `Tools/setup-signing.sh <team id>`. It writes
  `Config/Signing.local.xcconfig` (see `Config/Signing.local.xcconfig.example`).
- **The owner's Macs** keep signing exactly as before: `Tools/release.sh` runs
  `Tools/setup-signing.sh` by itself the first time it finds no local team, and that picks up the
  same Apple Development certificate (team `9JAQUUW553`) that was in the project until now. For
  ⌘R builds in Xcode, run `Tools/setup-signing.sh` once.

## Publishing releases

`Tools/release.sh "notes"` builds, checks the signature, zips and publishes to the releases repo
(`THEO_RELEASES_REPO` in `Config/Theo.xcconfig`, or `CLICKY_UPDATES_REPO` for one run). Its files
go to `build/releases/` in the repo (ignored by git; `CLICKY_RELEASE_OUT` moves them). It refuses
a build that is unsigned, ad hoc signed, not signed with an Apple Development identity, or that
doesn't satisfy the installed Theo's designated requirement. The release carries:

| Asset | Used by |
|---|---|
| `Theo-<build>.zip` | everyone (Theo's in-app updater takes the first `.zip`) |
| `SHA256SUMS` | install.sh, the Windows/Linux installers, anyone checking by hand; lists the zip, `SIGNER` and `install.sh` |
| `SIGNER` | install.sh: who signed this build (the strict rule above) |
| `install.sh` | the `curl … \| bash` line; this repo's script with the releases repo and signer written in (`Tools/install/stamp-installer.py`) |

and writes `theo-<build>.rb`, the Homebrew cask for that build, next to the zip.

The one-liner and the Update button work with no token only when the releases repo is
**public**. While it is private, only people with access can install or update (with `gh`'s
sign-in or `THEO_GITHUB_TOKEN`, or a token in Settings › Updates); everyone else is told plainly
that the updates are private. Making a repo public, or moving releases to a new public repo, is
the owner's decision; after it, `Tools/set-releases-repo.sh <owner>/<repo>` points everything at
the new place, and the next build and release carry it.

**A fork** that publishes its own builds: create a releases repo, run
`Tools/set-releases-repo.sh <you>/<repo>` and `Tools/setup-signing.sh`, then `Tools/release.sh`.
Its installs and updates come from its own repo and check its own signer.

### Homebrew tap

Create a public repo `<owner>/homebrew-theo` and put the generated cask in it as
`Casks/theo.rb`; update it after each release. The cask removes the quarantine flag after
Homebrew has verified the checksum (Homebrew quarantines what it downloads), declares
`auto_updates` because Theo updates itself, and has a `zap` stanza for `brew uninstall --zap`.

## Testing the installer

Anywhere (Linux or Mac, no real build; also runs in CI, `.github/workflows/installers.yml`):

```bash
python3 Tools/install/test-install-stand-in.py   # install.sh on a stand-in Mac against a stand-in GitHub
python3 Tools/install/check-release-config.py    # releases repo and signing team each in one place
```

The stand-in Mac is small programs named `codesign`, `ditto`, `plutil` and `osascript` that act
on fake apps, first on `PATH`; the release-reading JavaScript is the script's own, run under Node.
It covers where releases come from, the private-repo message, how the signer rule is chosen, loose
rules, a replaced release, `--allow-new-signer`, the published copy and checksums.

On a Mac, end to end with real builds and signatures:

```bash
CLICKY_RELEASE_DRY_RUN=1 CLICKY_RELEASE_OUT=/tmp/theo-rel Tools/release.sh "test"
Tools/install/test-install.sh /tmp/theo-install-test /tmp/theo-rel/Theo-<build>.zip
```

Everything goes into the scratch folder: the apps, a fake `$HOME` for the uninstall tests, and
a local fake GitHub for the `SHA256SUMS`, token and `curl | bash` paths. The one launch uses
the isolated `--profile test-install`, so the installed Theo, its data and its permissions are
never touched. Test 1 installs the latest real release from GitHub; pass `--no-github` to skip
it.
