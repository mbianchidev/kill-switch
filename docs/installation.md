# Installation

[Documentation index](README.md) | [Usage and configuration](usage.md) |
[Troubleshooting](troubleshooting.md)

## Requirements

- **macOS 13+ (Ventura or later)** on Apple Silicon or Intel. Release apps and
  binaries are universal; Windows and Linux are not supported.
- **No developer tools are needed for prebuilt releases.** Source builds need
  Git, Swift 5.9+, and Xcode Command Line Tools or Xcode; see
  [development setup](development.md#build-and-run-without-installing).
- **Administrator authorization** is needed for spindump and sysdiagnose, not
  ordinary monitoring. Installation needs a folder writable by your account.
- Disk scans may need **Full Disk Access** for protected folders. macOS can
  still restrict individual process metrics.

## macOS app

1. Download [KillSwitch.dmg](https://github.com/mbianchidev/kill-switch/releases/latest/download/KillSwitch.dmg)
   from the [latest release](https://github.com/mbianchidev/kill-switch/releases/latest).
2. Open the DMG and drag **KillSwitch.app** onto the **Applications** shortcut.
3. Eject the DMG, then open **KillSwitch** from `/Applications`.

The app is ad-hoc signed, but **not Developer ID signed or notarized by Apple**.
For a trusted download blocked because its developer cannot be verified, first
attempt to open it, then use **System Settings > Privacy & Security > Open Anyway**
where macOS offers that per-app exception. Follow
[Apple's opening guidance](https://support.apple.com/en-us/102445) and the
[troubleshooting precautions](troubleshooting.md#opening-the-downloaded-app).
Do not bypass malware warnings or a managed-device policy.

The release includes
[KillSwitch.dmg.sha256](https://github.com/mbianchidev/kill-switch/releases/latest/download/KillSwitch.dmg.sha256)
for checking the download's SHA-256. A matching checksum checks integrity
against the release, not an Apple-verified publisher identity.

### Installation location and login startup

Automatic updates require both the app and its parent folder to be writable.
A normal user-owned copy in `/Applications` works; use `~/Applications` if your
account cannot update the system Applications folder. Do not update a copy
running from the read-only DMG. Adjust any documented app paths and the optional
CLI symlink if you install elsewhere.

App installs do not create a login item automatically. To run at login, add
**KillSwitch** in **System Settings > General > Login Items**
(**Login Items & Extensions** on newer macOS versions).

The DMG does not change your shell or install `killswitchctl` automatically.
See [CLI setup](cli.md#setup) for its optional symlink.

### Switching from a script installation

Quit the old copy and use its [standalone uninstaller](#uninstall) before
switching to the app. Otherwise the old LaunchAgent can start a second copy.
Saved preferences, the auto-update opt-in, and synced integration ports are
retained; [preference migration](auto-update.md#app-bundles) describes the shared
defaults domain.

## Standalone binary and CLI

From outside a source checkout, this downloads the latest release, starts the
GUI immediately, and enables startup at login. No `sudo` or developer tools are
needed. Review the script before running it:

```bash
curl -fsSL https://raw.githubusercontent.com/mbianchidev/kill-switch/main/install.sh | bash
```

The installer verifies the binary's SHA-256, installs `~/bin/KillSwitch`, links
`~/bin/killswitchctl` to that same binary, and loads
`~/Library/LaunchAgents/io.killswitch.agent.plist`. Re-running it upgrades an
existing install and refreshes the CLI symlink.

From a checkout with Swift available, it builds locally instead. Override with
`KILLSWITCH_INSTALL_MODE=source` or `KILLSWITCH_INSTALL_MODE=release`; see
[source installation](development.md#standalone-source-installation).
Ensure `~/bin` is on `PATH` before invoking `killswitchctl`.

Install, update, and uninstall refuse to replace or remove `~/bin/KillSwitch`
when it is a real directory. Existing binary files and symlinks can be replaced
or removed safely. The CLI path is app-owned only when it is a symlink; regular
files and directories at `~/bin/killswitchctl` are preserved.

## First run

The app opens on **Resources** with **My processes** selected. A live process
table and a KillSwitch menu-bar icon confirm it is running. Choose
**All processes** to include system and other-user processes.

**Before opening Dev cleanup:** automatic termination is **enabled by default**
for qualifying dev servers older than **12 hours**. Opening that tab runs a
cleanup immediately. Age means total process lifetime, not inactivity. Read the
[configuration and safety guidance](usage.md#dev-cleanup) before using it.

Closing the window hides it and removes the Dock icon; it does **not** quit.
Use **Show KillSwitch** in the menu bar to reopen it or **Quit KillSwitch** to
exit. See [menu-bar behavior](usage.md#menu-bar-tray) for background activity.

## Updates

The app checks at launch and on a saved interval; automatic installation is
opt-in. Use **Updates > Download & install**, enable **Update automatically**, or
replace the app manually with a trusted release. See
[update controls and recovery](auto-update.md#using-updates) for both install
types and their requirements.

## Uninstall

**App installation:** choose **Quit KillSwitch** in the menu bar, remove its
login item in System Settings if you added one, then move
`/Applications/KillSwitch.app` to Trash. **Updates > Show in Finder** reveals
the installed app. Remove `~/bin/killswitchctl` too if you created that symlink.
Preferences are retained.

**Standalone installation:** use **Updates > Uninstall KillSwitch** to remove
the binary, CLI symlink, and LaunchAgent, then quit. Or run:

```bash
curl -fsSL https://raw.githubusercontent.com/mbianchidev/kill-switch/main/uninstall.sh | bash
# or, from a checkout:
./uninstall.sh
```

The uninstaller preserves preferences. Diagnostic reports and logs are separate
files; review them before deciding whether to remove them. Do not delete a whole
Library folder or unrelated preferences as part of uninstalling KillSwitch.
