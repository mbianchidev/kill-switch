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
| Memory | Physical footprint, threads, open files, PID, user | Memory pressure, physical/app/cached/wired/compressed memory, swap |
| Energy | Current and rolling power, sleep prevention, PID, user | Total impact and battery/power-source status |
| Disk | Lifetime bytes read and written | Free/occupied capacity, read/write operations, totals, and live rates |
| Network | Bytes and packets sent/received | Inbound/outbound totals and rates |

Live graphs retain five minutes of history. CPU, memory, disk, and network
sample every **6 seconds**; Energy samples every **15 seconds** because its
power collector is heavier. Heavyweight collectors run only for the selected
metric. Sampling continues with the window hidden if Resources is selected;
leaving the tab stops it.

KillSwitch uses supported macOS interfaces where available: `top`, Mach VM
statistics, `libproc`, IOKit storage statistics, `nettop`, `netstat`,
`memory_pressure`, and `pmset`.

macOS denies some `libproc` data for protected or other-user processes. Those
rows remain visible in **All processes**, but restricted disk or architecture
fields show a dash. Per-process GPU and App Nap counters are also not exposed by a
supported public interface, so KillSwitch does not invent values for them.
The **All processes** scope does not grant administrator privileges.

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
