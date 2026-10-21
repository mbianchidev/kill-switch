# Troubleshooting

[Documentation index](README.md) | [Installation](installation.md)

## Opening the downloaded app

KillSwitch is ad-hoc signed, **not Developer ID signed or Apple-notarized**.
Only open downloads you trust and have verified.

For a warning that the developer cannot be verified, first try opening the
copied app. Where macOS offers it, use **System Settings > Privacy & Security >
Open Anyway**, then confirm **Open** for this app. See
[Apple's safe app-opening instructions](https://support.apple.com/en-us/102445).

Do not override malware, revoked-authorization, or damaged/tampered-app warnings.
Re-download from the official release or contact your administrator. Do not
disable Gatekeeper or defeat managed-device policies.

### Legacy app-specific quarantine command

Earlier installation instructions, also included in the DMG's `Install.txt`,
contain this narrowly scoped command for a trusted copy in `/Applications`:

```bash
xattr -dr com.apple.quarantine /Applications/KillSwitch.app
```

Prefer the macOS **Open Anyway** path above. The command removes downloaded-file
quarantine metadata from this app bundle and its contents only. It does not
sign/notarize the app or disable Gatekeeper system-wide. Quit the app first and
adjust the path only for the actual installed copy. It is not an instruction
to bypass malware warnings, managed policy, or restrictions on unrelated files.
Verified automatic updates handle quarantine on their staged bundle themselves.

## Disk scans are partial or permissions disappeared

macOS privacy controls can deny access to Desktop, Documents, Downloads, and
other folders. Disk cleanup reports incomplete scans and links to **Full Disk
Access** settings. Grant access only if you intend to scan those locations.
Replacing an ad-hoc-signed app or standalone binary can require granting access
again.

Hidden home configuration, protected Library locations, cleanup roots, and
iCloud-synced items are intentionally excluded. Giving Full Disk Access does
not remove those safety rules. See [disk cleanup](usage.md#disk-cleanup).

## A process metric is unavailable

macOS restricts some counters for protected or other-user processes.
**All processes** changes the list, not your privileges. A dash can mean a
counter is unavailable; per-process GPU and App Nap data are not fabricated.
See [resource sources and limitations](system-diagnostics.md#resources).

## Two copies start or closing the window does not exit

Closing the window intentionally leaves KillSwitch in the menu bar. Use
**Quit KillSwitch** to exit.

After switching install types, a retained standalone LaunchAgent can start the
old binary while a login item starts the app. Quit the old copy and run the
[appropriate uninstaller](installation.md#uninstall) rather than deleting
unrelated login items or processes.

## CLI is missing or opens the GUI

The app does not install a shell alias automatically. Follow [CLI setup](cli.md#setup),
check that `~/bin` is on `PATH`, and verify with
`killswitchctl dev-cleanup status --json`.

The executable must be invoked with basename **`killswitchctl`**. Calling
`KillSwitch` with CLI-looking arguments starts the GUI. A regular file or
directory already occupying the alias path is preserved instead of overwritten;
inspect it before choosing how to resolve the collision.

Do not run `cleanup` merely as a setup check: it can terminate real processes.

## An update fails or repeatedly appears available

The app and its parent directory must be writable. A copy on the DMG is
read-only; a protected installation may need reinstalling in `~/Applications`.
Do not run the updater with `sudo`.

Local source builds report `dev` and consider any published release newer.
A failed release pauses automatic installation of that version; the Updates
tab displays the error and permits manual retry. Review
`~/Library/Logs/killswitch-update.log` and the
[update recovery details](auto-update.md#app-bundles).

## Source build reports a missing SwiftUIMacros plugin

Some preview Command Line Tools/SDK combinations cannot load the SwiftUI macro
plugin. Select a compatible **installed** SDK for the build/check commands
without changing the global toolchain. With the macOS 26.5 SDK installed:

```bash
export SDKROOT="$(xcrun --sdk macosx26.5 --show-sdk-path)"
```

Then rerun the [development commands](development.md#build-and-run-without-installing).
The single-command packaging alternative remains documented in the
[development guide](development.md#compatible-sdk-override).

## Reporting a problem

Search [existing issues](https://github.com/mbianchidev/kill-switch/issues) before
opening a bug report. Include your macOS version, CPU architecture, install
type, app version, reproduction steps, and relevant redacted errors.

Diagnostics, logs, file paths, and command lines can contain sensitive
information; inspect and redact them before sharing. Use
[private vulnerability reporting](../SECURITY.md) for security issues and the
[Code of Conduct contact](../CODE_OF_CONDUCT.md#reporting-an-issue) for conduct
reports, not public bug reports.
