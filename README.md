# Third Party Patcher

Third Party Patcher (TPP) is a macOS daemon-based patching system for IT administrators. It automatically discovers installed third-party applications, checks for available updates, downloads installers in the background, and applies them — with optional user-facing prompts via [swiftDialog](https://github.com/swiftDialog/swiftDialog) so users stay informed without being blocked.

Updates are driven by [Installomator](https://github.com/Installomator/Installomator) label files, which Third Party Patcher downloads and keeps current automatically. Custom and override labels can be supplied by the IT team without modifying the Installomator project.

---

## How It Works

Patching is divided into four phases, each on its own configurable schedule:

| Phase | What it does |
|-------|-------------|
| **Scan** | Discovers installed apps by evaluating Installomator labels |
| **Check** | Looks up available versions and marks apps that need updating |
| **Stage** | Downloads and validates installers in the background |
| **Apply** | Installs staged updates; prompts the user if a blocking process is running |

A `LaunchDaemon` wakes `patcherscheduler` every 10 minutes. Each wake is cheap — it exits in milliseconds when nothing is due.

---

## Binaries

Three command-line tools are installed to `/usr/local/bin/tpp/`:

| Binary | Purpose |
|--------|---------|
| `patcher` | Runs individual patching phases on demand |
| `patcherscheduler` | Daemon entrypoint; also provides a `status` subcommand |
| `patcherreport` | Generates patch compliance reports |

---

## Requirements

- macOS 14 Ventura or later
- [swiftDialog](https://github.com/swiftDialog/swiftDialog) (for user prompts; install via `patcher ensure`)
- Network access to GitHub (for Installomator label updates and app downloads)

---

## Installation

Deploy the signed and notarized `.pkg` via your MDM. The package installs the three binaries, the LaunchDaemon plist, and loads the daemon immediately.

See the **[Installation wiki page](../../wiki/Installation)** for full details, prerequisites, and uninstall instructions.

---

## Configuration

All settings are managed through the `com.gilburns.patcher` preference domain, deployable as an MDM configuration profile.

```
/Library/Managed Preferences/com.gilburns.patcher.plist   ← MDM (preferred)
/Library/Preferences/com.gilburns.patcher.plist           ← local override
```

See the **[Preference Keys wiki page](../../wiki/Preference-Keys)** for a full reference of every available key.

> **Migrating from App Auto-Patch?** Preference key names are largely compatible. The main difference is that Third Party Patcher uses native plist booleans (`<true/>`/`<false/>`) rather than strings (`<string>TRUE</string>`). See the [compatibility note](../../wiki/Preference-Keys#compatibility-with-app-auto-patch) for details.

---

## Managed Labels

You can supply your own Installomator-compatible `.sh` label files to override existing labels or add support for internal applications not in the public Installomator repository.

```
/Library/Application Support/Patcher/Managed/Labels/   ← your label files
/Library/Application Support/Patcher/Managed/Version.txt
```

See the **[Managed Labels wiki page](../../wiki/Managed-Labels)** for the full guide.

---

## Wiki

Full IT-admin documentation is available in the [project wiki](../../wiki):

- [Installation](../../wiki/Installation)
- [How It Works](../../wiki/How-It-Works)
- [Scheduling](../../wiki/Scheduling)
- [Command-Line Reference](../../wiki/Command-Line-Reference)
- [Preference Keys](../../wiki/Preference-Keys)
- [Installomator Integration](../../wiki/Installomator-Integration)
- [Managed Labels](../../wiki/Managed-Labels)
- [Deferral and Deadlines](../../wiki/Deferral-and-Deadlines)
- [User Prompts](../../wiki/User-Prompts)
- [Reporting](../../wiki/Reporting)
- [Logs and Troubleshooting](../../wiki/Logs-and-Troubleshooting)
- [Contributing](../../wiki/Contributing)

---

## License

Third Party Patcher is released under the [MIT License](LICENSE).
