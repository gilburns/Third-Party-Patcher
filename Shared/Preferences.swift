//
//  Preferences.swift
//  patcher
//
//  Created by Gil Burns on 4/4/26.
//

import Foundation

struct Preferences {
    
    private static let managedPrefsDomain = "com.gilburns.patcher.plist"
    
    private static let managedPrefsURL = FileManager.default
        .urls(for: .libraryDirectory, in: .localDomainMask).first!
        .appendingPathComponent("Managed Preferences")
        .appendingPathComponent(managedPrefsDomain)
    
    private static let localPrefsURL = FileManager.default
        .urls(for: .libraryDirectory, in: .localDomainMask).first!
        .appendingPathComponent("Preferences")
        .appending(component: managedPrefsDomain, directoryHint: .inferFromPath)

    private let prefs: [String: Any]

    /// Describes where the preferences were loaded from, for logging.
    let source: String

    /// For testing only — initialises directly from a dictionary without reading any plist.
    init(testPrefs: [String: Any]) {
        prefs  = testPrefs
        source = "test"
    }

    init() {
        let managed = NSDictionary(contentsOf: Preferences.managedPrefsURL) as? [String: Any]
        let local   = NSDictionary(contentsOf: Preferences.localPrefsURL)   as? [String: Any]

        switch (managed, local) {
        case (let m?, let l?):
            // Both present — merge with managed taking precedence on any shared key
            prefs  = l.merging(m) { _, managed in managed }
            source = "managed + local (managed takes precedence)"
        case (let m?, nil):
            prefs  = m
            source = "managed (\(Preferences.managedPrefsURL.path().removingPercentEncoding ?? ""))"
        case (nil, let l?):
            prefs  = l
            source = "local (\(Preferences.localPrefsURL.path().removingPercentEncoding ?? ""))"
        case (nil, nil):
            prefs  = [:]
            source = "none (using defaults)"
        }
    }

    // MARK: - Logging

    /// When true, low-signal verbose output is included in the log (per-label key dumps, etc.).
    /// Defaults to false.
    var logVerbose: Bool {
        prefs["LogVerbose"] as? Bool ?? false
    }

    // MARK: - App Handling

    /// Applications discovered in /Users/* are never updated and ignored if true.
    /// Applications discovered in /Users/* are always updated if false
    var ignoreAppsInHomeFolder: Bool {
        prefs["IgnoreAppsInHomeFolder"] as? Bool ?? false
    }

    /// Applications discovered only on external volumes (/Volumes/*) are ignored if true.
    var ignoreAppsOnExternalVolumes: Bool {
        prefs["IgnoreAppsOnExternalVolumes"] as? Bool ?? false
    }

    /// When true, applications discovered in /Users/* locations are relocated to /Applications.
    /// Items relocated to the /Applications are managed and the previous user managed app is deleted.
    /// If 'IgnoreAppsInHomeFolder' is set to 'true' this setting is also ignored.
    var convertAppsInHomeFolder: Bool {
        prefs["ConvertAppsInHomeFolder"] as? Bool ?? false
    }

    // MARK: - Installomator Repo Connections
    
    /// GitHub account hosting the Installomator repository. Defaults to "Installomator".
    var installomatorGitHubAccount: String {
        pref("InstallomatorGitHubAccount", default: "Installomator")
    }

    /// GitHub repository name for Installomator. Defaults to "Installomator".
    var installomatorGitHubRepo: String {
        pref("InstallomatorGitHubRepo", default: "Installomator")
    }

    /// Branch to pull Installomator labels from. Defaults to "main".
    var installomatorGitHubBranch: String {
        pref("InstallomatorGitHubBranch", default: "main")
    }

    // MARK: - Installomator Metadata Repo Connections

    /// GitHub account hosting the Installomator Metadata repository. Defaults to "Installomator".
    var installomatorGitHubMetadataAccount: String {
        pref("InstallomatorGitHubMetadataAccount", default: "gilburns")
    }

    /// GitHub repository name for Installomator Metadata. Defaults to "Installomator".
    var installomatorGitHubMetadataRepo: String {
        pref("InstallomatorGitHubMetadataRepo", default: "Installomator-Metadata")
    }

    /// Branch to pull Installomator Metadata from. Defaults to "main".
    var installomatorGitHubMetadataBranch: String {
        pref("InstallomatorGitHubMetadataBranch", default: "main")
    }

    // MARK: - Installomator Metadata Sync

    /// When true, patcherscheduler periodically checks the metadata repo for updates
    /// and syncs icons and metadata to a local cache. Defaults to true.
    var metadataSyncEnabled: Bool {
        prefs["MetadataSyncEnabled"] as? Bool ?? true
    }

    /// Days between checks for metadata repo updates. Defaults to 10.
    var metadataSyncIntervalDays: Int {
        prefs["MetadataSyncIntervalDays"] as? Int ?? 10
    }

    // MARK: - Installomator Handling
    /// When true, disables all Installomator label management: no initial download, no update checks,
    /// and Installomator labels are never used during scan/check/stage. Managed labels (if present)
    /// are the only source of labels. Defaults to false.
    var installomatorLabelsDisable: Bool {
        prefs["InstallomatorLabelsDisable"] as? Bool ?? false
    }

    /// When true, skips the routine Installomator label update check during a scan.
    /// Has no effect on the initial download when no labels are present locally.
    /// Ignored when InstallomatorLabelsDisable is true.
    var installomatorUpdateDisable: Bool {
        prefs["InstallomatorUpdateDisable"] as? Bool ?? false
    }
    
    
    /// Key determines if managed apps are detected and automatially added
    /// to the IgnoredLabels list
    /// Currently it looks for Microsoft Suite, Microsoft Edge, Google Suite and Google Chrome
    /// Default is true. Set to false to manage the list yourself
    var ignoreManagedApps: Bool {
        prefs["IgnoreManagedApps"] as? Bool ?? true
    }
    
    /// Space-separated list of label name patterns to ignore during a scan.
    /// Supports `*` and `?` wildcards (e.g. `"google* microsoft*"`).
    var ignoredLabels: [String] {
        guard let value = prefs["IgnoredLabels"] as? String else { return [] }
        return value.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    /// When true, non-production label variants (labels whose name ends with one of
    /// `NonProductionLabelSuffixes`) are automatically added to the ignored list, but only
    /// when a production label of the same base name also exists.
    /// E.g. with the default suffixes, "microsoftedgebeta" and "microsoftedgedev" are ignored
    /// because "microsoftedge" also exists as a label; a label like "figma" with no
    /// suffix is untouched, and a hypothetical "somethingbeta" is left alone if "something"
    /// does not also exist as a label.
    /// Default is true. Set to false to manage non-production labels yourself via IgnoredLabels.
    var ignoreNonProductionLabels: Bool {
        prefs["IgnoreNonProductionLabels"] as? Bool ?? true
    }

    /// Space-separated list of suffixes that mark a label as a non-production variant of a
    /// base label (e.g. "beta canary dev"). Only used when IgnoreNonProductionLabels is true.
    /// Defaults to "beta canary dev".
    var nonProductionLabelSuffixes: [String] {
        let value = prefs["NonProductionLabelSuffixes"] as? String ?? "beta canary dev"
        return value.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    /// Space-separated list of label name patterns that are required.
    /// Does NOT Support `*` and `?` wildcards (e.g. `"google* microsoft*"`).
    var requiredLabels: [String] {
        guard let value = prefs["RequiredLabels"] as? String else { return [] }
        return value.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    /// Space-separated list of Installomator label names approved for self-service
    /// installation via Available Software catalog. Does not support wildcards.
    /// The default sort order of labels in the App Catalog matches the order you supply here.
    /// This allows you to prioritize featured labels to the start of the list.
    /// Example: "microsoftword zoom slack"
    var optionalLabels: [String] {
        guard let value = prefs["OptionalLabels"] as? String else { return [] }
        return value.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }
    
    /// When true, labels that produce no appNewVersion value are skipped entirely during staging.
    /// Defaults to false.
    var ignoreUnknownVersionLabels: Bool {
        prefs["IgnoreUnknownVersionLabels"] as? Bool ?? false
    }

    /// Number of days to wait before re-downloading an unknown-version label that was last
    /// checked and found up to date. Only applies when IgnoreUnknownVersionLabels is false.
    /// Defaults to 7.
    var unknownVersionCheckIntervalDays: Int {
        prefs["UnknownVersionCheckIntervalDays"] as? Int ?? 7
    }

    /// Number of days to wait before re-downloading a label whose script-reported version
    /// did not match the actual downloaded file (e.g. Spotify reporting a future version).
    /// The throttle is invalidated automatically when appNewVersion changes.
    /// Defaults to 7.
    var versionMismatchThrottleDays: Int {
        prefs["VersionMismatchThrottleDays"] as? Int ?? 7
    }

    // MARK: - Download Handling

    /// Maximum download speed for staged downloads, in curl --limit-rate format.
    /// Examples: "500K" (500 KB/s), "2M" (2 MB/s), "1G" (1 GB/s).
    /// Empty or absent means no bandwidth limit. Defaults to no limit.
    var downloadBandwidthLimit: String? {
        guard let value = prefs["DownloadBandwidthLimit"] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// Number of consecutive download/verification failures before a label is marked broken for staging.
    /// Defaults to 3.
    var stageDownloadFailThreshold: Int {
        prefs["StageDownloadFailThreshold"] as? Int ?? 3
    }

    /// Number of consecutive install failures before a staged update is abandoned and that version
    /// is blocked from being re-staged. Staging resumes when a newer version becomes available.
    /// Defaults to 3.
    var applyFailThreshold: Int {
        prefs["ApplyFailThreshold"] as? Int ?? 3
    }

    // MARK: - Scan Delay Options
    
    /// When true, the scheduler waits a one-time random delay after first deployment
    /// before running its first scan. Spreads fleet-wide first-scan load across the
    /// initialScanDelayMaxSeconds window instead of all machines scanning simultaneously
    /// when a LaunchDaemon is pushed. Defaults to true.
    var initialScanDelayEnabled: Bool {
        prefs["InitialScanDelayEnabled"] as? Bool ?? true
    }

    /// Maximum seconds for the one-time initial deployment delay.
    /// The actual delay is chosen randomly in [0, initialScanDelayMaxSeconds] on first
    /// launch and persisted — subsequent 10-minute wakes just check if it has elapsed.
    /// Defaults to 86400 (24 hours).
    var initialScanDelayMaxSeconds: Int {
        prefs["InitialScanDelayMaxSeconds"] as? Int ?? 86400
    }


    // MARK: - Scheduler: per-subcommand cycle preferences

    /// Days between full application scans. Scan rediscovers installed apps against
    /// all Installomator labels.
    /// Defaults to 30.
    var scanIntervalDays: Int {
        prefs["ScanIntervalDays"] as? Int ?? 30
    }

    /// When true, a scan is triggered immediately if the Installomator labels have
    /// been updated since the last scan (regardless of ScanIntervalDays).
    /// Defaults to true.
    var scanOnLabelUpdate: Bool {
        prefs["ScanOnLabelUpdate"] as? Bool ?? true
    }

    /// Hours between light scan runs. Light scan checks uninstalled labels for apps
    /// installed by other means, without re-running label scripts or hitting the network
    /// for non-installed labels. Defaults to 24.
    var lightScanIntervalHours: Int {
        prefs["LightScanIntervalHours"] as? Int ?? 24
    }

    /// Hours between check runs. Check is fast (~60–90s) and reads installed versions
    /// for already-discovered apps.
    /// Defaults to 12.
    var checkIntervalHours: Int {
        prefs["CheckIntervalHours"] as? Int ?? 12
    }

    /// Hours between stage runs. Stage downloads pending updates.
    /// Defaults to 12.
    var stageIntervalHours: Int {
        prefs["StageIntervalHours"] as? Int ?? 12
    }

    /// Minimum hours between apply runs when using deadline-based patching.
    /// Prevents apply from running every 10-minute cycle once updates are pending.
    /// Defaults to 4. (Not used in monthly mode — the patch-day window controls timing.)
    var applyIntervalHours: Int {
        prefs["ApplyIntervalHours"] as? Int ?? 4
    }

    // MARK: - Scheduler: apply schedule keys

    /// When true, patching is restricted to the configured weekday/week-of-month window.
    /// When false, deadline-based patching is used instead.
    /// Defaults to false.
    var monthlyPatchingCadenceEnabled: Bool {
        prefs["MonthlyPatchingCadenceEnabled"] as? Bool ?? false
    }

    /// Day of the week for monthly patching. 1 = Sunday … 7 = Saturday.
    /// Defaults to 3 (Tuesday).
    var patchingWeekday: Int {
        prefs["PatchingWeekday"] as? Int ?? 3
    }

    /// Which occurrence of the weekday in the month. 1 = first, 2 = second, etc.
    /// Defaults to 2.
    var patchingWeekOfMonth: Int {
        prefs["PatchingWeekOfMonth"] as? Int ?? 2
    }

    /// Earliest time of day to begin patching, in "HH:MM" 24-hour format. Empty means no restriction.
    var patchingStartTime: String {
        pref("PatchingStartTime", default: "")
    }

    /// Latest time of day to attempt patching, in "HH:MM" 24-hour format. Empty means no restriction.
    /// Defaults to 17:00 (5:00 PM)
    var patchingEndTime: String {
        pref("PatchingEndTime", default: "17:00")
    }

    /// Number of days a pending update must be present before Focus / DND is ignored.
    /// 0 means Focus is always respected. Defaults to 4.
    var deadlineDaysFocus: Int {
        prefs["DeadlineDaysFocus"] as? Int ?? 4
    }

    /// Number of days a pending update must be present before no further deferrals are allowed.
    /// 0 means no hard deadline. Defaults to 10.
    var deadlineDaysHard: Int {
        prefs["DeadlineDaysHard"] as? Int ?? 10
    }

    /// When false, Focus / DND and display assertions are never checked. Defaults to true.
    var focusCheckEnabled: Bool {
        prefs["FocusCheckEnabled"] as? Bool ?? true
    }

    /// Space-separated list of process names to ignore when checking for display-sleep
    /// assertions (`pmset -g assertions`). If the process holding the assertion resolves
    /// to a name that matches an entry here (case-insensitive), the assertion is not
    /// treated as a blocker and patching may proceed.
    /// Useful for music/media apps (e.g. Spotify, Deezer, Music) that hold a display
    /// assertion during playback but shouldn't defer patching.
    /// Example: "Spotify Deezer Music"
    var focusIgnoredProcesses: [String] {
        guard let value = prefs["FocusIgnoredProcesses"] as? String else { return [] }
        return value.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - Aggressive patch-day deferral

    /// When true, deferral options are progressively capped on patch day (monthly mode)
    /// or hard deadline day (deadline mode) based on how much time remains in the
    /// patching window. Caps shrink from 2 h early in the day to 5 min near window end,
    /// then no deferral is offered after the window closes.
    /// When false, the full DeferralTimerMenu list is always used. Defaults to true.
    var aggressivePatchDayDeferral: Bool {
        prefs["AggressivePatchDayDeferral"] as? Bool ?? true
    }

    // MARK: - Branding Color Palette
    
    /// Font color.
    /// Can be a standard Apple color: black, blue, gray, green, orange, pink, purple, red, white, yellow.
    /// or
    /// Specified in hex format, e.g. #00A4C7
    var brandColorFont: String {
        pref("BrandColorFont", default: "white")
    }

    /// Background color.
    /// Can be a standard Apple color: black, blue, gray, green, orange, pink, purple, red, white, yellow.
    /// or
    /// Specified in hex format, e.g. #00A4C7
    var brandColorBackground: String {
        pref("BrandColorBackground", default: "blue")
    }

    // MARK: - swiftDialog UI

    /// When true, the scheduler runs a silent apply pass before the interactive apply phase.
    /// Items whose blocking process is not running are installed without prompting the user.
    /// Skipped items are not counted as deferrals. Defaults to false.
    var quietApplyEnabled: Bool {
        prefs["QuietApplyEnabled"] as? Bool ?? false
    }

    /// When true, swiftDialog is used to show apply progress and handle blocking processes.
    /// Automatically disabled if swiftDialog is not installed. Defaults to true.
    var swiftDialogEnabled: Bool {
        prefs["SwiftDialogEnabled"] as? Bool ?? true
    }

    /// Title shown in the swiftDialog apply window.
    /// Defaults to "Third Party Patcher" when the key is absent.
    var appTitle: String {
        pref("AppTitle", default: "Third Party Patcher")
    }

    /// When true, swiftDialog will stay on top of all other windows.
    /// Defaults to true.
    var dialogOnTop: Bool {
        prefs["DialogOnTop"] as? Bool ?? true
    }

    /// Swift Dialog icon..
    var dialogIcon: String {
        pref("DialogIcon", default: "")
    }

    /// When true, swiftDialog will apply an Overlay Icon to the dialog.
    /// Automatically disabled if swiftDialog is not installed.
    /// Defaults to true.
    var useOverlayIcon: Bool {
        prefs["UseOverlayIcon"] as? Bool ?? true
    }

    /// Swift Dialog Overlay icon.
    /// Defaults to "".
    var overlayIcon: String {
        pref("OverlayIcon", default: "")
    }

    /// Swift Dialog screen postion
    /// Defaults to center
    /// topleft | left | bottomleft | top | center/centre | bottom | topright | right | bottomright
    var dialogScreenPosition: String {
        pref("DialogScreenPosition", default: "center")
    }

    /// Swift Dialog progress window screen postion
    /// Defaults to bottomright
    /// topleft | left | bottomleft | top | center/centre | bottom | topright | right | bottomright
    var dialogScreenProgressPosition: String {
        pref("DialogScreenProgressPosition", default: "bottomright")
    }
    
    /// Deterines if swift dialog should automatically close after completion
    /// if there is no response from the end-user.
    /// Defaults to true.
    var unattendedExit: Bool {
        prefs["UnattendedExit"] as? Bool ?? true
    }

    /// The number of seconds the swift dialog will automatically close
    /// if UnattendedExit is set to TRUE
    /// Defaults to 60.
    var unattendedExitSeconds: Int {
        prefs["UnattendedExitSeconds"] as? Int ?? 60
    }
    
    // MARK: - swiftDialog blocking process UI

    /// Action taken when a blocking process is running during apply.
    /// Options: ignore | kill | notify | prompt | defer
    ///   ignore — skip blocking process check entirely
    ///   kill   — force-quit the blocking process silently
    ///   notify — show a brief swiftDialog notification; skip label if still running
    ///   prompt — show a timed swiftDialog prompt; user can quit app or skip label
    ///   defer  — skip this label silently; retry on next apply cycle
    /// Defaults to "prompt".
    var blockingProcessAction: String {
        pref("BlockingProcessAction", default: "prompt")
    }

    /// Seconds shown on the swiftDialog countdown timer for the blocking-process prompt.
    /// When the timer expires, the blocking process is force-quit and patching proceeds.
    /// Defaults to 120 (2 minutes).
    var blockingProcessCountdownSeconds: Int {
        prefs["BlockingProcessCountdownSeconds"] as? Int ?? 120
    }

    // MARK: - swiftDialog deferral process UI
    
    /// The number of seconds to show defer until automatic action is taken
    /// Using this option overrides the default deferral countdown seconds.
    /// Defaults to 300 seconds (5 minutes)
    var deferralCountdownSeconds: Int {
        prefs["DeferralCountdownSeconds"] as? Int ?? 300
    }

    /// Deferral action to automatically take when the "DeferralCountdownSeconds" reaches 0 and the dialog is not acknowledged
    /// Options: ignore | kill | defer
    ///   ignore — skip blocking process check entirely
    ///   kill   — force-quit the blocking process silently
    ///   defer  — skip this label silently; retry on next apply cycle
    /// Defaults to "defer".
    var deferralAutomaticAction: String {
        pref("DeferralAutomaticAction", default: "defer")
    }

    /// The number of minutes to defer until the next update workflow attempt if a user chooses not to install updates
    ///  Using this option overrides the default deferral time which is set to 120 minutes (2 hours)
    var deferralTimerDefault: Int {
        prefs["DeferralTimerDefault"] as? Int ?? 120
    }

    /// Display a deferral time pop-up menu in the install update dialog that allows the user to override the 'DeferralTimerDefault' timer.
    /// If you override this with your own values, make sure the value set for `deferralTimerDefault` is included in this list
    var deferralTimerMenu: String {
        pref("DeferralTimerMenu", default: "5,30,60,120,240,480,1440")
    }

    /// The number of minutes to defer automatically if the user has enabled Focus/Do Not Disturb
    /// or when a process has requested that the display not go to sleep (for example, during an active meeting).
    /// Defaults to 60 (1 hours).
    var deferralTimerFocus: Int {
        prefs["DeferralTimerFocus"] as? Int ?? 60
    }

    // MARK: - Support info UI
    
    /// For the Support Team name that display in the Help Message.
    /// Defaults to "IT Support Team".
    var supportTeamName: String {
        pref("SupportTeamName", default: "IT Support Team")
    }

    /// For the Support Team email address that display in the Help Message.
    /// Defaults to "support@company.com".
    var supportTeamEmail: String {
        pref("SupportTeamEmail", default: "support@company.com")
    }

    /// For the Support Team phone number that display in the Help Message.
    /// Defaults to "None".
    var supportTeamPhone: String {
        pref("SupportTeamPhone", default: "None")
    }

    /// For the Support Team wesite that display in the Help Message.
    /// Defaults to "None".
    var supportTeamWebsite: String {
        pref("SupportTeamWebsite", default: "None")
    }
    
    // MARK: - PatcherMenu UI

    /// Icon displayed in the menu bar status item.
    /// Accepts an SF Symbol name (e.g. "gear") or an absolute path to a PNG file
    /// (starting with / or ~). A template-mode PNG (black art on transparent background)
    /// adapts automatically to the light/dark menu bar appearance.
    /// When empty, the built-in default symbol is used. Defaults to "".
    var menuBarIcon: String {
        pref("MenuBarIcon", default: "")
    }

    /// When true, patcherscheduler installs and loads the PatcherMenu LaunchAgent
    /// for the current console user. When false, the LaunchAgent is unloaded and
    /// the plist removed. Managed automatically by patcherscheduler at each run.
    /// Defaults to false (opt-in).
    var showMenuBarApp: Bool {
        prefs["ShowMenuBarApp"] as? Bool ?? false
    }

    /// When true, the Last Activity section (scan / check / stage / apply dates)
    /// is shown in the menu bar popover. Defaults to true.
    var showActivitySection: Bool {
        prefs["ShowActivitySection"] as? Bool ?? true
    }

    /// When true, a Quit button is shown in the menu bar popover footer.
    /// Defaults to false.
    var showQuitButton: Bool {
        prefs["ShowQuitButton"] as? Bool ?? false
    }

    // MARK: - Available Software UI

    /// Absolute path to a PNG or ICNS file used as the Available Software app icon,
    /// overriding the built-in icon in the Dock, Finder, and app switcher.
    /// Leave empty to use the default built-in icon. Defaults to "".
    var customAppIconPath: String? {
        guard let value = prefs["CustomAppIconPath"] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// Company or organization name shown in the Available Software app sidebar.
    /// Defaults to "Patcher Corp.".
    var companyName: String {
        pref("CompanyName", default: "Patcher Corp.")
    }

    /// When true, apps installed via self-service installs are automatically added
    /// to the current user's Dock if not already present. Defaults to true.
    var addToDockOnSelfServiceInstall: Bool {
        prefs["AddToDockOnSelfServiceInstall"] as? Bool ?? true
    }

    // MARK: - Available Software & PatherMenu UI

    /// When true, a Help (?) button is shown in the menu bar popover header.
    /// Tapping it displays support contact information. Defaults to true.
    var showHelpButton: Bool {
        prefs["ShowHelpButton"] as? Bool ?? true
    }

    /// When true, the "Download new Updates" option is shown in the Run Now menu.
    /// Defaults to true.
    var showMenuDownloadAction: Bool {
        prefs["ShowMenuDownloadAction"] as? Bool ?? true
    }

    /// When true, the "Check for Updates" option is shown in the Run Now menu.
    /// Defaults to true.
    var showMenuCheckAction: Bool {
        prefs["ShowMenuCheckAction"] as? Bool ?? true
    }

    /// When true, the "Full Discovery Scan" option is shown in the Run Now menu.
    /// Defaults to true.
    var showMenuScanAction: Bool {
        prefs["ShowMenuScanAction"] as? Bool ?? true
    }

    /// When true, patcherscheduler passes --user-initiated to patcher for XPC-triggered scan/check,
    /// causing a swiftDialog progress window to appear. Defaults to true.
    var showScanCheckProgressDialog: Bool {
        prefs["ShowScanCheckProgressDialog"] as? Bool ?? true
    }

    // MARK: - Webhooks
    
    /// Determines if Webhooks are sent when patching is completed.
    /// Options include:
    /// FALSE = don't send anything
    /// FALURES = Notify on failures only
    /// ALL = Notify on success and failure
    ///
    /// Defaults to "FALSE".
    var webhookFeature: String {
        pref("WebhookFeature", default: "FALSE")
    }

    /// The Microsoft Teams Webhook URL to use if WebhookFeature is set to TRUE.
    /// Defaults to "".
    var webhookURLTeams: String {
        pref("WebhookURLTeams", default: "")
    }

    /// The Slack Webhook URL to use if WebhookFeature is set to TRUE.
    /// Defaults to "".
    var webhookURLSlack: String {
        pref("WebhookURLSlack", default: "")
    }

    /// Comma-separated list of device attributes to include in webhook notifications,
    /// in the order they should appear. MDM info is always appended if detected.
    /// Supported keys: deviceName, hostname, serial, osVersion, osBuild, osName,
    ///                  model, hardwareModel, user, patcherVersion, installomatorVersion
    /// Defaults to "deviceName,serial,osVersion,user".
    var webhookAttributes: [String] {
        pref("WebhookAttributes", default: "deviceName,serial,osVersion,user")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// When to send the accumulated webhook report.
    /// Options: immediate, daily, weekly, monthly, patchDay
    /// Defaults to "immediate".
    var webhookSchedule: String {
        pref("WebhookSchedule", default: "immediate")
    }

    /// For weekly schedule: day of week to send (0=Sunday … 6=Saturday). Defaults to 1 (Monday).
    var webhookScheduleWeekday: Int {
        prefs["WebhookScheduleWeekday"] as? Int ?? 1
    }

    /// For monthly schedule: day of month to send (1–31). Defaults to 1.
    var webhookScheduleMonthDay: Int {
        prefs["WebhookScheduleMonthDay"] as? Int ?? 1
    }

    /// For daily, weekly, and monthly schedules: hour of day (0–23) at which to send. Defaults to 8.
    var webhookScheduleHour: Int {
        prefs["WebhookScheduleHour"] as? Int ?? 8
    }

    /// Minimum consecutive stage failures for a label before it appears in webhook notifications.
    /// Defaults to 2.
    var webhookStageFailureThreshold: Int {
        prefs["WebhookStageFailureThreshold"] as? Int ?? 2
    }

    /// Determines whether an immediate webhook notification is sent after a user-initiated
    /// install from the Available Software catalog (regardless of WebhookSchedule).
    /// Options:
    /// FALSE    — never send (default)
    /// FAILURES — send only when the install failed
    /// ALL      — send on success and failure
    /// Defaults to "FALSE".
    var webhookSelfServiceFeature: String {
        pref("WebhookSelfServiceFeature", default: "FALSE")
    }

    // MARK: - Log maintenance

    /// Number of days to retain log files in /Library/Logs/Patcher.
    /// Log files older than this are deleted during the cleanLogs run.
    /// Set to 0 to disable automatic log cleanup.
    /// Defaults to 90.
    var logRetentionDays: Int {
        prefs["LogRetentionDays"] as? Int ?? 90
    }

    // MARK: - Diagnostic

    /// Raw preference entries sorted alphabetically by key. For diagnostic display only.
    var rawEntries: [(key: String, value: Any)] {
        prefs.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { (key: $0.key, value: $0.value) }
    }

    // MARK: - Private helpers

    private func pref(_ key: String, default defaultValue: String) -> String {
        guard let value = prefs[key] as? String, !value.isEmpty else { return defaultValue }
        return value
    }
}
