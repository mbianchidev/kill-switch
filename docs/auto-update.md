# Auto-update

[Documentation index](README.md) | [Installation](installation.md) |
[Development](development.md)

KillSwitch ships continuously: every push to `main` is published as a GitHub
Release. Both app bundles and standalone installations can download, verify,
install, and restart automatically when **Update automatically** is enabled.

## Using updates

The **Updates** tab shows the running/latest versions and release notes.
**Check for updates** runs manually; checks also run at launch and on the saved
interval. A newer release appears in a banner at the top of the main window.

| Setting or action | Behavior |
| --- | --- |
| Check interval | 1 hour by default; choose 15/30 minutes or 1/3/6/12/24 hours |
| Update automatically | Off by default; downloads, verifies, installs, and restarts when enabled |
| Download & install | Runs the same installation flow manually |
| Show in Finder | Reveals an app installation for manual replacement or removal |
| Uninstall KillSwitch | Removes a standalone install and its CLI/login agent, then quits |

Update preferences persist, including the automatic-install opt-in when
switching from a standalone install to the app.

**Homebrew installs:** prefer the
[Homebrew upgrade commands](installation.md#updates) and leave **Update
automatically** off. The in-app updater can replace the app, but does not update
Homebrew's installed-version record.

**App installs:** the bundled helper stages and replaces the entire verified
app and confirms startup. The app and its parent folder must be writable; do
not update a copy running from the read-only DMG. Existing CLI symlinks and
login-item paths stay valid. Failed launches roll back and pause automatic
installation of that version, with a visible error and manual retry.

**Standalone installs:** the updater verifies the binary, replaces the path
launched by the LaunchAgent, refreshes `~/bin/killswitchctl`, reloads the agent,
and relaunches. Re-running the installer can also upgrade an older installation.

Manual replacement with the
[latest DMG](https://github.com/mbianchidev/kill-switch/releases/latest/download/KillSwitch.dmg)
remains available. Quit before replacing it, and follow the
[trusted-app opening guidance](troubleshooting.md#opening-the-downloaded-app) if
macOS blocks the manually downloaded copy. Verified automatic updates handle
quarantine on their staged bundle without altering its signature.

Details are logged to `~/Library/Logs/killswitch-update.log`. The following
sections document versioning, packaging, validation, startup confirmation, and
recovery rather than additional user configuration.

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
3. Run `bash scripts/package-macos.sh --universal-build` with
   `KILLSWITCH_VERSION` set to the computed version. SwiftPM's SwiftBuild
   backend builds `arm64` and `x86_64` together in one build graph per product,
   with its worker count set to the runner's logical CPU count. Packaging
   verifies both architectures and ad-hoc signs the standalone executable,
   bundled update helper, and native app bundle.
4. Package five assets: `KillSwitch.dmg`, `KillSwitch.dmg.sha256`, `KillSwitch`,
   `KillSwitch.tar.gz`, and `KillSwitch.sha256`. The DMG contains
   `KillSwitch.app`, an Applications shortcut, and installation instructions.
5. Run `bash scripts/check-macos-package.sh` to verify both architectures,
   bundle metadata, icon, signatures, checksums, update helper, and headless CLI dispatch
   without starting the GUI or installing anything.
6. `gh release create` publishes the release with all five assets attached and
   the latest commit message as the release notes.

`.github/workflows/ci.yml` also builds and verifies the universal DMG on every
PR and push to `main` using the same `--universal-build` path, and uploads it as
the **KillSwitch-macOS** artifact. This changes build scheduling, not the five
release assets, archive formats, signing, checksums, or verification steps.

The bundle uses the stable identifier `io.killswitch.app`, requires macOS 13+,
and includes an original AppKit-rendered monogram icon. It is
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

App bundles select `KillSwitch.dmg` and `KillSwitch.dmg.sha256`. The opt-in
**Update automatically** setting uses the same saved preference as standalone
installations. **Download & install** runs the same flow manually:

1. Download the DMG and verify its published SHA-256, failing closed for missing
   or mismatched checksums.
2. Mount it read-only without opening Finder. Validate the app's bundle identity,
   release version, executable, native architecture, and complete code signature.
3. Copy the entire app to a private sibling directory on the installation volume.
   Verify the staged signature, then remove its quarantine attribute. Unmount the
   image before proceeding.
4. Launch a verified copy of the bundled `KillSwitchUpdateHelper` and wait for
   its readiness acknowledgement. Only then quit the running GUI normally, saving
   preferences and releasing keep-awake resources.
5. The helper waits for the old process to exit, revalidates both bundles, and
   atomically exchanges the new and old app directories. It starts the new
   bundle's executable with a fresh startup token and private receipt location,
   retaining its exact process handle.
6. The GUI acknowledges only after its application delegate and root view
   finish startup. The helper verifies the acknowledgement's token, process ID,
   bundle path, and version, and briefly monitors the live process. Only then
   does it record success and remove the backup. Startup confirmation has a
   30-second deadline.

A launch failure, early crash, invalid acknowledgement, or startup timeout stops
the replacement before swapping the previous app back and attempting to reopen
it. An unresponsive replacement is terminated using its exact owned process
handle, with a bounded SIGKILL fallback. If it cannot be stopped, neither rollback
nor reopening the old app is attempted; the backup is preserved. A failed
rollback also preserves the backup and logs its path instead of deleting it. Helper
errors are recorded in
`~/Library/Application Support/KillSwitch/LastUpdate.json` and the update log;
the relaunched app shows the error. Automatic installation pauses for that failed
version to prevent restart loops, but **Download & install** retries explicitly,
and newer versions can still install automatically. An unreadable result file
also pauses automatic installation with a visible error rather than ignoring it.
Concurrent helpers use an exclusive lock in the same application-support folder.

Executable architectures are read through Foundation's
`Bundle.executableArchitectures`; no Xcode or Command Line Tools are required at
runtime. Signing verification and disk-image operations use tools included with
macOS itself.

The app and its parent directory must be writable by the current account.
Read-only disk-image copies and protected/root-owned installations are rejected
with instructions to reinstall in a writable location, such as `~/Applications`.
The updater does not elevate privileges, prompt for an administrator password,
replace only a signed app's executable, or create a `~/bin/KillSwitch` copy.
Existing CLI symlinks and login items keep pointing to the same installed path.

For the initial manually downloaded copy, follow the
[trusted-app opening and legacy app-specific quarantine guidance](troubleshooting.md#opening-the-downloaded-app).
Verified automatic updates remove quarantine from their staged bundle themselves.

App startup is managed through macOS **System Settings > General > Login Items**
(**Login Items & Extensions** on newer versions), not the legacy LaunchAgent.
Follow the [uninstall guide](installation.md#uninstall) to remove the app, login
item, and optional CLI symlink while retaining preferences.

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
  over the binary the LaunchAgent actually launches, read from the agent plist's
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

`UpdateChecker.swift` orchestrates checks, preferences, and downloads.
`AppBundleUpdater.swift` handles disk-image mounting and the helper handoff;
`InstallCore/AppBundleUpdate.swift` handles validation, atomic replacement,
rollback, and update results. `InstallCore/AppBundleStartup.swift` handles
startup acknowledgements and supervised relaunch. `KillSwitchUpdateHelper` waits
for process exit and relaunches without keeping the old GUI running alongside
the new one. `AppStartupConfirmation.swift` joins the delegate and root-view
startup signals before acknowledging the replacement.
