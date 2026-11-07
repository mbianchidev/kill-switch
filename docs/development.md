# Development and implementation

[Documentation index](README.md) | [Contributing](../CONTRIBUTING.md) |
[Agent instructions](../AGENTS.md)

This is the source-setup and implementation reference. User-facing settings and
safety rules live in [Usage and configuration](usage.md); release internals live
in [Auto-update](auto-update.md).

## Build and run without installing

Use macOS 13+, Git, Swift 5.9+, and Xcode Command Line Tools or Xcode. There are
no third-party Swift package dependencies or service credentials to configure.

```bash
git clone https://github.com/mbianchidev/kill-switch.git
cd kill-switch
swift build -c release --product KillSwitch
.build/release/KillSwitch
```

The last command launches the GUI without creating a login item. Expect the
activity dashboard and menu-bar icon. Local builds report `dev`, so the updater
considers any published release newer. Do not enable automatic updates if you
want to keep running your local development build.

Headless calls require a `killswitchctl` symlink; arguments passed directly to
a binary named `KillSwitch` do not select CLI mode. See [CLI setup](cli.md#setup).
Do not open Dev cleanup or invoke `cleanup` as a build smoke test: it can
terminate real processes.

## Tech stack

- **Swift 5.9+ and Swift Package Manager:** the package targets macOS 13+.
- **SwiftUI and Swift Charts:** native application views and live resource graphs.
- **AppKit:** `NSWorkspace` supplies application icons; `NSStatusItem` implements
  the menu-bar status item and menu.
- **CoreGraphics and workspace notifications:** idle-input timing, plus
  `NSWorkspace` sleep, display, and session notifications, drive screen-time
  tracking without recording app, website, or input histories.
- **Native process and resource APIs:** `libproc`, Mach CPU/VM statistics, and
  IOKit provide low-overhead CPU, memory, disk, and power data. `top`, `nettop`,
  `netstat`, and `pmset` run only for metrics that require them. See
  [resource data sources and restrictions](system-diagnostics.md#resources).
- **`osascript`:** native notifications and administrator-authorized diagnostics.
- **SQLite:** macOS's built-in `sqlite3` library stores private, bounded activity
  history through the `CSQLite` system-library target, without a package download.
- **Process inspection and startup:** NUL-delimited `lsof` data, launchd
  overrides, System Events legacy login items, macOS background-item inventory,
  and confirmed crontab edits. System-wide changes require authorization.
- **`URLSession` with async/await and the GitHub Releases API:** release checks
  and in-app update downloads.
- **Built-in macOS packaging tools:** native `.app` and DMG creation, without
  third-party packaging dependencies. The universal app includes the universal
  `KillSwitchUpdateHelper` for whole-app replacement and relaunch.
- **Startup integration:** macOS Login Items for app installations; a LaunchAgent
  for standalone installations.
- **GitHub Actions and CodeQL:** continuous releases from pushes to `main`, plus
  advanced CodeQL setup with a manual Swift build. See
  [release automation](auto-update.md#release-automation) and
  [CI and security scanning](ci-security.md).

## Shared core targets

| Target | Responsibility |
| --- | --- |
| [`TableQueryCore`](../Sources/TableQueryCore) | Typed text/numeric/date/boolean filters, unit parsing, quoted search, and bidirectional comparators shared by all data tables |
| [`DevCleanupCore`](../Sources/DevCleanupCore) | Preferences, integration-port merging, CLI parsing, cleanup classification, and shared termination protection |
| [`DiskCleanupCore`](../Sources/DiskCleanupCore) | File scanning, cleanup candidates, protected-path checks, and Trash operations |
| [`KeepAwakeCore`](../Sources/KeepAwakeCore) | IOKit power assertions, timed sessions, and resource cleanup |
| [`InstallCore`](../Sources/InstallCore) | Binary/symlink path safety, native command execution, whole-app validation, staging, startup confirmation, and rollback |
| [`ScreenTimeCore`](../Sources/ScreenTimeCore) | Active-time tracking, idle breaks, daily rollover, and reminder boundaries |
| [`SystemMetricsCore`](../Sources/SystemMetricsCore) | Resource/system-health parsing, continuous sampling policy, PID-safe history/rates and inspection, bounded project discovery, and private SQLite storage |
| [`StartupCore`](../Sources/StartupCore) | Startup inventory, protected-service policy, command planning, reversible cron/login changes, and backups |

[`KillSwitch`](../Sources/KillSwitch) contains the GUI and basename-dispatched
headless CLI. [`KillSwitchUpdateHelper`](../Sources/KillSwitchUpdateHelper)
performs supervised app replacement. Test executables live in [`Tests`](../Tests).

The GUI delegates shared classification, persistence, and safety decisions to
the core targets. CLI dispatch happens in `Sources/KillSwitch/main.swift` before
SwiftUI starts; GUI and CLI cleanup use the same core configuration and service.
The updater delegates unprivileged bundle replacement and startup supervision
to `InstallCore` and the bundled helper.

When extending behavior, add reusable rules to the corresponding core target
and mock-based checks rather than duplicating them in a view or CLI handler.
Preserve ownership checks, Porto hostagent protection, and installer path safety.

<a id="ui-and-menu-bar"></a>
<a id="developer-cleanup-defaults"></a>

User behavior moved to the [menu-bar guide](usage.md#menu-bar-tray) and
[developer-cleanup defaults](usage.md#developer-cleanup-defaults), which are the
authoritative references for UI actions, runtime/protection lists, and saved
configuration. The [CLI guide](cli.md) covers integration-owned port syncing.

## Watchdog model

The native watchdog mirrors the consecutive-check approach of the
`cpu-watchdog.sh` / `cpu-hog-monitor.sh` scripts referenced in its
[source comments](../Sources/KillSwitch/CPUWatchdog.swift). Those shell scripts
are not distributed or required by this repository.

The first check runs when monitoring starts; subsequent checks follow the
selected interval. The default three observations at five-minute intervals are
sampled evidence, not a measurement of exactly 15 minutes of continuous load.
After an alert, the process counter resets and can alert again after the same
number of further consecutive sightings. See the
[watchdog guide](usage.md#cpu-watchdog) for controls, recent alerts,
kill buttons, and the bounded log.

## Run checks

The regression targets are executable checks, not an XCTest suite. Run the same
core checks as [CI](../.github/workflows/ci.yml):

```bash
swift run DevCleanupCoreChecks
swift run DiskCleanupCoreChecks
swift run InstallCoreChecks
swift run SystemMetricsChecks
swift run ScreenTimeCoreChecks
swift run StartupCoreChecks
```

Use the smallest relevant target while iterating. Tests use synthetic processes,
temporary files, and mock dependencies. Install checks use signed mock bundles
for identity/version/signature rejection, path safety, quarantine handling,
permissions, replacement/rollback, and startup-loop prevention.
System-metric checks also open synthetic files, hold/probe a POSIX lock, and
create a loopback listener to verify real `lsof` output. Lock fields are compared
with the installed collector's complete output because macOS can omit them.
Startup checks use mock command runners, temporary files, and a private fake
crontab executable to exercise staging, hashes, installation, and cleanup.
Isolated launch-directory fixtures cover updater placeholders, configuration
plists, read-only links, duplicate labels per domain, and source revalidation.
They never change live startup entries, request administrator access, or control
a desktop application.

For table-query changes, `swift run SystemMetricsChecks --table-query-checks`
runs only the shared query, measurement-availability, and activity-field checks.
The full command also covers inspection filtering and ownership scope. Startup, disk-cleanup, and
dev-cleanup checks verify their own field definitions without running live
operations. Numeric sort keys are projected once per row; views reuse each
filtered snapshot rather than sorting again for every cell.
The energy cache keys both power and verified sleep-assertion states by process
lifetime. An empty successful assertion inventory records No only for the
identities observed in that read; missing or failed reads remain unknown.
Mode changes clear current readings without clearing unresolved collector errors;
every sampling tick republishes those errors until the relevant reader succeeds.

For memory regressions, run `swift run SystemMetricsChecks --memory-stress`.
This adds two simulated hours of 5,000 synthetic processes, checks that all
processes remain in the bounded live history and minute averages, and enforces a
256 MiB peak-resident-memory budget for the checks process, not the full GUI.

`ResourceMonitor.shared` owns the app-lifetime sampler; dashboard and resource
views observe the same snapshots and history selection. The page container keeps
model lifetimes stable without observing their updates; only the relevant leaf
views subscribe, so a resource tick does not rebuild navigation. A native
`NSTabViewController` without a tab strip lazily creates visited
`NSHostingController` pages and retains their SwiftUI filter/sort state.
Metric requests carry page-specific leases, so an outgoing page cannot clear a
newer selection. Actual window visibility gates heavier collection while
continuous CPU, memory, disk, and traffic sampling remains unchanged.
The native
history-process menu creates its choices on opening and releases them after
closing instead of maintaining a SwiftUI view for every recorded process.
Its shortcut delegate bypasses populating choices during closed-menu key checks.
`ActivityProcessCatalog` reconciles samples with explicit per-PID lifetime
evidence before live coalescing or minute aggregation, so neither can hide a
short-lived process while its measurements await storage. Missing measurements
or descriptors do not prove an exit. A matching lifetime, verified absence,
defunct state, or replacement identity resolves a restored record; unavailable
reads preserve unresolved lifetimes for later retries. Confirmed exits keep
their original deadline, dating verified downtime exits from the last saved
sighting. Exited descriptors expire after six hours or when their last sighting
is more than 24 hours old, and delayed writes exclude expired processes. SQLite
persists exit deadlines alongside descriptors; process metadata and measurements
are pruned together in a transaction. Defunct states are excluded by both PS
parsing and the native lifetime reader; sleeping and stopped processes remain
live. Whole-Mac and running-process history still use the 24-hour window.
Pruning-only ticks persist pending termination records without rewriting the
live inventory. Successful pruning acknowledges only those saved records;
dirty live metadata stays pending for the next minute save, and failed pruning
preserves pending changes for retry. Minute saves persist all pending process
metadata, including lifetimes absent from the completed measurement bucket.
Queued minute saves reuse one snapshot of the latest pending metadata throughout
the drain and acknowledge it only after every queued save succeeds. A later
failure leaves that metadata pending for retry, preventing older bucket
descriptors from overwriting the current process name or user during recovery.
Sample-derived metadata updates skip already-terminated rows, so delayed
buckets cannot overwrite finalized names, owners, or last-sighting times after
pruning acknowledges an exit. Historical measurements are still saved;
authoritative lifecycle records remain responsible for metadata changes.
`OpenFilesTab` subscribes only to shared process-scope changes; resource ticks
do not rerun its file filtering and sorting.
Sampling and inspection queues drain autoreleased objects after each work item.
Six-second samples remain in memory for five minutes, bounded to 51 snapshots
by `ActivityLiveHistory`; extra refreshes replace their current six-second slot.
`ActivityAccumulator` still receives every measurement and writes minute
averages on rollover and normal termination. Store operations stay on the
sampling queue. `ActivityProcessIdentity` includes boot identity and process
start time to avoid merging reused PIDs. Failed/restricted measurements remain
optional and do not become zeroes. See
[history storage](system-diagnostics.md#history-and-storage) and
[startup management](startup.md) for user-facing behavior and persistence.

There is no separate formatter or linter configuration. Match the existing
Swift style and keep failure messages actionable. Add regression checks in the
existing executable target for the subsystem you change.

`SystemHealthMonitor` is shared by Dashboard and the three health pages.
Visible clients lease one thirty-second timer; no health history is accumulated.
Hardware information is loaded off the main thread and retained once available.
Inspection uses one serial work queue per visible panel, verifies process
lifetimes around collection, rejects stale activation results, and releases
row snapshots/project caches on hiding. The per-process sheet selects only its
verified PID and shares one files/connections read. Developer listeners cache
native working-directory/Git context by lifetime for at most thirty seconds,
walk at most twelve ancestors, and read at most 4 KiB per metadata file without
following a metadata-file symlink or running git.

### Measure isolated UI footprint

Build a separate release probe; the compile-time entry point is absent from
normal app and package builds:

```bash
swift build -c release --scratch-path .build/performance \
  -Xswiftc -DKILLSWITCH_PERFORMANCE_PROBE --product KillSwitch
PROBE="$(swift build -c release --scratch-path .build/performance \
  -Xswiftc -DKILLSWITCH_PERFORMANCE_PROBE --show-bin-path)/KillSwitch"
swift scripts/measure-footprint.swift "$PROBE" .build/footprint.json \
  30 3 1000 "$(git rev-parse HEAD)"
```

This runs five scenarios with synthetic process rows and 51 six-second history
samples. The dashboard includes the navigation shell; CPU, Memory, and Energy
render their resource views directly. AppKit renders offscreen without opening,
activating, or controlling a desktop window. No real collectors, user history,
cleanup, updates, startup changes, or privileged diagnostics run.

The external harness reads kernel CPU time, resident memory, and physical
footprint every 100 ms. CPU uses one-core normalization: 100% is one logical
CPU core, not the whole machine. It excludes the first two seconds for average
and p95 CPU, and reports median memory from the final third of the run.
Peak RSS includes `wait4`'s maximum; peak physical footprint is an observed
peak, not the lifetime kernel peak. `wait4` CPU includes waited child processes;
the synthetic scenarios launch none.

The probe also accepts `system`, `battery`, `thermal`, `connections`, `files`,
`servers`, `inspector`, and `navigation`. Append a comma-separated scenario list
after the revision in the measurement command to select them. Inspection
scenarios use 1,000 synthetic file/listener records; `PROCESSES` controls resource
rows. Navigation cycles through ten safe pages without entering Dev cleanup.
Run the deterministic native-state checks directly:

```bash
"$PROBE" --interface-checks
"$PROBE" dashboard 3 1000 .build/dashboard.png 900x650
```

The optional PNG is the probe's own unshown window, never a desktop capture.
`--native-health-check` separately verifies public native health interfaces
without identifiers, UI interaction, or privileged diagnostics; it is not a
synthetic measurement scenario.

Retain reports outside Git and compare identical durations, counts, hardware,
OS, toolchain, and build settings over multiple runs. These probes complement
`SystemMetricsChecks --memory-stress`; they do not measure interactive
VoiceOver behavior, live-collector overhead, a full 24-hour database, or
extended-run growth. They are not the controlled-environment recurring
performance baseline requested in [#37](https://github.com/mbianchidev/kill-switch/issues/37).

## Build and verify the app and DMG

Run on macOS from the checkout:

```bash
bash scripts/package-macos.sh
bash scripts/check-macos-package.sh
```

The packaging script builds Apple Silicon (`arm64`) and Intel (`x86_64`)
executables, combines them, creates the native app with its icon and metadata,
and ad-hoc signs the app, standalone executable, and update helper. It writes:

```text
dist/KillSwitch.dmg
dist/KillSwitch.dmg.sha256
dist/KillSwitch
dist/KillSwitch.sha256
dist/KillSwitch.tar.gz
```

CI and releases use `bash scripts/package-macos.sh --universal-build` to build
both architectures together in one SwiftPM build graph per product, with the
worker count set to the logical CPU count. This mode explicitly selects the
SwiftBuild backend and requires a SwiftBuild-capable toolchain (Swift 6.3+).
The default command above retains sequential architecture builds for older
Swift and Command Line Tools compatibility. Both paths produce and verify the
same asset formats and supported architectures.

The DMG contains `KillSwitch.app`, an Applications shortcut, and installation
instructions. Local app bundles default to `dev` (`0.0.0`). To label a local
app bundle, use the supported environment variable:

```bash
KILLSWITCH_VERSION=v1.2.3 bash scripts/package-macos.sh
```

This is an illustrative local version, not a publishing command. The release
workflow separately embeds the published fallback version for the standalone
binary. These builds are **not Developer ID signed or Apple-notarized**.
Packaging uses built-in macOS tools and no third-party packaging dependencies.

The package check mounts the DMG read-only without opening Finder, checks bundle
metadata, icon, signatures, architectures, checksums, the standalone tarball,
and headless CLI dispatch, then ejects it. It also checks a disposable copied
app and the helper's argument handling. It does not launch the GUI, install a
login item, update the live app, or run process cleanup.

Local packaging and verification do not publish anything. The
[existing release workflow](auto-update.md#release-automation) handles versioning
and GitHub publication from `main`; do not push a tag or run publication as a
test.

## Standalone source installation

From a checkout with Swift available, `install.sh` builds locally by default.
To explicitly select source mode, run `KILLSWITCH_INSTALL_MODE=source bash install.sh`.
The original executable-script recipe is also supported:

```bash
chmod +x install.sh uninstall.sh
./install.sh
```

This installs and **immediately launches the GUI**, then enables startup at
login. It is not a headless smoke test. The installer:

1. Builds the release binary, or downloads it in release mode.
2. Installs it at `~/bin/KillSwitch` without `sudo`.
3. Links `~/bin/killswitchctl` to the same binary.
4. Writes and loads the login LaunchAgent.

Force a mode with `KILLSWITCH_INSTALL_MODE=source` or
`KILLSWITCH_INSTALL_MODE=release`. The [installation guide](installation.md#standalone-binary-and-cli)
describes checksum verification, `PATH`, and protection of existing directories
and non-symlink CLI paths.

To pull/rebase the current checkout branch, rebuild, replace the standalone
binary, and reload the LaunchAgent:

```bash
./update.sh
```

The equivalent `bash update.sh` invocation is supported.

### Compatible SDK override

If preview Command Line Tools cannot load `SwiftUIMacros`,
[troubleshooting](troubleshooting.md#source-build-reports-a-missing-swiftuimacros-plugin)
explains how to export a compatible installed `SDKROOT` for build/check commands.
To scope the override to a single packaging command instead, the original recipe remains
available when the macOS 26.5 SDK is installed:

```bash
SDKROOT="$(xcrun --sdk macosx26.5 --show-sdk-path)" bash scripts/package-macos.sh
```

Neither form changes the global toolchain selection.

## Debugging and manual checks

Resource and cleanup failures surface in the UI or stderr; native controllers
also use macOS logging. Watchdog and update logs are listed in
[usage](usage.md#cpu-watchdog) and [update recovery](auto-update.md#app-bundles).
Inspect logs for private paths and command lines before sharing.

Reproduce process/file behavior with mock inputs or a disposable account.
Do not run installers, live cleanup, privileged diagnostics, or destructive
buttons on a normal workstation as a validation shortcut. For UI changes,
follow the [manual accessibility checklist](../ACCESSIBILITY.md#verification);
core/package checks do not establish VoiceOver or keyboard coverage.

## Further implementation details

- [Auto-update](auto-update.md): complete app staging, signature and architecture
  validation, 30-second startup acknowledgement, rollback, failed-version
  handling, preference migration, and standalone update behavior.
- [Resources and diagnostics](system-diagnostics.md): native metric sources,
  unavailable counters, report previews, storage paths, permissions, and
  diagnostic entry points.
- [Build and package verification](#build-and-verify-the-app-and-dmg):
  universal packaging, checksums, copied-app checks, and safe headless dispatch.
