# KillSwitch

A lightweight macOS process manager and diagnostics utility. It provides Activity Monitor-style system resources, one-click process termination, developer cleanup, CPU alerts, keep-awake controls, and native diagnostic collection.

<img width="1710" height="1066" alt="image" src="https://github.com/user-attachments/assets/61c0ab7c-2466-4eda-84f8-586993b2d79d" />

## Features

- Activity Monitor-style CPU, memory, energy, disk, and network process views
- Defaults to the logged-in user's processes; switch to all processes to include root and other users
- Live five-minute graphs plus system-wide summary counters for every resource mode
- Shows application icons and full executable names where macOS exposes them
- Filter by process, PID, or user and sort by the active resource
- One-click process termination (SIGTERM, falls back to SIGKILL)
- Generates privileged 10-second spindump reports with preview, save, and reveal actions
- Runs full macOS `sysdiagnose` from the app or with **Shift-Command-D**
- Native macOS notifications when a process sustains high CPU for an extended period
- Menu bar (tray) icon — closing the window keeps the app running in the menu bar
- Keeps the Mac awake indefinitely or for a selected duration, with optional display sleep
- Advanced keep-awake settings for default duration, display sleep, and launch activation
- Runs at login via LaunchAgent
- Dark, translucent UI inspired by Raycast

## Tabs

### Resources

One dense, live process table with five modes:

- **CPU** — % CPU, CPU time, threads, idle wakeups, architecture kind, PID, and user, plus a stacked user/system CPU graph.
- **Memory** — physical footprint, threads, ports, PID, and user, plus memory pressure, physical memory, app memory, cached files, wired memory, compression, and swap.
- **Energy** — current energy impact, rolling power history, sleep prevention, battery charge, and power-source status.
- **Disk** — per-process bytes read/written, system operation totals, and live read/write throughput.
- **Network** — per-process bytes and packets sent/received, system totals, and live inbound/outbound throughput.

The table samples every six seconds. **My processes** is the default scope; choose
**All processes** to include system and other-user processes. macOS can restrict
disk, architecture, GPU, and App Nap values for protected processes, so unavailable
fields display an em dash instead of fabricated data.

### Dev cleanup

- Lists processes **listening on notable dev ports** (defaults: 3000–3003, 4000, 4200, 5000/5001, 5173/5174, 5555, 6006, 8000/8001, 8080/8081, 8090, 8443, 8888, 9000/9090/9091), showing PID, command, and port, each with a kill button.
- **Auto-kills** stale dev servers (node, python, java/mvn, rust/cargo, go, ruby, deno, bun, …) owned by the current user that have been running past the configured age (default **12 hours**).
- Never touches: processes owned by other users or the system, Copilot CLI / SDK, node-based MCP servers (github, context7, work_iq, fabric, seismic, azure, kusto, revenue, …), IDEs (VS Code, Obsidian, Chrome, Slack, Teams, OrbStack) or non-dev apps (Spotify, Handy, …). Detection is conservative — when in doubt it does **not** kill.
- Re-scans ports and re-runs cleanup on configurable intervals (defaults: every 5s / 10 min), plus a manual "Run cleanup now" button, and shows a summary of what was found and cleaned.
- **Fully configurable from the Settings card** — every detection input is exposed and editable, with changes persisted across launches:
  - Toggle **auto-kill** on/off and pick the **kill-after age** (1/6/12/24/48/72h).
  - Pick the **cleanup** and **port-scan** intervals.
  - Add/remove watched **ports**, dev **runtimes**, dev-server **indicators** (command-line signatures), and **protected** substrings (never killed).
  - **Reset to defaults** restores every value.


### CPU Watchdog

- Watches for processes (parent-collapsed) sustaining CPU above a threshold and fires **native macOS notifications** when one stays hot for several consecutive checks — mirroring the `cpu-watchdog.sh` / `cpu-hog-monitor.sh` shell scripts.
- Defaults: **90%** threshold, alert after **3** consecutive checks, every **5 min** (~15 min sustained). Threshold (80/85/90/95%), interval, and consecutive-check count are all configurable.
- After alerting, the per-process counter resets to avoid spam (it re-alerts after the same number of further consecutive sightings).
- Shows currently-offending processes with their consecutive count and a kill button, plus an in-app recent-alerts history.
- Appends to `~/Library/Logs/cpu-watchdog.log`, trimmed to the last 500 lines.

### Diagnostics

- **Generate Spindump** samples user and kernel call stacks for 10 seconds, previews the report in-app, and supports Save/Reveal.
- **Run System Diagnostics** creates a full macOS `sysdiagnose` archive. Use the button, the menu-bar item, or **Shift-Command-D** while KillSwitch is active.
- macOS also provides the global sysdiagnose chord **Control-Option-Shift-Command-Period**.
- Reports are stored in `~/Downloads/KillSwitch Diagnostics/`; both actions request administrator authorization.
- See [docs/system-diagnostics.md](docs/system-diagnostics.md) for data sources, permissions, and limitations.

### Keep awake

- Start or stop a keep-awake session from the main window and see its active duration and mode.
- Choose the default duration used by the tab and optional launch activation.
- Keep the display on, or allow it to sleep while the Mac stays awake for background work.
- Optionally activate keep-awake automatically when KillSwitch launches. Preferences persist across launches.

### Updates

- Shows the running version and the latest published release, with a manual **Check for updates** button.
- Auto-checks on launch and on a configurable interval (**default every 1 hour**, selectable 15m–24h); when a newer build exists, a banner appears at the top of the window.
- **Update automatically** toggle: when enabled, new releases are downloaded and installed as soon as they're found, so you're always on the latest version with no action required.
- One-click **Download & install**: fetches the new binary, validates it, replaces the user-owned `~/bin/KillSwitch` (no admin prompt — the install path is in your home directory), reloads the LaunchAgent, and relaunches.
- **Uninstall KillSwitch** button: removes the binary and login LaunchAgent (same as `uninstall.sh`), then quits — no terminal needed.
- See [docs/auto-update.md](docs/auto-update.md) for the full release + update flow.

## Menu bar (tray)

KillSwitch lives in the macOS menu bar like Caffeine. A status item (⚡ icon) sits in
the top menu bar with a dropdown:

- **Keep Mac Awake** — prevents idle system sleep indefinitely, for 5/10/15/30
  minutes, or for 1/2/5 hours. It can also prevent display sleep when enabled in
  the **Keep awake** tab. The active duration is checkmarked; choose
  **Deactivate** to restore normal sleep behavior.
- **Show KillSwitch** — brings the window back to the front (restores the Dock icon).
- **Quit KillSwitch** — fully exits the app.

Closing the main window with the red close button does **not** quit the app — it hides
the window and drops the Dock icon, leaving only the menu bar icon. Re-open it from the
menu bar item (or by clicking the Dock icon if visible). To fully quit, use **Quit
KillSwitch** from the menu bar.

## Requirements

- macOS 13+ (Ventura or later)
- Swift 5.9+
- Xcode Command Line Tools
- An administrator account for spindump and sysdiagnose collection

## Install

One line — downloads the latest prebuilt release and sets it up to run at login
(no `sudo`, no source checkout needed):

```bash
curl -fsSL https://raw.githubusercontent.com/mbianchidev/kill-switch/main/install.sh | bash
```

This downloads the latest `KillSwitch` binary, verifies its SHA-256, installs it
to `~/bin/KillSwitch`, and loads a LaunchAgent so it starts at login. Re-running
it upgrades an existing install — handy if you're stuck on an old build (see
[Updating](#updating)).

### Build from source instead

From a checkout, `install.sh` builds with Swift automatically:

```bash
chmod +x install.sh uninstall.sh
./install.sh            # builds with Swift when run inside the repo
```

Force a mode with `KILLSWITCH_INSTALL_MODE=source` or `KILLSWITCH_INSTALL_MODE=release`.

This will:
1. Build (or download) the release binary
2. Copy it to `~/bin/KillSwitch` (no `sudo` required)
3. Install a LaunchAgent so it starts at login

## Uninstall

From the app, open the **Updates** tab and click **Uninstall KillSwitch** (removes
the binary and login LaunchAgent, then quits). Or from a terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/mbianchidev/kill-switch/main/uninstall.sh | bash
# or, from a checkout:
./uninstall.sh
```

## Updating

Released builds update themselves: open the **Updates** tab (or wait for the
launch check) and click **Download & install** when a newer version is offered.
The updater overwrites whatever binary the LaunchAgent launches, so the new
version is the one that comes back after the relaunch.

Every push to `main` is automatically published as a GitHub Release
(auto-incrementing semver, e.g. `v1.1.1`) with the compiled binary attached, and
the running app compares its embedded version against the latest release. See
[docs/auto-update.md](docs/auto-update.md) for details.

To update a source checkout manually instead:

```bash
./update.sh
```

## Run without installing

```bash
swift build -c release
.build/release/KillSwitch
```

## Tech Stack

- Swift 5.9
- SwiftUI + Swift Charts (live resource graphs)
- AppKit (`NSWorkspace`) for application icons; `NSStatusItem` for the menu bar (tray) icon
- macOS process and resource APIs (`top`, `libproc`, Mach VM statistics, IOKit, `nettop`, `netstat`, `pmset`)
- `osascript` for native notifications, privileged diagnostics, and privileged self-update
- `URLSession` (async/await) + GitHub Releases API for in-app updates
- GitHub Actions for continuous releases on every push to `main`
- CodeQL static analysis (advanced setup, manual Swift build) — see
  [docs/ci-security.md](docs/ci-security.md)
- LaunchAgent for auto-start
