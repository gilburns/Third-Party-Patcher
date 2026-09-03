# Jamf Pro Extension Attributes

Ready-to-use Extension Attribute (EA) scripts that pull Third Party Patcher status
into Jamf Pro inventory. Each script shells out to `patcherreport` — mostly its
`get` subcommand — and echoes a single `<result>` value.

No `jq`, `python3`, or other add-ons are required; the scripts use only tools
present on a stock macOS install.

## Included scripts

| Script | EA display name | Data type | What it reports |
|--------|-----------------|-----------|----------------|
| `tpp-last-scan.sh` | TPP - Last Scan | Date | Last full Installomator scan (UTC) |
| `tpp-last-apply.sh` | TPP - Last Apply | Date | Last apply/install pass (UTC) |
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

## Adding an EA to Jamf Pro

1. **Settings ▸ Computer Management ▸ Extension Attributes ▸ New**
2. **Display Name:** use the name from the table above (the `TPP -` prefix keeps
   them grouped).
3. **Data Type:** match the table.
4. **Input Type:** Script — paste the script contents.
5. Save. Values populate on each device's next inventory submission (`jamf recon`).

## Notes

- **Binary path.** Scripts call `/usr/local/bin/tpp/patcherreport`. If you deploy
  the dev build (`/usr/local/bin/tpp_dev/`), adjust the `patcherreport=` line.
- **No root required.** `patcherreport` only reads state files, but EA scripts run
  as root under Jamf anyway.
- **Dates are UTC.** Jamf stores EA dates as `YYYY-MM-DD hh:mm:ss` in UTC; the
  date scripts convert `patcherreport`'s ISO-8601 output accordingly.
- **Freshness.** These values are only as current as the last inventory. Pair a
  scan/apply-heavy smart group with a shorter recon interval if you need tighter
  reporting.

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
