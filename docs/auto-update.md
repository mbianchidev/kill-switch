# Auto-update

KillSwitch ships continuously: every push to `main` is published as a GitHub
Release, and the running app can detect, download, and install the latest build.

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
3. `swift build -c release`.
4. Package the binary (`KillSwitch`) and a `KillSwitch.tar.gz`, and write a
   `KillSwitch.sha256` containing the binary's SHA-256 digest.
5. `gh release create` publishes the release with all three assets attached and
   the latest commit message as the release notes.

`.github/workflows/ci.yml` is unchanged and still builds every PR and push.

## Embedded version

`Sources/KillSwitch/Version.swift` exposes `AppVersion.current`. It is committed
with the fallback value `"dev"`, so a local `swift build` always works. The
release workflow rewrites this file with the real version before building, so
released binaries report their true version. A `dev` build parses to `0` and
therefore treats any published release as an update.

## In-app updates

`Sources/KillSwitch/UpdateChecker.swift` (`UpdateChecker.shared`) drives the flow:

- **Check** — queries
  `https://api.github.com/repos/mbianchidev/kill-switch/releases/latest`,
  parses the latest tag and the `KillSwitch` asset URL, and compares versions.
  Runs on launch and then on a user-configurable interval (**default every
  hour**, selectable 15m–24h and persisted to `UserDefaults`); a manual trigger
  lives in the **Updates** tab. Network/JSON errors are caught and surfaced,
  never crashing the app.
- **Notify** — when a newer version exists, a banner appears at the top of the
  window and the Updates tab shows the release notes and an install button.
- **Auto-update** — an opt-in **Update automatically** toggle (persisted) makes
  the app install an available release the moment it's detected, so the user
  always lands on the latest version with no action required.
- **Install** — downloads the new binary, validates it is a non-trivial Mach-O
  executable, and verifies its SHA-256 against the release's `KillSwitch.sha256`
  asset (failing closed if the checksum is missing or mismatched), then copies it
  over the binary the LaunchAgent actually launches — read from the agent plist's
  `ProgramArguments` (falling back to `~/bin/KillSwitch`). Targeting the agent's
  own launch path guarantees the relaunched binary is the one we just wrote, so
  the install and relaunch can never disagree (the cause of the pre-1.1.2 update
  loop). It then fixes permissions, reloads the LaunchAgent, and relaunches. The
  install path lives in the user's home directory, so no admin password is
  required. Temp files are cleaned up and failures are reported clearly.

Update activity is logged to `~/Library/Logs/killswitch-update.log`.

### Entry point for other UI

The menu bar / tray can offer "Check for Updates…" by calling:

```swift
UpdateChecker.shared.checkForUpdates()
```

All update logic is self-contained in `UpdateChecker.swift` to keep the
`AppDelegate` thin.
