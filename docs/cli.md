# Headless CLI and Porto integration

[Documentation index](README.md) | [Developer cleanup settings](usage.md#dev-cleanup)

## Setup

The [Homebrew cask](installation.md#homebrew-cask) links `killswitchctl` into
Homebrew's `bin` directory; keep Homebrew on `PATH`. The standalone installer
creates `~/bin/killswitchctl`.

For a manually installed app, create the optional symlink yourself:

```bash
mkdir -p "$HOME/bin"
ln -s /Applications/KillSwitch.app/Contents/MacOS/KillSwitch "$HOME/bin/killswitchctl"
export PATH="$HOME/bin:$PATH"
```

Adjust the app path for a custom location. `ln -s` deliberately refuses to
overwrite an existing alias; remove the old script installation first. Add
`~/bin` to your shell configuration to keep it on `PATH`.

The executable basename selects headless mode before SwiftUI starts: CLI calls
never open the window or menu-bar item. Running the same binary as `KillSwitch`
starts the GUI instead. This also applies to a source build; invoke it through a
`killswitchctl` symlink rather than passing CLI arguments directly to
`.build/release/KillSwitch`.

Every command requires `--json`. No separate CLI download or runtime dependency
is needed.

## Read saved status

Verify CLI setup without terminating processes:

```bash
killswitchctl dev-cleanup status --json
```

It returns the version, saved auto-kill mode, user ports, integration ports,
and merged effective ports. With an illustrative customized single user port:

```json
{
  "autoKillEnabled": true,
  "effectivePorts": [3000, 41000, 41001],
  "integrationPorts": {
    "porto": [41000, 41001]
  },
  "userPorts": [3000],
  "version": "v1.2.3"
}
```

`autoKillEnabled` is the saved mode, allowing integrations to show whether a
subsequent cleanup call can terminate candidates.

## Sync an integration's ports

These commands change saved integration ports:

```bash
killswitchctl dev-cleanup sync-ports --source porto --ports 41000,41001 --json
killswitchctl dev-cleanup sync-ports --source porto --ports='' --json
```

`sync-ports` returns the same response shape as `status`. Each source is stored
separately. An empty value (`--ports=''` or `--ports=`) clears it. User-edited
ports are never overwritten; scans and cleanup merge the latest persisted
integration ports without restarting the GUI.

Ports are comma-separated integers from **1 through 65535**. Source names are
normalized to lowercase, contain 1-64 letters, numbers, dots, underscores, or
hyphens, and start with a letter or number. Ports are deduplicated and sorted.

Watched ports control the listener list, not which processes cleanup may
terminate. Review the [saved detection settings](usage.md#dev-cleanup).

## Run cleanup

**This command can terminate processes.** It uses the same service as
**Run cleanup now**, including saved auto-kill, age, runtime, dev-indicator,
ownership, and exclusion rules:

```bash
killswitchctl dev-cleanup cleanup --json
```

Example response (values are illustrative, not current process data):

```json
{
  "autoKillEnabled": true,
  "candidateCount": 2,
  "killedCount": 1,
  "killedProcesses": [
    {
      "ageHours": 13.5,
      "command": "/usr/local/bin/node vite --port 41000",
      "pid": 12345,
      "runtime": "node"
    }
  ],
  "version": "v1.2.3"
}
```

If auto-kill is disabled or the saved age threshold has not been crossed, a
candidate is not terminated. Processes failing runtime, indicator, ownership,
system-path, or exclusion checks are not candidates. Porto-managed
`limactl hostagent` processes are hard-protected across every termination path,
independently of editable exclusions.

## Exit codes and errors

| Exit code | Meaning |
| --- | --- |
| `0` | Successful command; JSON is written to stdout |
| `1` | Runtime or persistence failure |
| `2` | Invalid arguments, source, or port |

Errors are JSON on stderr:

```json
{"error":{"code":"invalid_arguments","message":"..."}}
```

## Porto and other integrations

Porto is optional, not a prerequisite. An integration can detect
`killswitchctl`, offer a [supported installation method](installation.md)
if missing, sync managed ports under its own source name such as `porto`, and
invoke cleanup. Settings and integration ports use the same preferences for the
GUI and CLI, including an app-bundle symlink.

See [troubleshooting](troubleshooting.md#cli-is-missing-or-opens-the-gui) if the
alias is missing or a command opens the GUI.
