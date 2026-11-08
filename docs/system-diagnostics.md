# Resources and system diagnostics

[Documentation index](README.md) | [Usage and configuration](usage.md)

## Resources

The resource pages under **Performance** default to the logged-in user's processes. Select
**All processes** to include root, service accounts, and other users.
Filter by process name, PID, user, or comparisons such as `CPU% > 40`, and sort
any data column in either direction. The [filter guide](table-controls.md)
covers numeric units, predefined values, and resetting filters.
Application icons and executable names appear where macOS exposes them.

| Mode | Process data | System graph and summary |
| --- | --- | --- |
| CPU | CPU, CPU time, threads, idle wakeups, architecture, PID, user | Stacked user/system CPU graph, idle load, process and thread counts |
| Memory | Physical footprint or resident-memory fallback, threads, open files, PID, user | Used-memory history, current memory pressure, physical/app/cached/wired/compressed memory, swap |
| Energy | Current and rolling power, sleep prevention, PID, user | Total impact and battery/power-source status |
| Disk | Lifetime bytes read and written | Free/occupied capacity, read/write operations, totals, and live rates |
| Network | Bytes and packets sent/received, with a shortcut to Connections | Inbound/outbound totals and rates |

One shared monitor samples CPU, memory, disk, and network every **6 seconds**
throughout the app's lifetime, including when another tab is selected or the
window is hidden. `nettop` and `netstat` therefore run continuously, not just
while Network is selected. Energy's heavier power/battery collection runs at
most once every **15 seconds**, only while Energy is visible, including actual
window visibility.
Visibility and page leases take effect immediately, including for already-queued
callbacks. Energy and memory-pressure phases recheck the current selection
before beginning; an optional phase already in progress can finish.
Power and sleep assertions retain separate read availability: never-read, failed, and
not-yet-observed process lifetimes remain unavailable rather than becoming
zero power or No. Each collector retains its error until its own retry succeeds,
including on six-second ticks that skip Energy collection. Sampling another mode
clears current power/assertion readings and starts a fresh read on returning to
Energy. Optional cached battery values are also cleared on suspension; unresolved
battery-reader errors remain until that reader succeeds. The energy summary
totals reported values and shows N/A when none are readable. Memory-pressure
queries run only while Memory is selected.

Graphs connect measured samples without smoothing. CPU shows separate stacked
system/user bands on a fixed **0-100%** global scale. Per-process CPU can exceed
100% because 100% represents one CPU core. Memory history uses bytes, not a
percentage of physical memory or the pressure counter. Disk and network use
separate labelled traces, with writes/sent
traffic dashed. Their y-axis labels share a readable **B/s, KB/s, MB/s, GB/s, or
TB/s** unit rather than scientific notation, using the same 1,024-byte steps as
the resource summaries. Energy uses relative impact **points (pts)**, not watts.
Throughput and energy scales start at zero and include the largest value in
the visible history. Legends identify the series; CPU/memory/disk/network
support five-minute, one-hour, six-hour, and 24-hour windows. Energy retains its
session-only five-minute graph.

Native per-process CPU counters from `proc_pid_rusage` are Mach absolute-time
ticks. KillSwitch converts them with `mach_timebase_info` before calculating CPU
seconds or percentages; treating them as nanoseconds understates Apple Silicon
usage. Older per-process CPU history recorded with the former conversion is not
retroactively recalibrated. Global CPU accounting is separate and unchanged.
Each I/O counter uses its own collection timestamp for rate calculations;
blocking energy queries do not turn steady traffic into alternating rates.

KillSwitch uses supported macOS interfaces where available: `top`, Mach VM
statistics, `libproc`, IOKit storage statistics, `nettop`, `netstat`,
`memory_pressure`, and `pmset` for sleep assertions. Battery/power information
uses the public IOKit power-source interface, without a `pmset -g batt`
subprocess.

macOS denies some `libproc` data for protected or other-user processes. Those
rows remain visible in **All processes**, but restricted disk or architecture
fields show a dash. Per-process GPU and App Nap counters are also not exposed by a
supported public interface, so KillSwitch does not invent values for them.
The **All processes** scope does not grant administrator privileges. GPU columns
that are always unavailable are not shown on the CPU page.

## Native system health

Dashboard Battery and Thermal shortcuts explicitly show collection before the
first health snapshot. Completed unavailable readings remain unavailable, not
perpetually collecting.

System, Battery, Thermal, and the dashboard share one visible-only health
reader. CPU/model/core, OS/kernel, uptime, and load information use public
`sysctl`, `ProcessInfo`, and `getloadavg` interfaces. The runtime card explicitly
labels `ProcessInfo.systemUptime` as awake time since restart, excluding sleep
rather than claiming total elapsed boot time. Power-source descriptions
come from IOKit; an optional readable `AppleSmartBattery` cycle counter remains
unavailable when not exposed. Native battery readings replace the former
Energy-only battery subprocess.

Energy and System Health share the same battery-status rules. A non-charging
battery supplying the Mac is discharging, even while its full-charge flag
remains set. A non-charging battery on AC or UPS power is not assumed to be
discharging, and missing charging flags stay unavailable.
Time-to-empty is retained only while the battery is actually supplying power;
AC/UPS charge holds do not display stale discharge estimates.

Thermal pressure uses `ProcessInfo.thermalState`, not private SMC temperature or
fan interfaces. Before the first health snapshot, the card shows that thermal
information is being collected; an unavailable state is shown only after a
completed read reports it. Low Power Mode comes from `ProcessInfo`. Automatic health reads
are at least thirty seconds apart after completion, including across page
changes and hiding/reopening; explicit Refresh reads on demand. Scheduled
polling stops when no relevant page is visible. An already-running read finishes
into the shared cache without starting another poll; a request still waiting on
the queue checks visibility before reading and is canceled without consuming a
polling interval. All IOKit objects/file
descriptors are released after a read. Failed fields and verified battery absence have
distinct presentations. These readings do not expand the persisted history or
collect identifying serial/UUID values.

Hardware architecture is detected at runtime for the Intel executable slice:
Rosetta still identifies an Apple Silicon Mac. An absent translation key
identifies native Intel; other unreadable translation states are reported
unavailable rather than silently identifying the wrong hardware.

## History and storage

Live history retains at most 51 six-second samples for five minutes. Manual
refreshes update the current six-second slot rather than retaining extra full
process lists; the latest measurement keeps its actual collection timestamp.
The history-process menu builds its choices only when opened and releases them
when closed. Search, exited-process selection, and native keyboard navigation
remain available without retaining a view for every historical process.
A process-lifetime catalog observes samples before they are coalesced, so
short-lived processes and their names remain selectable while measurements await
storage.
The shared monitor averages available measurements into one-minute buckets and
saves each completed bucket, plus the current partial bucket when quitting
normally. A crash can lose the unfinished minute. Recording does not continue while KillSwitch is
quit or the Mac is asleep.

History is held in macOS's built-in SQLite database at:

```text
~/Library/Application Support/KillSwitch/ActivityHistory/activity.sqlite
```

The directory is private (`0700`); the database and SQLite sidecars use `0600`.
Records older than 24 hours are pruned on startup and as new buckets are saved.
Exited, terminated, and defunct processes have a shorter window: their names and
all saved per-process measurements are deleted six hours after their exit is
first observed, or once their last verified sighting is older than 24 hours,
whichever comes first. Defunct processes no longer contribute live measurements.
Repeated observations and app restarts do not extend a recorded exit deadline.
If an exit happened while KillSwitch was closed, the last recorded sighting is
used only after a lifetime read confirms absence, a defunct state, or a verified
replacement sharing its PID. A readable matching lifetime stays live even if its
resource measurements are unavailable. Missing measurements and failed identity
reads do not confirm an exit: unresolved lifetimes remain in the menu across
retries, while already-confirmed exits continue to expire. This does not extend
the 24-hour window for stored measurements.
Running process histories and whole-Mac measurements keep the 24-hour window.
An expired process selection returns to **Entire Mac**. Pruning failures are
reported and retried; delayed pre-sleep writes cannot restore expired entries.
History includes measurements, process names, numeric PIDs, ownership, last-seen
and observed-exit times, and process-lifetime/boot identities. It does not record
network endpoints, open file paths, or process command-line arguments. Nothing is
uploaded.
**Clear history** removes saved records, buffered measurements, in-memory graph
data, and historical process names. It keeps only the descriptors of the last
displayed live sample, with their actual observation times, so those processes
remain selectable before the next sample. A live selection is preserved; a
historical selection returns to **Entire Mac**. Retaining those live descriptors
does not recreate any cleared measurements.
Lifetime identities use unprivileged `KERN_PROC_PID` information, including
other users' processes; restricted rusage counters remain unavailable rather
than excluding their readable PS memory and network history.

Global counters measure the whole Mac regardless of the process-table scope.
Per-process memory may use physical footprint or, where restricted, resident
memory; disk and network counters follow different kernel accounting paths
from system-wide totals. Do not expect sums of process rows to equal global
totals. First rate samples, regressed counters, and samples after long gaps are
unavailable, not zero. Missing readings and gaps over 90 seconds break graph
lines. Only processes with a readable lifetime identity receive persistent
per-process history.

Storage or collector failures appear in the UI and logs. A failed component
does not replace other available measurements with invented values. **Refresh**
retries unavailable history storage.
Failed writes are retried automatically and by **Refresh**. Up to five minutes
of unsaved minute buckets are retained in memory; longer storage outages display
a separate data-loss notice rather than growing memory without a bound.
That retry window starts when a completed bucket is queued, not when its
measurements were taken, so a healthy resume after sleep can still save the
pre-sleep bucket.

## Connections and open files

Darwin `lsof` can emit permission diagnostics in its NAME field instead of file
records. These are retained as errors, not counted as open files. A target with
only such diagnostics remains unavailable; readable records from a partial
inventory can still be displayed with the diagnostic warning.

Network connections have a dedicated **Connections** page, also linked from
Network traffic. Open files has a dedicated page. **Inspect** buttons on
processes, files, and listeners open a shared per-process files/connections
sheet without a second independent collector.
Both use `lsof`'s NUL-delimited field output, with numeric addresses/ports and
full command names. They refresh
every ten seconds only while visible. Queued refreshes check their activation
before collection, so hiding does not
start a delayed `lsof` read. Hiding releases the current rows immediately, and
an expired in-flight activation cannot publish its results.
Unresolved warning/error details remain available after suspension, but a new
visit or mode labels them **Previous inspection warning or error** while its
refresh is pending. A failed retry replaces them with the current error; a
successful warning-free read clears them.
Copy actions show brief confirmation, then restore their original label. A new
value or hidden button clears that feedback; it confirms a copy action, not
ongoing ownership of the system clipboard.
Names with spaces remain intact; control
characters use `lsof` display escapes. Plain search covers identifying text;
protocol, state, type, and measurement filters use explicit comparisons.
Numeric comparisons and sorting use underlying counters rather
than formatted strings. macOS can omit protected processes, files, and sockets;
short-lived connections between samples may be missed.

For a verified live target, a read exposing neither files nor connections is
reported as unavailable inspection data, not a successful empty inventory.
Successful global connection/listener queries can legitimately have no matches.

Filesystem metadata lookups use `lsof`'s two-second blocking-operation timeout.
Inspection no longer deliberately skips those lookups with `-b`, which generated
warnings for every mounted filesystem even when inspection succeeded.
Genuine timeout, permission, and collection warnings still appear in the panel.
Project discovery accepts detached Git IDs only as 40- or 64-byte ASCII
hexadecimal values. Malformed metadata remains an explicit discovery warning,
not an invented branch label.
Git reftable repositories retain their verified project directory but show an
explicit unsupported-branch warning instead of interpreting the compatibility
HEAD as the current branch.
Branch-metadata errors retain the discovered repository root, so nested working
directories still group under their project while the specific warning remains
visible.
Symbolic branch refs are validated before display; malformed components or
Git-forbidden characters produce a metadata warning instead of a branch label.

Open files includes ordinary files, directories, and Unix sockets, with file
descriptor, access, size, and reported lock information. Locks are best-effort
advisory information, not a complete audit of kernel/application locks. Viewing
an entry never releases its lock, closes its descriptor, or kills its process.

## Spindump

Choose **Diagnostics > Generate Spindump** to sample system call stacks for 10
seconds. macOS requests administrator authorization because live system-wide
spindump collection requires root access.

The complete text report is stored in:

```text
~/Downloads/KillSwitch Diagnostics/
```

KillSwitch previews the first 2 MB in the app. Use **Save** or **Reveal** to work
with the full report.

## System Diagnostics

Choose **Run System Diagnostics** to create a full `sysdiagnose` archive containing
logs, system state, a spindump, process data, storage details, and network status.
Collection can take several minutes and requests administrator authorization.

Available entry points:

- Diagnostics tab button
- **Diagnostics > Run System Diagnostics** app menu
- KillSwitch menu-bar menu
- **Shift-Command-D** while KillSwitch is active
- macOS global chord: **Control-Option-Shift-Command-Period**

The generated archive is stored under `~/Downloads/KillSwitch Diagnostics/` and
revealed in Finder when collection completes.

Both kinds of report can contain sensitive logs, paths, command lines, and
system state. Review and redact reports before sharing them. Do not collect
privileged diagnostics as a routine build or documentation check.
