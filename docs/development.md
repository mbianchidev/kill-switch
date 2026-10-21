# Development and implementation

This reference complements the [README development guide](../README.md#development)
with the full tech stack, native integrations, process-detection defaults, and
alternative source-installation recipes.

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
| [`DevCleanupCore`](../Sources/DevCleanupCore) | Preferences, integration-port merging, CLI parsing, cleanup classification, and shared termination protection |
| [`DiskCleanupCore`](../Sources/DiskCleanupCore) | File scanning, cleanup candidates, protected-path checks, and Trash operations |
| [`KeepAwakeCore`](../Sources/KeepAwakeCore) | IOKit power assertions, timed sessions, and resource cleanup |
| [`InstallCore`](../Sources/InstallCore) | Binary/symlink path safety, native command execution, whole-app validation, staging, startup confirmation, and rollback |
| [`ScreenTimeCore`](../Sources/ScreenTimeCore) | Active-time tracking, idle breaks, daily rollover, and reminder boundaries |
| [`SystemMetricsCore`](../Sources/SystemMetricsCore) | Resource parsing and metric-specific sampling behavior |

[`KillSwitch`](../Sources/KillSwitch) contains the GUI and basename-dispatched
headless CLI. [`KillSwitchUpdateHelper`](../Sources/KillSwitchUpdateHelper)
performs supervised app replacement. Test executables live in [`Tests`](../Tests);
their commands are listed in the [README](../README.md#run-checks).

## UI and menu bar

The app uses a dark, translucent, Raycast-inspired interface. Like Caffeine,
closing the main window leaves a menu-bar utility running rather than quitting.
The status item uses a bolt-shaped icon (`bolt.slash`).

- **Keep Mac Awake** offers indefinite sessions, 5/10/15/30 minutes, or 1/2/5
  hours. The active duration is checkmarked. **Deactivate** restores normal
  sleep behavior; the Keep awake tab shows the active duration and mode.
- **Generate Spindump** and **Run System Diagnostics** open the corresponding
  diagnostics actions.
- **Show KillSwitch** reopens the main window and restores the Dock icon.
  Clicking the Dock icon also reopens the window when that icon is visible.
- **Quit KillSwitch** fully exits, saves screen-time state, and releases active
  keep-awake resources.

The watchdog and screen-time monitor continue with the window hidden, as does
resource sampling when Resources is the selected tab. The Keep awake tab
persists default duration, display-sleep behavior, and optional launch activation.

## Developer cleanup defaults

The editable defaults live in
[`DevCleanupPreferences.swift`](../Sources/DevCleanupCore/DevCleanupPreferences.swift).
Runtime families include Node.js/npm, Deno, Bun, Python, Java/Maven, Rust/Cargo,
Go, and Ruby. The executable-name entries are:

```text
node, deno, bun, npm, npx, pnpm, yarn,
python, python3, python2, java, mvn, cargo, rustc, go, ruby
```

A runtime match alone is not enough: automatic cleanup also requires a
configured dev-server command-line indicator, current-user ownership, and an
age beyond the saved threshold. Commands under `/System/` are skipped.

Default command-line exclusion substrings cover:

- **Copilot CLI / SDK:** `copilot`.
- **MCP servers**, including GitHub, Context7, Work IQ, Fabric, Seismic, Azure,
  Kusto, and Revenue examples: `mcp`, `modelcontextprotocol`, `context7`,
  `work_iq`, `work-iq`, `workiq`, `fabric`, `seismic`, `azure`, `kusto`,
  `revenue`, and `server-github`.
- **IDEs and desktop applications**, including VS Code, Obsidian, Chrome,
  Slack, Teams, OrbStack, Spotify, Handy, and KillSwitch itself: `killswitch`,
  `visual studio code`, `code helper`, `electron`, `obsidian`, `chrome`,
  `slack`, `teams`, `orbstack`, `spotify`, and `handy`.
- **Language servers:** `language-server`, `language_server`, `tsserver`, and
  `lsp`.

These are editable substring protections for **automatic cleanup**, not an
unconditional guarantee about every process from a named product. Manual kill
buttons do not use that exclusion list. Porto-managed `limactl hostagent`
processes have separate hard protection across all KillSwitch termination paths,
even when editable exclusions are changed.

The [README settings table](../README.md#dev-cleanup) lists watched ports,
age choices, refresh/cleanup intervals, and reset behavior. Disabling auto-kill
leaves scanning and manual kill buttons available. Process age is not idle time,
and watched ports do not restrict automatic-cleanup eligibility.

Integrators such as Porto can treat `killswitchctl` as optional: detect it,
offer the [standalone installer](../README.md#standalone-binary-and-cli) if
missing, sync their managed ports under a source such as `porto`, and invoke
cleanup. The [CLI reference](../README.md#headless-cli-and-porto-integration)
documents commands, JSON responses, persistence, and exit codes.

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
[README watchdog section](../README.md#cpu-watchdog) for controls, recent alerts,
kill buttons, and the bounded log.

## Standalone source installation

From a checkout with Swift available, `install.sh` builds locally by default.
In addition to the README's `bash install.sh` form, the original executable-script
recipe is supported:

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
`KILLSWITCH_INSTALL_MODE=release`. The [README](../README.md#standalone-binary-and-cli)
describes checksum verification, `PATH`, and protection of existing directories
and non-symlink CLI paths.

To pull/rebase the current checkout branch, rebuild, replace the standalone
binary, and reload the LaunchAgent:

```bash
./update.sh
```

The README also documents the equivalent `bash update.sh` invocation.

### Compatible SDK override

If preview Command Line Tools cannot load `SwiftUIMacros`, the README explains
how to export a compatible installed `SDKROOT` for build/check commands. To scope
the override to a single packaging command instead, the original recipe remains
available when the macOS 26.5 SDK is installed:

```bash
SDKROOT="$(xcrun --sdk macosx26.5 --show-sdk-path)" bash scripts/package-macos.sh
```

Neither form changes the global toolchain selection.

## Further implementation details

- [Auto-update](auto-update.md): complete app staging, signature and architecture
  validation, 30-second startup acknowledgement, rollback, failed-version
  handling, preference migration, and standalone update behavior.
- [Resources and diagnostics](system-diagnostics.md): native metric sources,
  unavailable counters, report previews, storage paths, permissions, and
  diagnostic entry points.
- [Build and package verification](../README.md#build-and-verify-the-app-and-dmg):
  universal packaging, checksums, copied-app checks, and safe headless dispatch.
