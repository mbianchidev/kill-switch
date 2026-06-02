# KillSwitch

A lightweight macOS process manager utility. Lists the processes belonging to the current user, shows PID, CPU%, and memory usage, and lets you terminate them with a single click.

## Features

- Real-time process list (refreshes every 3s)
- Works for whichever user is running the app (no hardcoded username)
- Collapses helper/child processes into their main (parent) process, aggregating CPU and memory — e.g. Spotify and its helpers appear as a single entry
- Shows real application icons where available for easier recognition
- Filter processes by name
- Sort by CPU usage, memory, name, or PID
- One-click process termination (SIGTERM, falls back to SIGKILL)
- Runs at login via LaunchAgent
- Dark, translucent UI inspired by Raycast

## Requirements

- macOS 13+ (Ventura or later)
- Swift 5.9+
- Xcode Command Line Tools

## Build & Install

```bash
chmod +x install.sh uninstall.sh
./install.sh
```

This will:
1. Build the release binary
2. Copy it to `/usr/local/bin/KillSwitch`
3. Install a LaunchAgent so it starts at login

## Uninstall

```bash
./uninstall.sh
```

## Run without installing

```bash
swift build -c release
.build/release/KillSwitch
```

## Tech Stack

- Swift 5.9
- SwiftUI
- AppKit (`NSWorkspace`) for application icons
- macOS process APIs (`ps` command)
- LaunchAgent for auto-start
