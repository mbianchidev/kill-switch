# Usage and configuration

[Documentation index](README.md) | [Installation](installation.md) |
[CLI reference](cli.md)

## Menu bar (tray)

KillSwitch uses a dark, translucent, Raycast-inspired interface. Like Caffeine,
closing the main window leaves the menu-bar utility running rather than
quitting. Its status item uses a bolt-shaped icon (`bolt.slash`).

- **Keep Mac Awake** offers a duration menu. The active duration is checkmarked;
  **Deactivate** restores normal sleep behavior.
- **Generate Spindump** and **Run System Diagnostics** start the corresponding
  diagnostic actions.
- **Show KillSwitch** reopens the window and restores the Dock icon. Clicking
  the Dock icon also reopens the window when that icon is visible.
- **Quit KillSwitch** fully exits, saves screen-time state, and releases
  keep-awake resources.

The watchdog, screen-time monitor, and CPU/memory/disk/network sampling continue
with the window hidden and while using other tabs. Quitting flushes the current
history bucket. Energy details run only while their resource view is selected;
connection/open-file inspection runs only while its panel is visible.
The Dev cleanup tab starts its timers on appearance and stops them on
disappearance; opening it runs an immediate cleanup.

## Dashboard

The initial tab compares CPU, memory, network traffic, and disk I/O on one time
axis. Select a live process, or use **History for** to inspect a previously
recorded process, including one that exited. **Entire Mac** restores global
graphs. The process search beside that menu also finds historical names and PIDs.

Choose **Live · 5m**, **1 hour**, **6 hours**, or **24 hours**. Drag across a chart
or use the keyboard-accessible time slider to inspect the nearest measured
sample across all four graphs. **Live** returns to current readings. These
history selections are shared with the individual resource views.

Sampling runs every six seconds while KillSwitch is running. One-minute
averages persist locally for 24 hours, across app restarts; gaps during sleep,
shutdown, or failed sampling are not recorded as zero usage. Process histories
distinguish process lifetimes and boots, not just reused PIDs. **Clear history**
deletes stored measurements and process names after confirmation; new sampling
continues. See [history storage and limitations](system-diagnostics.md#history-and-storage).

## Resources

Filter by process name, PID, or user, sort by the active resource, and inspect
application icons and executable names where macOS exposes them.
**My processes** is the default; **All processes** includes other users and
system processes without granting additional privileges.

Selecting a process also selects its history. CPU, Memory, Disk, and Network
reuse the dashboard's sampler, history range, and process selector rather than
starting separate recordings. Their summary cards remain labelled **Entire Mac**.
Memory history shows bytes used; the current memory-pressure counter remains
available in the summary.

Within **Network**, switch between **Connections** and **Traffic by process**.
Connections includes TCP listeners, active connections, bound UDP sockets, and
Unix sockets visible to this account. Search addresses/ports, process, PID,
owner, protocol, or state, then filter listeners/active connections and sort.

**Open files** lists accessible file descriptors by process, with path, PID,
owner, access mode, type, size, and reported advisory lock. Search, filter by
type or reported locks, and choose sort field/direction. An open file is not
necessarily locked, and an empty lock field does not prove there is no lock.
These inspection panels refresh every ten seconds and do not close files or
terminate processes.

The [resource reference](system-diagnostics.md#resources) describes all five
modes, counters, data sources, refresh intervals, and unavailable fields.
Manual kill buttons follow the [termination safety rules](#safety-and-limitations).

## Startup

Review launch agents, system services, login apps, app-owned background items,
and cron jobs. Search/filter/sort entries and confirm **Disable** or **Enable**
for supported registrations. Changes affect future launches, not running
processes. System services and root's crontab require macOS administrator
approval; protected macOS services stay read-only.

**Load login apps** explicitly requests any required System Events access.
**Load background items** separately requests administrator access to the
macOS background-item inventory.
Modern app-owned background-item switches remain in macOS **Login Items
settings**. **Load system cron** explicitly authorizes reading root's crontab.
See [startup management](startup.md) for supported entries, backups, permissions,
and recovery.

## Disk cleanup

- Opens on **Largest files**, sorted by occupied disk space. Switch to
  **Temporary**, **Caches**, or **Large folders**.
- Browse with breadcrumbs, filter by name or path, reveal items in Finder, and
  select one or more candidates.
- Scans continue across tab, category, or folder changes. Completed locations
  are cached; **Rescan** applies added, updated, and removed items without
  clearing visible rows first.
- Every removal requires confirmation and moves items to macOS Trash.
  KillSwitch never permanently deletes an item.
- Standard home folders such as Documents, Downloads, Pictures, and Movies
  must be opened before their contents can be selected. Cleanup roots,
  `~/Library` outside the designated cleanup areas, and hidden home
  configuration are protected.
- iCloud-synced items are excluded because moving them to Trash can remove
  data from every synced device.
- Partial scans report permission problems and link to **Full Disk Access**.
  Desktop, Documents, Downloads, and other protected locations may need access.
  Updating an ad-hoc-signed app or binary may require granting it again.

## Dev cleanup

**Auto-kill is enabled by default.** Opening the tab immediately runs a cleanup,
which can terminate qualifying servers older than the saved age. Age is total
process lifetime, not inactivity; a busy server can qualify.
If you cannot risk that first cleanup pass, do not open the tab. The CLI
[status command](cli.md#read-saved-status) reads settings without running cleanup.

The table shows PID, command, and port for watched listeners and recognized dev
servers, with manual kill buttons. Automatic cleanup requires current-user
ownership, a matching runtime and dev-server indicator, age beyond the saved
threshold, and no applicable protection. Commands under `/System/` are skipped.
Other users' processes are not automatic-cleanup candidates.

### Settings and persistence

The **Settings** card exposes every detection input and persists it across
launches:

| Setting | Default | Choices |
| --- | --- | --- |
| Auto-kill | Enabled | On/off; turning it off does not disable manual kill buttons |
| Kill-after age | 12 hours | 1, 6, 12, 24, 48, or 72 hours |
| Port refresh | 5 seconds | 5/10/30 seconds or 1 minute |
| Cleanup interval | 10 minutes | 30 seconds or 1/5/10/15/30/60 minutes |
| Watched ports | Listed below | Add/remove ports from 1 through 65535 |
| Runtimes | Listed below | Editable executable-name entries |
| Dev-server indicators | Listed below | Editable command-line substrings |
| Protected substrings | Listed below | Editable automatic-cleanup exclusions |

**Run cleanup now** uses the saved auto-kill and age settings and displays
candidate and termination counts. **Reset to defaults** re-enables auto-kill,
restores all values, clears synced integration ports, and immediately runs
cleanup. Integration ports remain cleared until that integration syncs again.

### Developer cleanup defaults

The source of the built-ins is
[`DevCleanupPreferences.swift`](../Sources/DevCleanupCore/DevCleanupPreferences.swift).
Default watched ports:

```text
3000-3003, 4000, 4200, 5000/5001, 5173/5174, 5555, 6006,
8000/8001, 8080/8081, 8090, 8443, 8888, 9000/9090/9091
```

Runtime families include Node.js/npm, Deno, Bun, Python, Java/Maven, Rust/Cargo,
Go, and Ruby. The executable-name entries are:

```text
node, deno, bun, npm, npx, pnpm, yarn,
python, python3, python2, java, mvn, cargo, rustc, go, ruby
```

A runtime match alone is insufficient; it must also match a dev-server
command-line indicator. The built-in indicators are:

```text
vite, next dev, nodemon, webpack, react-scripts, ng serve,
astro dev, nuxt, remix, ng build --watch, electron ., electron-forge,
npm run, npm start, npm exec, npx, yarn dev, yarn start,
pnpm dev, pnpm start, pnpm run, bun run, bun dev,
spring-boot:run, gradlew, quarkus:dev,
cargo run, cargo watch, cargo-watch, trunk serve,
go run, air, rails server, rails s, puma, rackup,
flask run, uvicorn, gunicorn, manage.py runserver, runserver,
http.server, deno run, deno task
```

Default protected command-line substrings cover:

- **Copilot CLI / SDK:** `copilot`.
- **MCP servers**, including GitHub, Context7, Work IQ, Fabric, Seismic, Azure,
  Kusto, and Revenue examples: `mcp`, `modelcontextprotocol`, `context7`,
  `work_iq`, `work-iq`, `workiq`, `fabric`, `seismic`, `azure`, `kusto`,
  `revenue`, and `server-github`.
- **IDEs and desktop applications**, including VS Code, Obsidian, Chrome,
  Slack, Teams, OrbStack, Spotify, Handy, and KillSwitch: `killswitch`,
  `visual studio code`, `code helper`, `electron`, `obsidian`, `chrome`,
  `slack`, `teams`, `orbstack`, `spotify`, and `handy`.
- **Language servers:** `language-server`, `language_server`, `tsserver`, `lsp`.

These are editable substring checks for automatic cleanup, not an unconditional
guarantee about every process from a named product. Manual kill buttons do not
use that exclusion list. Porto-managed `limactl hostagent` processes have
separate hard protection across all termination paths, even if exclusions
change.

Watched ports control discovery/listing, not automatic-cleanup eligibility.
Matching servers on other ports can qualify. The [CLI](cli.md) can sync
integration-owned ports without overwriting user-edited ports.

## CPU watchdog

The **Watchdog** tab sends native notifications after consecutive high-CPU
observations of parent-collapsed processes.

| Setting | Default | Choices |
| --- | --- | --- |
| CPU threshold | 90% | 80%, 85%, 90%, or 95% |
| Check interval | 5 minutes | 30 seconds or 1/5/10/15/30/60 minutes |
| Consecutive checks | 3 | 2, 3, 5, or 6 |

These controls apply to the current app session. The process counter resets
after each alert and can alert again after the same number of further
consecutive sightings. Offenders have kill buttons and consecutive counts;
recent alerts appear in the app. `~/Library/Logs/cpu-watchdog.log` retains the
last 500 lines.

These are sampled observations, not proof of uninterrupted load for an exact
duration. See the [watchdog model](development.md#watchdog-model).

## Screen time

Tracks today's active use and the current continuous stretch. Counting pauses
after **5 minutes** without keyboard/pointer input; **10 minutes** idle, screen
lock, display/system sleep, or a long monitoring gap ends the stretch.

| Setting or action | Behavior |
| --- | --- |
| Break reminders | Off by default; enable native **Touch grass** notifications |
| Reminder interval | 2 active hours by default; choose an integer from 1 through 12 hours |
| Reset stretch | Ends the current stretch without clearing today's total |

Changing the reminder interval schedules the next future boundary rather than
immediately firing an overdue reminder. Today's total, current stretch,
settings, and last reminder persist across launches. Daily totals reset at local
midnight without ending an active stretch.

Only aggregate durations are stored locally, not app, website, keystroke, or
pointer histories.

## Diagnostics

**Generate Spindump** samples user/kernel stacks for 10 seconds and offers
preview, Save, and Reveal. **Run System Diagnostics** creates a full
`sysdiagnose` archive. Both request administrator authorization and write under
`~/Downloads/KillSwitch Diagnostics/`.

Use the tab, app menu, menu bar, or **Shift-Command-D** while KillSwitch is
active. macOS also provides **Control-Option-Shift-Command-Period** for
sysdiagnose. Collection may take several minutes. Review reports for sensitive
data before sharing; see the [diagnostics guide](system-diagnostics.md).

## Keep awake

Start or stop a session from the tab or **Keep Mac Awake** menu, and inspect its
active duration and mode.

| Setting | Default | Choices |
| --- | --- | --- |
| Duration | Indefinite | Indefinitely, 5/10/15/30 minutes, or 1/2/5 hours |
| Keep display on | Enabled | Keep the display awake or allow it to sleep while the Mac stays awake |
| Activate at launch | Disabled | Optional automatic activation when KillSwitch starts |

Settings persist across launches. **Reset to defaults** restores the values
above. **Deactivate** stops the active session and restores normal sleep
behavior. Idle-sleep prevention does not guarantee against lid-close or forced
sleep; quitting the app releases its assertions.

## Updates

The **Updates** tab checks at launch and every hour by default. Check intervals
are 15/30 minutes or 1/3/6/12/24 hours; automatic installation is off by default.
These preferences persist. See [update controls](auto-update.md#using-updates),
[installation requirements](installation.md), and [uninstall](installation.md#uninstall).

## Safety and limitations

- Automatic cleanup is age-based, not idle detection, and is not limited to
  watched ports.
- Manual kill buttons remain available when auto-kill is disabled or an
  exclusion matches. They send SIGTERM, with SIGKILL as a fallback if sending
  SIGTERM fails, and can lose unsaved work. Uninspectable processes and
  Porto-managed hostagents are refused.
- **All processes** does not grant administrator privileges. macOS permissions
  still apply to process access, disk scans, and diagnostics.
- Trash operations are not permanent deletion, but still require checking the
  selected files and confirmation. iCloud and protected locations are excluded.
- Releases are ad-hoc signed, not Apple-notarized. Checksums verify integrity
  against the published release, not an Apple-verified publisher identity.
- Monitoring and keep-awake sessions stop when the app quits.
