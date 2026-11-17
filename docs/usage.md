# Usage and configuration

[Documentation index](README.md) | [Installation](installation.md) |
[CLI reference](cli.md)

Click any process name or PID to copy it to the clipboard; a brief **Copied**
badge confirms it, and clicking still selects the row. PIDs are always shown as
plain identifiers, without thousands separators.

All data tables and record lists support two-way sorting and resettable filters.
Search accepts text and comparisons such as `CPU% > 40` or `size >= 1GB`.
See [sorting and filtering](table-controls.md) for field examples, units, and
the **Filter**, **Apply**, and **Reset filters** controls.

## Menu bar (tray)

KillSwitch uses a dark, translucent, Raycast-inspired interface. Like Caffeine,
closing the main window leaves the menu-bar utility running rather than
quitting. Its status item uses a bolt-shaped icon (`bolt.slash`) with a thin
vertical bar beside it that fills from the bottom as the startup disk fills up.
Hover over the icon to see the disk name, space used, capacity, and percentage.
Like Finder, available space includes purgeable space. The bar updates every
minute and is hidden when the capacity cannot be read.

- **Keep Mac Awake** offers a duration menu. The active duration is checkmarked;
  **Deactivate** restores normal sleep behavior.
- **Generate Spindump** and **Run System Diagnostics** start the corresponding
  diagnostic actions.
- **Show KillSwitch** reopens the window and restores the Dock icon. Clicking
  the Dock icon also reopens the window when that icon is visible.
- **Quit KillSwitch** fully exits, saves screen-time state, and releases
  keep-awake resources.

The watchdog, folder size alerts, screen-time monitor, and CPU/memory/disk/network
sampling continue with the window hidden and while using other tabs. Quitting flushes the current
history bucket. Energy details run only while their resource view is selected;
connection/open-file inspection runs only while its panel is visible.
Confirmed Dev cleanup runs immediately and keeps its cleanup timer active while
that page is selected, including hidden or minimized windows. Leaving the page
stops future passes. Its safe entry preview never starts cleanup or its timers.

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

## Destinations

**Destinations** under **Investigate** groups the active TCP and UDP connections
visible to your account by remote address. Each row shows the address, its
reverse DNS hostname when one exists, the scope (Public, Private, Carrier-grade
NAT, Link-local, Loopback, or Multicast), remote ports, the connection count,
and every process with a connection to that address. IPv4-mapped IPv6 addresses
are merged with their IPv4 form. Link-local IPv6 addresses keep their interface
zone, such as `fe80::1%en0`, because the same address on another interface can
be a different machine. Loopback connections are hidden unless you
select **Include loopback**; listeners, bound sockets, and closed connections
are not destinations.

Below it, **This Mac's IP addresses** lists every IPv4 and IPv6 interface
address with its prefix length, scope, and up/down status. It does not look up
a public IP address through an external service.

The page reuses the Connections collection: it refreshes every ten seconds
while visible, follows the shared **My processes** / **All processes** scope,
and stops when you leave. Hostnames come from reverse DNS lookups through your
Mac's configured resolver, four at a time, and are cached until KillSwitch quits.
A missing or different name is normal; it need not match the name an app used.

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
terminates a process, or changes a service. By default it shows **Detected dev
servers**: the same running dev servers and watched ports that Dev cleanup
lists, using your saved runtimes, indicators, exclusions, and watched ports.
You do not need to open Dev cleanup or confirm a cleanup pass to see them.
Choose **All listeners** to show every visible TCP listener instead. Rows are
grouped by the nearest Git project, a recognized project manifest, or working
directory. Search listener fields and numeric ports, or independently find
project names, paths, and branches.

Detection reads listener command lines with `ps` and uses a command only after
confirming it belongs to the same process lifetime as the sampled listener.
Commands under `/System/` are never listed. A listener whose command line is
unavailable can only match a watched port; if such listeners are hidden, a
warning shows how many and any `ps` error. Protected processes can appear here
because this page is read-only; Dev cleanup still never terminates them.

Project-warning banners follow the visible listener and project filters;
affected visible rows show their specific reason. Errors remain retained for
filtered-out listeners and reappear when those rows are shown.

**Copy address**, **Reveal folder**, **Open HTTP**, and **Inspect** are explicit
actions. Not every TCP listener is an HTTP server. Wildcard listeners use a
loopback HTTP address; malformed or non-IP endpoints do not become browser
URLs. Project discovery reads native working-directory information and bounded
Git metadata, including worktree `gitdir` pointers, without invoking git,
Docker, or a shell. Only Git's CR/LF line terminators are discarded; whitespace
in directory paths and valid branch names is preserved. Missing metadata is
explained; a verified working directory can still be shown when branch discovery
fails.

Listeners refresh every ten seconds only while visible. Project context is
cached by process lifetime for at most thirty seconds and released when hidden.
Changing the system clock does not prolong or shorten this cache.
Filters do not change collection. If opening HTTP or revealing a folder covers
KillSwitch, inspection pauses and resumes automatically when its window is
visible again, without switching pages.
All-process scope does not grant extra privileges. Project paths and branch
names are not added to persistent activity history.

## System, Battery, and Thermal

**System** shows the CPU model/architecture, physical/logical core counts,
physical memory, macOS/kernel version, awake time since restart, load averages, and shared CPU
usage. Global CPU remains 0-100% across the Mac; a process's 100% represents
one logical core. Load averages are runnable/waiting work, not percentages.
Awake time since restart is `ProcessInfo.systemUptime` and excludes sleep; it
is not presented as total elapsed time since boot.

**System details** on the System page adds the model name and identifier, model
number, computer name, local hostname, boot time, serial number, hardware UUID,
every visible storage volume with available and total space, and online
displays with resolution. They are read with `system_profiler`, IOKit, and
volume information when the page opens; use its refresh button to read them
again. The serial number and hardware UUID identify your Mac, so they stay
masked until you choose **Show**; **Copy** places one on the clipboard. They are
never stored.

**Battery** shows charge, charging state, power source, reported condition,
cycle count, applicable time estimates, and Low Power Mode when macOS exposes
them. A desktop's verified lack of an internal battery is distinct from a
failed read or an attached UPS. Missing counters remain N/A.

**Thermal** shows macOS's Normal, Warm, High, or Critical thermal-pressure
assessment with a textual explanation. These states are not temperatures;
KillSwitch does not invent sensor readings or fan speeds.

One shared health monitor uses supported public interfaces at most every thirty
seconds while one of these pages or Dashboard is visible. No privileged helper,
temperature sensor, or additional background recording is involved. Health
details are live, not persisted.

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

## Homebrew

**Homebrew** under **Manage** lists installed formulae and casks with their
versions (`installed → latest` when an upgrade exists), one status badge, and
actions. KillSwitch looks for `brew`
in `/opt/homebrew/bin` and `/usr/local/bin`. If neither exists, the page stays
empty: KillSwitch never installs, repairs, or configures Homebrew.

- **Upgrade** upgrades one outdated formula or cask; **Upgrade all** upgrades
  every outdated package that KillSwitch may upgrade, after confirmation.
- Self-updating casks (`auto_updates`) are always skipped, even when Homebrew
  lists them as outdated; they show **Updates itself**. Unversioned (`latest`)
  casks and pinned packages are skipped too. KillSwitch names each package it
  upgrades, so a greedy Homebrew setting cannot include skipped casks.
- **Uninstall** runs `brew uninstall` after confirmation, without `--force`,
  `--zap`, or `--ignore-dependencies`. Homebrew refuses to remove a formula that
  another package needs. A cask uninstall removes its app but keeps its settings.
- Casks whose apps are running show **Running** and are skipped by **Upgrade**
  and **Upgrade all**; quit the app, then upgrade. KillSwitch checks again
  before each cask, and skips every cask if running apps cannot be listed.
- **Check for updates** runs `brew update`; the refresh button relists packages.

Every action runs `brew` in the background as your user, one at a time, with
`HOMEBREW_NO_AUTO_UPDATE` set so upgrades act on the versions shown. The last
command's output appears on the page; failures are shown with Homebrew's error.
Casks whose installers ask for an administrator password cannot finish from
KillSwitch; run those in Terminal. Filter by **Outdated**, **Formulae**, or
**Casks**, or search with fields such as `outdated = yes`.

## Disk cleanup

- Opens on **Largest files**, sorted by occupied disk space. Switch to
  **Temporary**, **Caches**, **Large folders**, or [**Maintenance**](#maintenance).
- Browse with breadcrumbs, filter by name or path, reveal items in Finder, and
  select one or more candidates.
- Sort by item, contents, modification date, or space used; the Sort picker
  also offers path and type. Numeric filters use bytes, not formatted size text.
- Storage mapping reads folders in parallel across CPU cores, so trees with
  many subfolders finish much faster than a one-folder-at-a-time scan.
- Scans continue across tab, category, or folder changes. Completed locations
  are cached; **Rescan** applies added, updated, and removed items without
  clearing visible rows first.
- Every removal requires confirmation and moves items to macOS Trash.
  Only **Empty Trash** and **Remove worktree** in Maintenance delete permanently,
  each after its own confirmation.
- Standard home folders such as Documents, Downloads, Pictures, and Movies
  must be opened before their contents can be selected. Cleanup roots,
  `~/Library` outside the designated cleanup areas, and hidden home
  configuration are protected.
- iCloud-synced items are excluded because moving them to Trash can remove
  data from every synced device.
- Partial scans report permission problems and link to **Full Disk Access**.
  Desktop, Documents, Downloads, and other protected locations may need access.
  Updating an ad-hoc-signed app or binary may require granting it again.

### Maintenance

**Maintenance** collects the disk steps of a periodic Mac cleanup. Each card
shows its actions in the header and a one-line summary; hover the info icon for
details. Each card scans first, lists what it would move with reasons for
anything kept, and asks before acting. Everything moves to the Trash unless
stated otherwise.

- **Merged PR artifacts:** **Preview** finds generated installers (`.dmg`,
  `.pkg`, app installer `.zip`/`.tar.gz`), staged apps in packaging folders, and
  ignored `node_modules`, `dist`, `dist-electron`, `target`, CMake `build`,
  `coverage`, and `test-results` folders in agent sessions and worktrees whose
  pull request is merged. GitHub is read with your existing `gh` login; a
  closed-but-unmerged PR is not eligible. A worktree must be clean, idle, and
  at the merged PR's head commit. Running, recently active, or unreadable
  sessions, open files, and Git metadata, tracked files, or local
  configuration are protected. **Move to Trash** rechecks every item first.
  Read-only installer images that are mounted and unused are ejected normally;
  busy images stay mounted.
- **Run automatically** (off by default) repeats the merged-artifact cleanup
  every 1, 6, 12, or 24 hours while KillSwitch runs, without asking. Turning it
  off stops an automatic run that is in progress before its next move.
- **Need your approval** lists whole worktrees and sessions whose PRs are
  merged. Sessions are never removed. **Remove…** on a worktree runs
  `git worktree remove` without `--force`, after a fresh check; Git refuses
  worktrees with changes or untracked files. This deletes the folder, including
  its ignored files, and keeps the branch.
- **Archives in agent worktrees:** untracked archives idle for the chosen hours
  (24 by default) and not open.
- **Installed disk images:** DMGs at the top level of `~/Downloads` and
  `~/Desktop` whose apps are already installed at the same or a newer version.
  Nothing else in those folders is opened or moved.
- **Idle build output:** ignored `target`, `node_modules`, and `build` folders
  in clean checkouts under the repository roots, unused for the chosen days
  (14 by default).
- **Tool caches:** clears Homebrew, Go, npm, uv, pnpm, Yarn, pip, Playwright,
  and Cargo caches with each tool's own command. A cache is kept while a
  program that uses it runs.
- **Trash:** counts items and empties the Trash through Finder after a separate
  confirmation. This deletes everything there, including items you moved
  yourself. Finder may ask for Automation permission.
- **Empty automatically** (off by default, confirmed when turned on) empties the
  whole Trash daily, weekly (default), or every 30 days, without asking. The
  first automatic empty is one interval after you turn it on, and the card shows
  the next one. If KillSwitch was closed when it was due, it runs within about
  15 minutes of KillSwitch starting. A failed run, for example without Finder
  Automation permission, is retried at the next interval. Turning it off stops
  a pending run. Finder's own settings can instead remove items after 30 days.
- **Last 24 hours** shows run counts, space moved and freed, and errors. Only
  counts and sizes are kept, for 24 hours.
- **Settings** (collapsed, with a one-line summary) holds the roots and idle
  times. Agent session and worktree roots default to
  `~/.copilot/session-state` and `~/workspace/copilot-worktrees`; repository
  roots default to existing `~/Projects`, `~/workspace`, `~/Developer`, `~/src`,
  and `~/code`. Add or remove roots inside your home folder; `~/Downloads`,
  `~/Library`, and the Trash are refused. **Reset to defaults** restores them.
  Roots are checked again at every scan, so a root that later links into a
  refused location is skipped. Changing roots discards earlier previews and
  scans.

Every merged-artifact run appends paths, sizes, PRs, protected and skipped
reasons, and errors to `~/.copilot/logs/merged-artifact-cleanup.jsonl`. The log
rotates at 5 MB and keeps two older copies. Repository pulls are not part of
Maintenance.

## Folder size alerts

**Folder alerts** measures folders you choose and alerts you when one reaches
its own size limit.

- Choose **Add folder…** and select one or more folders. Each starts with a
  10 GB limit and monitoring on. Links resolve to their target folder, and a
  folder can be watched only once.
- Edit **Alert at** with a number and MB, GB, or TB, then press Return or
  **Save**. Units are 1,024-based, matching the sizes KillSwitch displays.
  Saving a new limit re-arms the alert and measures the folder again.
- The switch pauses or resumes one folder. **Reveal in Finder** opens it, and
  the remove button stops watching it without changing its files.
- Folders are measured at launch, when added, resumed, or given a new limit,
  with **Check now**, and at the selected interval.

| Setting | Default | Choices |
| --- | --- | --- |
| Alert limit | 10 GB per folder | 1 MB through 1024 TB, entered in MB, GB, or TB with up to two decimals |
| Check every | 15 minutes | 1/5/10/15/30/60 minutes |
| Monitoring | On for new folders | Per-folder switch |

When a folder reaches its limit, KillSwitch posts a macOS notification titled
**Folder size alert**, shows a banner above every page, marks the folder
**Limit reached**, and adds it to **Recent alerts**. Choose **Review**, dismiss
the banner, or open Folder alerts to acknowledge it. Recent alerts keep the
last 50 alerts for the current app session. If macOS does not deliver the
notification, the page reports it and the in-app alert remains.

A folder alerts once each time it reaches its limit. It alerts again only after
a complete measurement falls below 95% of the limit, so a folder hovering at
the limit does not alert on every check. Changing the limit re-arms it.

Sizes add up the allocated space of every file, including hidden files and
package contents, like `du`. Symbolic links are not followed, and hard-linked
files count once. When some contents cannot be read, the size is shown as a
lower bound (`≥`); it can still trigger an alert but never re-arms one, and the
folder shows **Incomplete** rather than **Below limit**. A folder that cannot be
read at all is reported as unavailable, not as 0 bytes. When a later check
fails, the folder shows **Check failed** with the error and keeps its last
successful size for reference. Changing a limit while a folder is being measured
discards that measurement and starts a new one.
Desktop, Documents, Downloads, and other protected locations may need
**Full Disk Access**; the page links to its settings whenever a watched folder
or something inside one is denied.

Folders, limits, alert state, and the interval persist across launches.
Folders are measured one at a time at background priority, so very large
folders can take a while. Monitoring stops when KillSwitch quits.

## Dev cleanup

**Auto-kill is enabled by default.** Selecting the sidebar page first shows a
safe preview while automatic termination is enabled. **Open Dev cleanup**
explicitly asks for confirmation; confirming immediately runs a cleanup,
which can terminate qualifying servers older than the saved age. Age is total
process lifetime, not inactivity; a busy server can qualify.
Use **Dev servers** for read-only discovery: it lists the same detected dev
servers without a confirmation or cleanup pass. If you cannot risk that first
cleanup pass, cancel the entry confirmation. The CLI
[status command](cli.md#read-saved-status) reads settings without running cleanup.

Canceling leaves the safe preview shown; it does not reset sidebar selection or
reopen the modal when navigating with arrow keys. Other pages remain reachable
without authorizing cleanup.
The preview retains cleanup filters and prior session results. After confirming
entry, automatic cleanup keeps running at the saved interval while **Dev cleanup
is selected**, including hidden, minimized, or fully covered windows. Showing the
window again does not require another confirmation or restart the cleanup
deadline. Foreground port polling pauses while hidden and refreshes on return.

Leaving this page revokes execution authorization and cancels not-yet-started
passes; returning then requires fresh confirmation while auto-kill is enabled.
Disabling auto-kill revokes termination permission immediately. Hidden read-only
cleanup stops its timers and resumes on return, including rapid visibility and
navigation changes. Sleep and quitting stop execution; this feature does not
keep the Mac awake.
An already-started authorized pass can finish; its outcome remains available on
return. Queued scans and cleanup passes reread saved settings before starting,
so later saved filters apply and disablement still prevents automatic termination.
Entry, reset, and enable confirmations belong to both their UI visit and
individual request. Hiding still invalidates pending dialogs and stale UI
callbacks without revoking an already-confirmed background session. Canceling
or replacing a dialog invalidates its old callback without canceling a newer
request.

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
candidate and termination counts. **Reset to defaults** first asks for explicit
confirmation. Confirming **Reset and enable auto-kill** restores all values,
clears synced integration ports, re-enables automatic termination, and
immediately runs cleanup. Canceling changes nothing. Re-enabling the auto-kill
switch also requires confirmation; disabling it takes effect immediately.
Changing settings alone never authorizes a read-only visit to terminate
processes. Integration ports remain cleared until that integration syncs again.

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

## Applications

**Applications** under **Your Mac** lists the app bundles in `/Applications` and
`~/Applications`, including subfolders up to three levels deep, with their name,
bundle identifier, version, and modification date. Built-in apps in
`/System/Applications` are not listed.

- **Homebrew** marks apps installed by a Homebrew cask, with the cask name.
- **Signature** shows Gatekeeper's assessment from `spctl --assess`:
  **Notarized**, **App Store**, **Apple**, **Local**, or **Unverified**.
  **Local** means the app is not notarized: Gatekeeper rejected it, or it is
  signed with a Developer ID but not notarized. Ad-hoc builds, including
  KillSwitch itself, are local. **Unverified** means Gatekeeper could not assess
  it, for example because assessments are disabled.

Use **Homebrew**, **Not Homebrew**, or **Local** to filter, or search fields such
as `local = yes` and `homebrew = no`. Assessments run in small parallel batches
when the page first opens. The refresh button scans and assesses every app
again. The page is read-only; **Reveal in Finder** shows an app.

## Security

**Security** under **Your Mac** reads, without administrator access:

- **Protections:** FileVault, the firewall and its stealth mode, Gatekeeper,
  System Integrity Protection, the active XProtect definitions version (from
  `xprotect version` on macOS 15 and later, otherwise the XProtect bundle), and whether
  security responses install automatically. A protection that is off is
  highlighted; stealth mode is informational. An unrecognized or failed read is
  shown as Unknown with the raw output, never assumed.
- **macOS updates:** opening the page lists the updates found by macOS's most
  recent Software Update scan (`softwareupdate --list --no-scan`). **Scan now**
  contacts Apple and can take minutes. Security responses, updates within your
  installed macOS major version, and Safari updates are highlighted as security
  updates because Apple ships security fixes in them; major upgrades and other
  software are listed without highlighting. **Open Software Update** opens
  System Settings to install them; KillSwitch does not install macOS updates.
- **Homebrew packages:** every outdated package, because Homebrew does not label
  which upgrades fix vulnerabilities. Upgrade them from the Homebrew page.

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
- Homebrew upgrades and uninstalls run `brew` as your user and cannot be
  undone by KillSwitch. Review the confirmation; self-updating and running
  casks are never upgraded.
- Maintenance moves only verified generated files to the Trash and fails closed
  when activity, ownership, or PR state cannot be confirmed. Emptying the Trash,
  including automatic emptying, and removing a worktree are permanent.
- Applications, Security, Destinations, and System details are read-only.
  KillSwitch does not change security settings or install macOS updates.
- Monitoring and keep-awake sessions stop when the app quits.
