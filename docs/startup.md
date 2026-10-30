# Startup management

[Documentation index](README.md) | [Usage and configuration](usage.md#startup)

The **Startup** tab lists future-launch registrations, not every currently
running process. Search by app/service name, command, or path; filter by entry
type and enabled state, then choose a sort field and direction. Select a row
to read its complete source and command.

## Supported entries

| Entry | Discovery | Control |
| --- | --- | --- |
| User launch agents | `~/Library/LaunchAgents` and `/Library/LaunchAgents`, in the current `gui/UID` domain | Confirmed `launchctl disable` / `enable` overrides |
| System services | `/Library/LaunchDaemons`, in the `system` domain | Same overrides, with macOS administrator approval |
| macOS agents/services | `/System/Library/LaunchAgents` and `/System/Library/LaunchDaemons` | Read-only |
| Legacy login apps | **Load login apps**, using System Events | Remove only the selected login registration; **Enable** restores its saved name, path, and hidden state |
| App-owned login/background items | **Load background items**, using administrator-authorized `sfltool dumpbtm` | Read-only inventory; use **Login Items settings** for the macOS-managed switch |
| Your cron jobs | Current account's `crontab -l` | Comment/uncomment only the selected job |
| Root's cron jobs | **Load system cron**, with administrator approval | Same job-level edits, with administrator approval |

Cron discovery covers user and root crontabs, including `@reboot` and standard
calendar macros. It does not edit `/etc/crontab`, periodic scripts, or device
management profiles. Modern background-item discovery uses Apple's diagnostic
text output, which can vary by macOS release; unreadable output is reported
rather than assumed to be a complete inventory.

## Confirming changes

Every **Disable** or **Enable** requires confirmation. System-wide changes use
the native administrator authorization dialog; cancelling does not report
success. Startup controls do not send signals, unload services, stop running
jobs, delete apps, or rewrite launch-agent/daemon plists. Enabling a service
allows future launches; it does not immediately start it.

The app rereads a service's source before changing it, refuses changed files,
unexpected ownership, symlink entries, unsafe labels, other users' GUI domains,
and protected macOS services. It checks the resulting `launchctl` override.
If current state cannot be read, that entry stays unknown/read-only.
Vendor apps can recreate their registrations or override changes later.

Cron changes preserve unrelated jobs, comments, environment variables, and
formatting. Disabled jobs remain visible with a `# KillSwitch disabled: ` prefix.
The current crontab is checked again immediately before installing the edited
document. A concurrent change is refused; **Refresh** before trying again.
Replacement contents never enter shell or `osascript` arguments. A private
`0600` input is copied into an authorization-owned temporary directory, checked
against its expected hash, installed, and verified in the same command. Both
temporary copies are cleaned up, including on failure.
The administrator transport removes only the newline added by `osascript`,
preserving the crontab's own trailing newlines and subsequent edit fingerprints.

## Permissions and recovery

Opening Startup automatically reads service definitions and your crontab
without requesting administrator authorization. **Load login apps** explicitly
requests any required Automation permission for System Events. If denied,
review **System Settings > Privacy & Security > Automation** and refresh.
**Load background items** separately requests administrator authorization for
the macOS background-item database. **Load system cron** explicitly requests
authorization to read root's jobs. These inventories stay cached when switching
tabs or refreshing an unrelated changed entry. Only explicit **Refresh** or
**Load** actions reload privileged inventories and can prompt again.

Saved login-app backups are not proof that a registration is disabled.
Until a successful **Load login apps** read verifies its absence, a saved record
is unknown/read-only. Current live metadata replaces an older hidden-state
backup for the same registration rather than creating duplicate rows.

App-owned background items use macOS's own controls. Open **Login Items
settings**, or navigate to **System Settings > General > Login Items** manually
if the link is unavailable. Managed-device policies and protected services are
not bypassed.

Legacy login-app restoration data and complete pre-edit cron backups are kept
privately under:

```text
~/Library/Application Support/KillSwitch/StartupBackups/
```

The directory uses `0700`; saved files use `0600`. These backups can contain
commands and paths, so review them before sharing. They are separate from
activity history and are not deleted by **Clear history**. Failed operations
retain their backups; cron errors identify the backup path. Do not overwrite
an entire current crontab with an old backup without first comparing unrelated
changes. Prefer the app's individual **Enable** action when available.

Partial reads and operation failures remain visible in Startup. A failed
command is not treated as an empty inventory or a successful disable.
