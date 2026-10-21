# Auto-update

KillSwitch ships continuously: every push to `main` is published as a GitHub
Release. The running app detects new builds; app bundles offer a DMG download,
while standalone installations can install updates in place.

## Versioning

Releases use auto-incrementing **semver** (`vMAJOR.MINOR.PATCH`):

- Every push to `main` bumps the **patch** of the latest published release
  (e.g. `v1.1.0` → `v1.1.1` → `v1.1.2`).
- To cut a **minor or major** release, publish that tag manually (e.g. create
  `v1.2.0` on GitHub). The next push to `main` continues patching from it
  (`v1.2.1`, `v1.2.2`, …).
- If no release exists yet, the first auto-release is `v0.0.1`.

The version is computed by reading the latest release via `gh release view`, so
it's monotonic. Runs are serialized (`concurrency`) so two pushes can't compute
the same patch. The same string is embedded into the binary at build time (see
below). Versions are compared component-wise as integers, ignoring a leading `v`.

## Release automation

`.github/workflows/release.yml` runs on push to `main` (on `macos-latest`):

1. Compute the next version by bumping the patch of the latest release
   (`gh release view`), e.g. `v1.1.0` → `v1.1.1`.
2. Overwrite `Sources/KillSwitch/Version.swift` with the computed version.
3. Run `bash scripts/package-macos.sh` with `KILLSWITCH_VERSION` set to the
   computed version. It builds for `arm64` and `x86_64`, combines them with
   `lipo`, and ad-hoc signs both the standalone executable and native app bundle.
4. Package five assets: `KillSwitch.dmg`, `KillSwitch.dmg.sha256`, `KillSwitch`,
   `KillSwitch.tar.gz`, and `KillSwitch.sha256`. The DMG contains
   `KillSwitch.app`, an Applications shortcut, and installation instructions.
5. Run `bash scripts/check-macos-package.sh` to verify both architectures,
   bundle metadata, icon, signatures, checksums, and headless CLI dispatch
   without starting the GUI or installing anything.
6. `gh release create` publishes the release with all five assets attached and
   the latest commit message as the release notes.

`.github/workflows/ci.yml` also builds and verifies the universal DMG on every
PR and push to `main`, and uploads it as the **KillSwitch-macOS** artifact.

The bundle uses the stable identifier `io.killswitch.app`, requires macOS 13+,
and includes an AppKit-rendered icon matching the menu bar's bolt symbol. It is
not sandboxed, Developer ID signed, or notarized. Ad-hoc signing allows local
execution but does not establish an Apple-verified publisher identity.

## Embedded version

`Sources/KillSwitch/Version.swift` exposes `AppVersion.current`. It is committed
with the fallback value `"dev"`, so a local `swift build` always works. Bundled
apps read their version from the `KillSwitchVersion` Info.plist key; the same
release version, without its leading `v`, is written to
`CFBundleShortVersionString` and `CFBundleVersion`. The release workflow also
rewrites the fallback before building, so standalone binaries report the
published version. A `dev` build parses to `0` and
therefore treats any published release as an update.

For a locally labeled app, use
`KILLSWITCH_VERSION=v1.2.3 bash scripts/package-macos.sh`. Without this variable,
the app reports `dev` and its numeric bundle version is `0.0.0`.

## In-app updates

`Sources/KillSwitch/UpdateChecker.swift` (`UpdateChecker.shared`) drives the flow:

### App bundles

App bundles select the `KillSwitch.dmg` release asset. **Download DMG** opens the
download in the default browser. Quit KillSwitch using its menu bar menu, then
drag the new app into Applications and replace the old one. Automatic checks
and release notes remain available, but automatic installation is disabled for
bundles, even when an old standalone installation had it enabled.

The legacy installer and uninstaller are explicitly blocked in app bundles,
including when launched from a read-only DMG. Replacing only a signed app's
executable would invalidate its signature, and updating `~/bin/KillSwitch`
would silently update the wrong copy.

If macOS blocks the downloaded app, copy it to Applications first, quit it,
then run:

```bash
xattr -dr com.apple.quarantine /Applications/KillSwitch.app
```

Only do this for a download you trust. It removes this app's quarantine flag,
not Gatekeeper protection system-wide; it does not sign or notarize the app.
The DMG's SHA-256 is published separately as `KillSwitch.dmg.sha256`.

App startup is managed through macOS **System Settings > General > Login Items**
(**Login Items & Extensions** on newer versions), not the legacy LaunchAgent.
Uninstall by quitting, removing the login item, and moving the app to Trash.
Remove the optional `~/bin/killswitchctl` symlink if you created one.

Bundled GUI preferences fall back to the existing `KillSwitch` defaults domain,
so switching from the standalone install retains saved settings. Dev cleanup
preferences and integration ports continue using that shared domain directly,
including when invoked through the app's optional CLI symlink.

### Standalone/script installations

- **Check** queries
  `https://api.github.com/repos/mbianchidev/kill-switch/releases/latest`,
  parses the latest tag and the `KillSwitch` asset URL, and compares versions.
  Runs on launch and then on a user-configurable interval (**default every
  hour**, selectable 15m–24h and persisted to `UserDefaults`); a manual trigger
  lives in the **Updates** tab. Network/JSON errors are caught and surfaced,
  never crashing the app.
- **Notify:** when a newer version exists, a banner appears at the top of the
  window and the Updates tab shows the release notes and an install button.
- **Auto-update:** an opt-in **Update automatically** toggle (persisted) makes
  the app install an available release the moment it's detected, so the user
  always lands on the latest version with no action required.
- **Install:** downloads the new binary, validates it is a non-trivial Mach-O
  executable, and verifies its SHA-256 against the release's `KillSwitch.sha256`
  asset (failing closed if the checksum is missing or mismatched), then copies it
  over the binary the LaunchAgent actually launches — read from the agent plist's
  `ProgramArguments` (falling back to `~/bin/KillSwitch`). Targeting the agent's
  own launch path guarantees the relaunched binary is the one we just wrote, so
  the install and relaunch can never disagree (the cause of the pre-1.1.2 update
  loop). It then refreshes `~/bin/killswitchctl` as a symlink to that same binary,
  fixes permissions, reloads the LaunchAgent, and relaunches. The install path
  lives in the user's home directory, so no admin password is required. Temp
  files are cleaned up and failures are reported clearly.

The updater refuses to replace a real directory at the configured KillSwitch
binary path, and it only replaces or removes `~/bin/killswitchctl` when that path
is a symlink. Existing binary files and symlinks can be replaced safely; real
directories at the binary path and all non-symlinks at the CLI path are preserved
with a clear error.

The command-line alias is intentionally not a second release artifact. Both the
bundled and standalone `KillSwitch` executables select headless mode only when
their invocation basename is `killswitchctl`.

Update activity is logged to `~/Library/Logs/killswitch-update.log`.

### Entry point for other UI

The menu bar / tray can offer "Check for Updates…" by calling:

```swift
UpdateChecker.shared.checkForUpdates()
```

All update logic is self-contained in `UpdateChecker.swift` to keep the
`AppDelegate` thin.
