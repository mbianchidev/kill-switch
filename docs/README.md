# KillSwitch documentation

KillSwitch is a native macOS resource manager and menu-bar utility. Start with
the [project quickstart](../README.md#quickstart), then use the guides below for
complete setup, configuration, and development instructions.

## For users

| Guide | What it covers |
| --- | --- |
| [Installation](installation.md) | Requirements, app and standalone installs, login startup, first run, migration, and uninstall |
| [Usage and configuration](usage.md) | Menu-bar behavior, every tab, editable defaults, persistence, and cleanup safety |
| [Headless CLI and Porto integration](cli.md) | CLI setup, commands, JSON examples, port syncing, and exit codes |
| [Resources and system diagnostics](system-diagnostics.md) | Resource counters, sampling, macOS restrictions, spindump, and sysdiagnose |
| [Updates](auto-update.md#using-updates) | Update controls, app/standalone behavior, validation, and recovery |
| [Troubleshooting](troubleshooting.md) | Opening an unnotarized app, permissions, duplicate installs, CLI issues, and SDK errors |

**Before using Dev cleanup:** automatic termination starts enabled for qualifying
servers older than 12 hours. Opening the tab runs a cleanup immediately. Review
the [safety notes](usage.md#safety-and-limitations); process age is not inactivity.

## For developers

| Guide | What it covers |
| --- | --- |
| [Development and implementation](development.md) | Source setup, code layout, core targets, checks, debugging, and safe packaging |
| [Release and updater internals](auto-update.md#release-automation) | Version selection, release assets, publishing workflow, startup confirmation, and rollback |
| [CI and security scanning](ci-security.md) | Core/package checks, CodeQL setup, and cache constraints |
| [Contributing](../CONTRIBUTING.md) | Bug reports, proposals, focused pull requests, and review expectations |
| [Agent instructions](../AGENTS.md) | Repository map, verified commands, and safety constraints for coding agents |
| [Accessibility](../ACCESSIBILITY.md) | Native accessibility contribution guidance, manual verification, and known limitations |

## Community and policies

- [Security policy](../SECURITY.md): supported releases and private reporting.
- [Code of Conduct](../CODE_OF_CONDUCT.md): community behavior and reporting.
- [AI contribution responsibility](../README.md#ai-policy).
- [MIT License](../LICENSE).
- [Published releases](https://github.com/mbianchidev/kill-switch/releases).

[Back to the project](../README.md)
