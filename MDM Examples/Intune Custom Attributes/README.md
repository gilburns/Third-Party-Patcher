# Intune Custom Attributes (macOS)

Ready-to-use **Custom Attribute** shell scripts that pull Third Party Patcher
status into Microsoft Intune device inventory. Each script shells out to
`patcherreport` — mostly its `get` subcommand — and prints a single value.

These are the Intune equivalents of the scripts in
[`../Jamf Extension Attributes/`](../Jamf%20Extension%20Attributes/). The only
differences: the output is the bare value (no `<result>` wrapper), and Date
attributes are emitted in ISO-8601, which is what Intune expects.

No `jq`, `python3`, or other add-ons are required.

## Included scripts

| Script | Attribute name | Data type | What it reports |
|--------|----------------|-----------|----------------|
| `tpp-last-scan.sh` | TPP - Last Scan | Date | Last full Installomator scan (ISO-8601, UTC) |
| `tpp-last-apply.sh` | TPP - Last Apply | Date | Last apply/install pass (ISO-8601, UTC) |
| `tpp-apps-requiring-update.sh` | TPP - Apps Requiring Update | Integer | Managed apps found out of date |
| `tpp-pending-updates.sh` | TPP - Pending Updates | Integer | Updates staged and awaiting apply |
| `tpp-oldest-pending-days.sh` | TPP - Oldest Pending Update (Days) | Integer | Age of the oldest staged update |
| `tpp-days-until-hard-deadline.sh` | TPP - Days Until Hard Deadline | Integer | Days left before deferrals are cut off |
| `tpp-broken-labels.sh` | TPP - Broken Labels | Integer | Scan-broken + stage-broken labels |
| `tpp-deferrals-30-days.sh` | TPP - Deferrals (Last 30 Days) | Integer | Dialog deferrals in the last 30 days |
| `tpp-deadlines-forced.sh` | TPP - Deadlines Forced (Lifetime) | Integer | Times a hard deadline forced an install |
| `tpp-patching-mode.sh` | TPP - Patching Mode | String | `monthly` or `deadline` |
| `tpp-pending-update-labels.sh` | TPP - Pending Update Labels | String | Comma-separated list of staged labels |
| `tpp-patch-compliance-status.sh` | TPP - Patch Compliance Status | String | Rollup verdict (see below) |

### Compliance status values

`tpp-patch-compliance-status.sh` returns one of:

| Value | Meaning |
|-------|---------|
| `Not Installed` | `patcherreport` is not present on the device |
| `Overdue` | A hard deadline has been reached |
| `Deadline Approaching` | Updates pending, hard deadline within 3 days |
| `Pending` | Updates staged, deadline not yet close |
| `Updates Detected` | Updates found but nothing staged yet |
| `Compliant` | Nothing outstanding |

## Adding a Custom Attribute to Intune

1. In the [Intune admin center](https://intune.microsoft.com): **Devices ▸ macOS ▸
   Custom attributes ▸ Add** (also reachable via *Manage devices ▸ Scripts and
   remediations ▸ Platform scripts* on older tenants).
2. **Basics** — give it a name (e.g. *TPP - Pending Updates*) and description.
3. **Attributes** — choose the **Data type** from the table above and upload the
   matching `.sh` file.
4. **Scope tags** / **Assignments** — assign to the device groups you want.
5. Save. Results appear per device under **Devices ▸ \<device\> ▸ Custom
   attributes**, and can be exported or used in reporting.

## Notes

- **Run cadence is fixed.** Intune runs custom-attribute scripts about every
  **8 hours**; there is no way to shorten it. Values are only as current as the
  last run.
- **Runs as root.** `patcherreport` only reads state files, but the scripts run
  as root under Intune anyway.
- **Binary path.** Scripts call `/usr/local/bin/tpp/patcherreport`. If you deploy
  the dev build (`/usr/local/bin/tpp_dev/`), adjust the `patcherreport=` line.
- **Dates.** Intune Date attributes must be ISO-8601; the date scripts pass
  `patcherreport`'s output straight through (`2026-08-29T10:31:48Z`). Do not
  reformat them.
- **Empty output.** When a value isn't available (tool not installed, no active
  deadline, never applied) the script prints an empty line. Integer scripts print
  `0` instead where a zero is meaningful.
- **Shell.** Scripts target `/bin/bash`, which is present on all supported macOS
  releases.

## Building your own

`patcherreport get <dotted.key> [--from summary|pending|deferrals|broken|deadline]`
prints any single scalar from the JSON payloads with no quoting or wrapping:

```bash
patcherreport get labelsNeverUpdated
patcherreport get lastCheck.lastRun
patcherreport get deadline.hardDeadlineReached
patcherreport get totals.user --from deferrals --days 14
```

See the [Reporting wiki page](https://github.com/gilburns/Third-Party-Patcher/wiki/Reporting)
for the full list of keys.
