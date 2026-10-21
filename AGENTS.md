# Agent instructions

Read [CONTRIBUTING.md](CONTRIBUTING.md), the relevant guide under
[docs/](docs/README.md), and more-specific instructions if any are added before
editing. Keep changes focused and preserve existing user changes.

## Repository map

- `Package.swift`: SwiftPM package, macOS 13+, Swift tools 5.9; no third-party
  package dependencies.
- `Sources/KillSwitch`: SwiftUI/AppKit GUI and basename-dispatched CLI.
- `Sources/DevCleanupCore`, `DiskCleanupCore`, `KeepAwakeCore`, `InstallCore`,
  `ScreenTimeCore`, `SystemMetricsCore`: shared behavior and safety rules.
- `Sources/KillSwitchUpdateHelper`: supervised whole-app replacement.
- `Tests/*Checks`: executable regression checks, not an XCTest suite.
- `scripts/package-macos.sh` and `scripts/check-macos-package.sh`: local universal
  packaging and safe artifact/install verification.
- `.github/workflows`: core/package CI, CodeQL, and continuous releases.

See [development and architecture](docs/development.md) for implementation detail.

## Commands

Run on macOS with Swift and Xcode Command Line Tools or Xcode:

```bash
swift build -c release --product KillSwitch
swift run DevCleanupCoreChecks
swift run DiskCleanupCoreChecks
swift run InstallCoreChecks
swift run SystemMetricsChecks
swift run ScreenTimeCoreChecks
bash scripts/package-macos.sh
bash scripts/check-macos-package.sh
```

Use the smallest relevant checks for a change. No separate formatter/linter is
configured. Preview SDK problems and the compatible installed `SDKROOT`
workaround are covered in [troubleshooting](docs/troubleshooting.md#source-build-reports-a-missing-swiftuimacros-plugin).

## Safety and implementation

- Use typed Swift models and existing helpers. Keep reusable rules in the
  corresponding core target and test them with synthetic data.
- Never weaken Porto-managed Lima hostagent protection, ownership checks,
  protected-file rules, or installer symlink/directory safety.
- Never invoke `killswitchctl dev-cleanup cleanup --json` as a smoke test.
  Opening Dev cleanup can immediately terminate qualifying processes.
- `install.sh`, `update.sh`, and `uninstall.sh` change the user's installation
  and login agent. Do not run them on a normal workstation as validation.
- Prefer package verification: it mounts/ejects its own DMG, uses a disposable
  copied app, and exercises invalid headless arguments without live cleanup.
- Do not collect privileged system diagnostics or control a desktop UI without
  authorization. Never use real customer/person data as a fixture.
- Surface operation failures clearly; preserve resource cleanup and error
  reporting. Do not replace unavailable metrics with invented values.
- Keep screenshots and useful documentation unless a change explicitly requires
  replacement. Move detailed README material into linked `docs/` guides.

Local packaging does not publish. Follow the
[release guide](docs/auto-update.md#release-automation); do not create tags,
publish releases, or change signing claims as part of a check.
