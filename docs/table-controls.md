# Sorting and filtering

[Documentation index](README.md) | [Usage](usage.md)

Dashboard, Resources, Open files, Connections, Startup, Disk cleanup, Dev cleanup,
and Watchdog share sorting and filter controls. These controls affect displayed
rows only. They do not change monitoring, automatic cleanup, startup state,
process protection, or saved history.

## Sort a table

Click a data-column header to sort it; click it again to reverse the direction.
The **Sort** picker provides the same choice, including for the dev-server,
cleanup-history, offender, and alert lists that do not have column headers.
The direction button shows **A-Z / Z-A**, **Low-high / High-low**,
**Old-new / New-old**, or **No-yes / Yes-no**, depending on the field.

Numbers sort by their underlying value, not their formatted text: 2 is smaller
than 10, and 900 MB is smaller than 1 GB. Text uses natural alphabetical ordering.
Unavailable values stay last in both directions. Selection and action columns
are not sortable.

## Apply and reset filters

Type into search to filter immediately. Plain words search readable field
values; use double quotes to keep a phrase together. Separate terms and
comparisons combine with **AND**.

Choose **Filter** to build a comparison without memorizing field syntax:
select a field, comparison, and value, then choose **Apply**. Where available,
the **Values** menu offers predefined values; the value remains editable.
Apply appends the comparison to the current search.

**Reset filters** clears free text and comparison expressions and restores any
inline type, state, or reported-lock filters. Process tables return to
**My processes**. Reset does not change the selected sort, resource mode, cleanup
category, settings, or disk selections.

Inline filters and search comparisons apply together. Conflicting filters can
produce no rows; reset them to start again. Invalid expressions display an
explanation and no matching rows rather than ignoring part of the expression.

Disk selections survive filtering. Review the selected count and confirmation
before moving items to Trash. Reset filters is separate from Dev cleanup's
**Reset to defaults**, which changes cleanup settings and can run cleanup.
Watchdog filtering does not stop monitoring or notifications for hidden rows.

## Search expressions

Field names are case-insensitive. Use a short field name or the column name,
such as `cpu`, `CPU%`, `size`, `pid`, or `CPU time`.

| Expression | Where it applies |
| --- | --- |
| `CPU% > 40 memory >= 1GB` | Dashboard and resource processes |
| `threads >= 20 user:example` | Resource processes |
| `process:"Example worker" pid >= 100` | Open files and connections |
| `type = REG size > 1MB locked = yes` | Open files |
| `protocol = TCP port >= 8000 state = LISTEN` | Connections |
| `remotePort > 10000` | Connections with a remote IP port |
| `state = Enabled type = "Launch agents"` | Startup |
| `readOnly = no` | Startup entries with supported controls |
| `type = File size > 1GB` | Disk cleanup |
| `modified < 2026-01-01 removable = yes` | Disk cleanup |
| `port >= 8000 protected = no` | Running dev servers and ports |
| `age > 12h runtime:example` | Cleanup records; age is recorded at cleanup |
| `CPU% > 95 checks >= 3` | Watchdog offenders or alerts |
| `date >= 2026-01-01` | Watchdog alerts |

Use `=`, `==`, `!=`, `>`, `>=`, `<`, or `<=` for comparisons. Text `=` compares
the whole value without case sensitivity; `:` means case-insensitive
**contains**. Boolean fields accept `Yes`, `No`, `true`, `false`, `1`, or `0`
with `=` or `!=`.

Sizes accept bytes or `KB`, `MB`, `GB`, `TB`, `PB`, and `EB`, including their
`KiB`/`MiB` equivalents. Units use 1,024-byte steps, matching the app's counters.
Rates accept units such as `MB/s`. Durations use seconds by default or `ms`,
`s`, `m`, `h`, and `d`. Percentages accept an optional `%`; per-process CPU can
exceed 100%.

Dates accept `YYYY-MM-DD` or an ISO 8601 timestamp. Date-only thresholds use
midnight UTC; a timestamp can specify its timezone. Unknown measurements and
unavailable ports never become zero and do not satisfy numeric comparisons,
including `!=`.

IPv6 addresses such as `::1` and endpoints such as `127.0.0.1:9000` remain plain
search text. Quote literal comparison characters, for example `"CPU > 40"`.
Inside a quoted value, use `\"` for a quote and `\\` for a backslash; the filter
builder escapes text values automatically.

The **Find process** history search accepts name, PID, and user expressions,
such as `pid > 100 user:example`, including exited processes. It does not claim
current CPU or memory values for historical descriptors. Its clear button
resets that search without changing the selected history.
