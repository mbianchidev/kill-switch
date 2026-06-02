# KillSwitch

A lightweight macOS process manager utility. Lists processes belonging to user `mbianchidev`, shows PID, CPU%, and memory usage, and lets you terminate them with a single click.

## Features

- Real-time process list (refreshes every 3s)
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
- macOS process APIs (`ps` command)
- LaunchAgent for auto-start
