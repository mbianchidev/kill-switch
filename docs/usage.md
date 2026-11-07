# Usage and configuration

[Documentation index](README.md) | [Installation](installation.md) |
[CLI reference](cli.md)

All data tables and record lists support two-way sorting and resettable filters.
Search accepts text and comparisons such as `CPU% > 40` or `size >= 1GB`.
See [sorting and filtering](table-controls.md) for field examples, units, and
the **Filter**, **Apply**, and **Reset filters** controls.

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

## Navigation

The grouped native sidebar keeps monitoring, investigation, management, and
personal utilities separate. CPU, Memory, Disk activity, Network traffic, and
Energy have individual pages. Visited pages retain their filters and sorting;
unvisited pages are not instantiated. The dashboard's resource headings and
system, battery, and thermal cards also open their corresponding pages.

KillSwitch intentionally has one main window, matching its single menu-bar
utility and shared resource selection. It does not expose a second independent
window with conflicting collection visibility.

The window supports a 900 x 650 minimum. Charts become a single column in narrow
detail areas, history controls wrap, and wide data tables remain horizontally
scrollable. Closing or fully obscuring the window pauses optional health and
inspection work, not the continuous resource history or watchdog.

## Dashboard

The initial tab compares CPU, memory, network traffic, and disk I/O on one time
axis. Select a live process, or use **History for** to inspect a previously
recorded process, including one that exited. **Entire Mac** restores global
graphs. The process search beside that menu also finds historical names and PIDs.

Choose **Live · 5m**, **1 hour**, **6 hours**, or **24 hours**. Drag across a chart
or use the keyboard-accessible time slider to inspect the nearest measured
sample across all four graphs. **Live** returns to current readings. These
history selections are shared with the individual resource views.

The cards above the graphs show public system, battery, and thermal information.
**Inspect** beside a live process opens its files and connections without
terminating it. **Show resource history** in the inspector returns to this page
with the same process lifetime selected.

Sampling runs every six seconds while KillSwitch is running. One-minute
averages persist locally for up to 24 hours, across app restarts; gaps during sleep,
shutdown, or failed sampling are not recorded as zero usage. Process histories
distinguish process lifetimes and boots, not just reused PIDs. An exited,
terminated, or defunct process's history and menu entry are deleted six hours
after its exit is observed, or when its last verified sighting exceeds 24 hours,
whichever comes first. Missing resource measurements or unreadable lifetime
identities do not establish an exit; unresolved process entries remain available
until their presence or exit can be verified. Already-confirmed exits continue
to expire during collector failures. A selected process that expires returns
the graphs to **Entire Mac**. Running processes and whole-Mac history keep the
24-hour window.
**Clear history** deletes stored and buffered measurements and historical process
names after confirmation; new sampling continues. Currently displayed live
processes stay selectable, and a selected live lifetime remains selected. A
historical selection returns to **Entire Mac**. See
[history storage and limitations](system-diagnostics.md#history-and-storage).

## Resources

Filter by process name, PID, user, or numeric comparisons; sort any data column
in either direction. Application icons and executable names appear where macOS
exposes them.
**My processes** is the default; **All processes** includes other users and
system processes without granting additional privileges.

Selecting a process also selects its history. CPU, Memory, Disk, and Network
reuse the dashboard's sampler, history range, and process selector rather than
starting separate recordings. Their summary cards remain labelled **Entire Mac**.
Memory history shows bytes used; the current memory-pressure counter remains
available in the summary.

**Network traffic** includes an **Inspect connections** shortcut to the dedicated
**Connections** page. Connections includes TCP listeners, active connections, bound UDP sockets, and
Unix sockets visible to this account. Search addresses/ports, process, PID,
or owner; use comparisons such as `protocol = TCP state = LISTEN` for protocol
and state. Filter listeners/active connections and sort in either direction.
Connections refresh every ten seconds only while visible.

The [resource reference](system-diagnostics.md#resources) describes all five
modes, counters, data sources, refresh intervals, and unavailable fields.
Manual kill buttons follow the [termination safety rules](#safety-and-limitations).

## Open files

Use the dedicated **Open files** page under **Investigate** to inspect accessible
file descriptors. Per-process **Inspect** buttons also expose files and
connections for one verified process lifetime. **My processes** is the default, and the scope
picker is shared with Dashboard and Resources.

The table includes path, process, PID, owner, access mode, type, size, and
reported advisory lock. Search, filter by type or reported locks, and choose
sort field/direction. An open file is not necessarily locked, and an empty lock
field does not prove there is no lock.

Inspection refreshes every ten seconds while this tab is visible and stops when
you switch tabs. It does not close files or terminate processes. See the
[inspection limitations](system-diagnostics.md#connections-and-open-files).

## Process investigation

Use **Inspect** from Dashboard, a resource page, Connections, Open files, or Dev
servers. The sheet shows current resource readings for the exact selected
lifetime, with separate searchable/sortable files and connections. Its `lsof`
query selects that PID and verifies the lifetime before and after the read.
Reused PIDs, verified exits, and unavailable identity reads are reported
explicitly; unavailable reads do not claim that a process exited.

The sheet is read-only. Switching between files and connections reuses one
collection, and hiding it releases inspection snapshots and stops its timer.
**Done** or Escape closes it. **Show resource history** selects that lifetime
on the dashboard when its history remains available.

## Dev servers

This separate page is safe to open for discovery: it never starts Dev cleanup,
terminates a process, or changes a service. It shows visible TCP listeners
grouped by the nearest Git project, a recognized project manifest, or working
directory. Search listener fields and numeric ports, or independently find
project names, paths, and branches.

**Copy address**, **Reveal folder**, **Open HTTP**, and **Inspect** are explicit
actions. Not every TCP listener is an HTTP server. Wildcard listeners use a
loopback HTTP address; malformed or non-IP endpoints do not become browser
URLs. Project discovery reads native working-directory information and bounded
Git metadata, including worktree `gitdir` pointers, without invoking git,
Docker, or a shell. Missing metadata is explained; a verified working directory
can still be shown when branch discovery fails.

Listeners refresh every ten seconds only while visible. Project context is
cached by process lifetime for at most thirty seconds and released when hidden.
All-process scope does not grant extra privileges. Project paths and branch
names are not added to persistent activity history.

## System, Battery, and Thermal

**System** shows the CPU model/architecture, physical/logical core counts,
physical memory, macOS/kernel version, awake time since restart, load averages, and shared CPU
usage. Global CPU remains 0-100% across the Mac; a process's 100% represents
one logical core. Load averages are runnable/waiting work, not percentages.
Awake time since restart is `ProcessInfo.systemUptime` and excludes sleep; it
is not presented as total elapsed time since boot.

**Battery** shows charge, charging state, power source, reported condition,
cycle count, applicable time estimates, and Low Power Mode when macOS exposes
them. A desktop's verified lack of an internal battery is distinct from a
failed read or an attached UPS. Missing counters remain N/A.

**Thermal** shows macOS's Normal, Warm, High, or Critical thermal-pressure
assessment with a textual explanation. These states are not temperatures;
KillSwitch does not invent sensor readings or fan speeds.

One shared health monitor uses supported public interfaces at most every thirty
seconds while one of these pages or Dashboard is visible. No privileged helper,
serial number, hardware UUID, temperature sensor, or additional background
recording is involved. Health details are live, not persisted.

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
- Sort by item, contents, modification date, or space used; the Sort picker
  also offers path and type. Numeric filters use bytes, not formatted size text.
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

**Auto-kill is enabled by default.** Sidebar entry asks for confirmation while
automatic termination is enabled. Confirming entry immediately runs a cleanup,
which can terminate qualifying servers older than the saved age. Age is total
process lifetime, not inactivity; a busy server can qualify.
Use **Dev servers** for read-only discovery. If you cannot risk that first
cleanup pass, cancel the entry confirmation. The CLI
[status command](cli.md#read-saved-status) reads settings without running cleanup.

Each entry reloads saved settings without writing a retained monitor's stale
values back to preferences. Automatic cleanup requires both current saved
enablement and authorization for this visit (confirmation, or an explicit
Auto-kill switch action). A read-only entry cannot inherit later external
enablement, and saved disablement blocks the ensuing cleanup pass.

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
