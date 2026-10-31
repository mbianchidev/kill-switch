# KillSwitch

[Documentation](docs/README.md) |
[Releases](https://github.com/mbianchidev/kill-switch/releases) |
[Issues](https://github.com/mbianchidev/kill-switch/issues)

<img width="1280" height="935" alt="Killswitch screenshot" src="https://github.com/user-attachments/assets/c8b4883a-df7f-4934-b977-b372cff3deb0" />

KillSwitch is a native macOS resource manager and menu-bar utility for developers
managing long-running workloads, including AI-assisted development. Monitor
processes and 24-hour resource history, inspect connections and open files,
manage startup entries, review disk cleanup candidates, and control sleep,
with optional headless developer-tool integration.

## Contents

[Quickstart](#quickstart) | [Why KillSwitch](#why-killswitch) |
[How it works](#how-it-works) | [Configuration](#get-started-and-configuration) |
[Features](#features) | [Documentation](#documentation) |
[AI policy](#ai-policy) | [Contributing](#contributing) |
[Security](#security) | [License](#license)

<a id="requirements"></a><a id="install"></a>
<a id="macos-app-recommended"></a><a id="first-run"></a>

## Quickstart

Requires **macOS 13+** on Apple Silicon or Intel. The universal release needs no
developer tools; Windows and Linux are not supported.

With [Homebrew](https://brew.sh) installed:

```bash
brew install --cask mbianchidev/tap/killswitch
```

This installs the app and `killswitchctl`. Open **KillSwitch** from `/Applications`.
See [Homebrew installation and updates](docs/installation.md#homebrew-cask).
Or install manually:

1. Download [KillSwitch.dmg](https://github.com/mbianchidev/kill-switch/releases/latest/download/KillSwitch.dmg).
2. Open it, drag **KillSwitch.app** to **Applications**, and eject the DMG.
3. Open **KillSwitch** from `/Applications`. The activity dashboard and menu-bar
   icon confirm it is running.

The app is **ad-hoc signed, not Developer ID signed or Apple-notarized**. For a
trusted download, try opening it, then use **System Settings > Privacy & Security >
Open Anyway** where offered. Do not bypass malware warnings or managed-device
policy. See [opening precautions and troubleshooting](docs/troubleshooting.md).

**Dev cleanup starts with auto-kill enabled for qualifying servers older than
12 hours. Opening that tab runs a cleanup immediately.** Review its
[settings and safety rules](docs/usage.md#dev-cleanup) first.

Closing the window leaves KillSwitch running in the menu bar. Choose
**Quit KillSwitch** there to exit. For CLI/standalone installs, login startup,
permissions, migration, or removal, use the [installation guide](docs/installation.md).

## Why KillSwitch

- Inspect process resources, developer listeners, and system diagnostics in one
  native app instead of maintaining separate monitoring scripts.
- Review cleanup candidates and use Trash with confirmation rather than
  permanently deleting files.
- Share developer-cleanup settings between the GUI and optional JSON CLI.

Cleanup is process-age-based, not idle detection, and can terminate a busy dev
server. macOS permissions still restrict some metrics and file locations.

<a id="tech-stack"></a>

## How it works

SwiftUI/AppKit views use shared Swift core targets for sampling, cleanup,
preferences, and safety checks. The same executable selects headless mode when
invoked as `killswitchctl`. A bundled helper handles verified whole-app updates.
See [architecture and development](docs/development.md).

<a id="tabs"></a><a id="usage"></a><a id="resources"></a>
<a id="disk-cleanup"></a><a id="dev-cleanup"></a><a id="cpu-watchdog"></a>
<a id="screen-time"></a><a id="diagnostics"></a><a id="keep-awake"></a>
<a id="safety-and-limitations"></a><a id="menu-bar-tray"></a>

## Get started and configuration

- **Dashboard / Resources:** compare live data and 24-hour history; inspect
  network connections. **My processes** is the default.
- **Open files:** inspect file descriptors and reported locks in one dedicated tab.
- **Startup:** review apps, services, and cron jobs before disabling future
  launches. System-wide changes require administrator approval.
- **Dev cleanup:** understand the age-based safety rules before opening the tab;
  its Settings card controls auto-kill, age, detection, and exclusions.
- **Screen time / Keep awake:** enable optional reminders or sleep prevention.
- **Updates:** installation is opt-in; checks run at launch and hourly by default.

All settings, defaults, persistence, menu actions, and limitations are in
[Usage and configuration](docs/usage.md). Start optional CLI integration with
the read-only [status command](docs/cli.md#read-saved-status).

## Features

| Capability | Implemented behavior |
| --- | --- |
| Dashboard and resources | Global/per-process CPU, memory, traffic, and disk history for 24 hours, plus live energy and process actions |
| Process inspection | Network connections in Resources and one dedicated Open files tab with search, sorting, and reported advisory locks |
| Startup | Reversible login app, service, and cron controls, with protected macOS entries kept read-only |
| Disk cleanup | Large files, temporary data, caches, and folders with confirmation and Trash |
| Developer tools | Configurable dev cleanup, protected-process rules, CPU alerts, and JSON port syncing |
| Screen time | Local active-time totals, continuous stretches, and optional break reminders |
| Keep awake | Timed or indefinite sessions with optional display sleep and launch activation |
| Diagnostics and updates | Native spindump/sysdiagnose, menu-bar access, and opt-in automatic updates |

<a id="standalone-binary-and-cli"></a><a id="headless-cli-and-porto-integration"></a>
<a id="uninstall"></a><a id="updates"></a><a id="updating"></a>
<a id="development"></a><a id="run-without-installing"></a>
<a id="build-and-run-without-installing"></a><a id="run-checks"></a>
<a id="build-the-standalone-installation-from-source"></a>
<a id="build-the-app-and-dmg-from-source"></a><a id="build-and-verify-the-app-and-dmg"></a>

## Documentation

The [documentation index](docs/README.md) separates user and developer guides.

| Guide | Coverage |
| --- | --- |
| [Installation](docs/installation.md) | Homebrew, app/standalone installs, first run, login startup, and uninstall |
| [Usage and configuration](docs/usage.md) | All tabs, settings, defaults, safety, and persistence |
| [CLI](docs/cli.md) | Setup, Porto integration, JSON examples, and exit codes |
| [Resources and diagnostics](docs/system-diagnostics.md) | Counters, sampling, permissions, and report collection |
| [Startup management](docs/startup.md) | Login apps, background items, services, cron jobs, authorization, and recovery |
| [Updates](docs/auto-update.md) | User controls, release delivery, verification, and rollback |
| [Development](docs/development.md) | Source builds, architecture, core checks, and local packaging |
| [Troubleshooting](docs/troubleshooting.md) | Opening the app, permissions, CLI, updates, and SDK issues |

## AI policy

You are responsible for everything you contribute, including AI-assisted code,
documentation, and assets. Review and test your contribution. Be able to explain
what the code does and why it is needed.

## Contributing

Bug reports, documentation, accessibility improvements, and focused pull requests
are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md),
[accessibility guidance](ACCESSIBILITY.md), and the
[Code of Conduct](CODE_OF_CONDUCT.md). Coding agents must read [AGENTS.md](AGENTS.md).

## Security

Use the enabled [private vulnerability reporting process](SECURITY.md), not public
issues. Security fixes target the latest stable release; the policy explains
best-effort response and coordinated disclosure.

## License

KillSwitch is available under the [MIT License](LICENSE).
