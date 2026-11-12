# Installing Theo from Terminal

Theo installs the way OpenClaw and Hermes do: one line in Terminal, no paid Apple
Developer account, no notarization.

```bash
curl -fsSL https://github.com/adhyanmahajan26-boop/claudia-releases/releases/latest/download/install.sh | bash
```

Run the same line again to upgrade. To remove Theo:

```bash
curl -fsSL https://github.com/adhyanmahajan26-boop/claudia-releases/releases/latest/download/install.sh | bash -s -- --uninstall
```

`--uninstall` keeps chats, bots and settings; `--uninstall --purge` also moves them to the
Trash and removes Theo's saved keys and macOS permissions (it asks first). Other options:
`--version <build>`, `--dir <folder>`, `--no-launch`, `--force`, `--from <zip> --sha256 <hex>`;
`--help` lists them.

With Homebrew, once the tap repo exists (see below):

```bash
brew install --cask adhyanmahajan26-boop/theo/theo
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
3. It must be Theo (bundle id `com.personal.clicky`) and signed by Theo's team (`9JAQUUW553`,
   pinned in the script).

The checksum guards against a broken or swapped download; the pinned team guards against a
release asset that was replaced with something else, since only Theo's signing key can produce
that team id.

The install itself is copy-then-rename beside the destination, so a failure never leaves a
half-replaced app; on an upgrade the running Theo is asked to quit (SIGTERM, the same way the
test suites stop it) and is reopened afterwards. `/Applications` is used when it's writable
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

The certificate is valid until October 2027. Renewing it in Xcode keeps the same name, so the
requirement (and everyone's permissions) stay valid. Note that the certificate shows the
developer's name and Apple ID email to anyone who inspects the app's signature.

## Publishing a release

`Tools/release.sh "notes"` builds, signs, zips and publishes. The release carries:

| Asset | Used by |
|---|---|
| `Theo-<build>.zip` | everyone (Theo's in-app updater takes the first `.zip`) |
| `SHA256SUMS` | install.sh, the Windows/Linux installers, anyone checking by hand |
| `install.sh` | the `curl … \| bash` line (`releases/latest/download/install.sh`) |

and writes `theo-<build>.rb`, the Homebrew cask for that build, next to the zip.

The one-liner only works without a token when the releases repo is **public**. While it is
private, the script uses `gh`'s sign-in or `THEO_GITHUB_TOKEN` (fine for Addy's own Macs, not
for anyone else).

### Homebrew tap

Create a public repo `adhyanmahajan26-boop/homebrew-theo` and put the generated cask in it as
`Casks/theo.rb`; update it after each release. The cask removes the quarantine flag after
Homebrew has verified the checksum (Homebrew quarantines what it downloads), declares
`auto_updates` because Theo updates itself, and has a `zap` stanza for `brew uninstall --zap`.

## Testing the installer

```bash
CLICKY_RELEASE_DRY_RUN=1 CLICKY_RELEASE_OUT=/tmp/theo-rel Tools/release.sh "test"
Tools/install/test-install.sh /tmp/theo-install-test /tmp/theo-rel/Theo-<build>.zip
```

Everything goes into the scratch folder: the apps, a fake `$HOME` for the uninstall tests, and
a local fake GitHub for the `SHA256SUMS`, token and `curl | bash` paths. The one launch uses
the isolated `--profile test-install`, so the installed Theo, its data and its permissions are
never touched. Test 1 installs the latest real release from GitHub; pass `--no-github` to skip
it.
