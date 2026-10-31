# Resources and system diagnostics

[Documentation index](README.md) | [Usage and configuration](usage.md)

## Resources

The **Resources** tab defaults to the logged-in user's processes. Select
**All processes** to include root, service accounts, and other users.
Filter by process name, PID, or user and sort by the selected resource.
Application icons and executable names appear where macOS exposes them.

| Mode | Process data | System graph and summary |
| --- | --- | --- |
| CPU | CPU, CPU time, threads, idle wakeups, architecture, PID, user | Stacked user/system CPU graph, idle load, process and thread counts |
| Memory | Physical footprint or resident-memory fallback, threads, open files, PID, user | Used-memory history, current memory pressure, physical/app/cached/wired/compressed memory, swap |
| Energy | Current and rolling power, sleep prevention, PID, user | Total impact and battery/power-source status |
| Disk | Lifetime bytes read and written | Free/occupied capacity, read/write operations, totals, and live rates |
| Network | Bytes and packets sent/received, plus a connections panel | Inbound/outbound totals and rates |

One shared monitor samples CPU, memory, disk, and network every **6 seconds**
throughout the app's lifetime, including when another tab is selected or the
window is hidden. `nettop` and `netstat` therefore run continuously, not just
while Network is selected. Energy's heavier power/battery collection runs at
most once every **15 seconds**, only while Energy is visible. Memory-pressure
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
Each I/O counter uses its own collection timestamp for rate calculations;
blocking energy queries do not turn steady traffic into alternating rates.

KillSwitch uses supported macOS interfaces where available: `top`, Mach VM
statistics, `libproc`, IOKit storage statistics, `nettop`, `netstat`,
`memory_pressure`, and `pmset`.

macOS denies some `libproc` data for protected or other-user processes. Those
rows remain visible in **All processes**, but restricted disk or architecture
fields show a dash. Per-process GPU and App Nap counters are also not exposed by a
supported public interface, so KillSwitch does not invent values for them.
The **All processes** scope does not grant administrator privileges.

## History and storage

Live history retains at most 51 six-second samples for five minutes. Manual
refreshes update the current six-second slot rather than retaining extra full
process lists; the latest measurement keeps its actual collection timestamp.
The history-process menu builds its choices only when opened and releases them
when closed. Search, exited-process selection, and native keyboard navigation
remain available without retaining a view for every historical process.
Process choices include the current minute and pending writes, so short-lived
processes and their names remain selectable while measurements await storage.
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
History includes measurements, process names, numeric PIDs, ownership, and
process-lifetime/boot identities. It does not record network endpoints, open
file paths, or process command-line arguments. Nothing is uploaded.
**Clear history** removes the saved records and in-memory graph data.
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

The Network connections panel and Open files panel use `lsof`'s NUL-delimited
field output, with numeric addresses/ports and full command names. They refresh
every ten seconds only while visible. Names with spaces remain intact; control
characters use `lsof` display escapes. Search and sorting use the displayed
values. Protected processes, files, and sockets can be omitted by macOS, and
short-lived connections between samples may be missed.

Filesystem metadata lookups use `lsof`'s two-second blocking-operation timeout.
Inspection no longer deliberately skips those lookups with `-b`, which generated
warnings for every mounted filesystem even when inspection succeeded.
Genuine timeout, permission, and collection warnings still appear in the panel.

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
