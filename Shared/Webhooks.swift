//
//  Webhooks.swift
//  patcher
//
//  Sends patch-result notifications to Microsoft Teams (Adaptive Card) and
//  Slack (Block Kit). Shared across patcher, patcherscheduler, and patcherreporter.
//
//  WebhookFeature preference values:
//    FALSE     — webhooks disabled (default)
//    FAILURES  — send only when there are failed updates
//    ALL       — send on every run that produced results
//
//  WebhookAttributes preference (comma-separated, order preserved):
//    deviceName, hostname, serial, osVersion, osBuild, osName,
//    model, hardwareModel, user, patcherVersion, installomatorVersion
//  Default: "deviceName,serial,osVersion,user"
//  MDM info is always appended after the configured attributes when detected.
//
//  Passing forceTest: true bypasses the WebhookFeature gate and sends
//  regardless of the preference value (used by the `patcher testWebhook` command).
//

import Foundation

// MARK: - Public Types

enum WebhookFeatureLevel {
    case disabled, failuresOnly, all

    init(_ raw: String) {
        switch raw.uppercased() {
        case "FAILURES": self = .failuresOnly
        case "ALL":      self = .all
        default:         self = .disabled
        }
    }
}

struct WebhookDeviceInfo {
    // Identity
    let computerName: String        // Human name from System Settings → Sharing
    let hostname: String            // Network hostname
    let serialNumber: String
    let consoleUser: String
    // OS
    let osVersionFull: String       // e.g. "15.4.1 (24E263)"
    let osBuild: String             // e.g. "24E263"
    let osNameStr: String           // e.g. "Sequoia"
    // Hardware
    let marketingModelStr: String   // e.g. "MacBook Pro (14-inch, M3, 2023)"
    let hardwareModelStr: String    // e.g. "Mac14,5"
    // Software
    let patcherVersionStr: String
    let installomatorVersionStr: String
    // MDM
    let mdmName: String
    let mdmConsoleURL: String?      // nil when MDM is unrecognised
}

/// Resolves a WebhookAttributes key to a display (title, value) pair.
/// Returns nil for unrecognised keys so callers can use compactMap.
extension WebhookDeviceInfo {
    func attribute(for key: String) -> (title: String, value: String)? {
        switch key.trimmingCharacters(in: .whitespaces).lowercased() {
        case "devicename":
            return ("Device", computerName)
        case "hostname":
            return ("Hostname", hostname)
        case "serial":
            return ("Serial", serialNumber)
        case "osversion":
            return ("macOS", osVersionFull)
        case "osbuild":
            return ("Build", osBuild)
        case "osname":
            return ("macOS Name", osNameStr)
        case "model":
            return ("Model", marketingModelStr.isEmpty ? "Unknown" : marketingModelStr)
        case "hardwaremodel":
            return ("Hardware Model", hardwareModelStr)
        case "user":
            return ("User", consoleUser.isEmpty ? "—" : consoleUser)
        case "patcherversion":
            return ("Patcher", patcherVersionStr)
        case "installomatorversion":
            return ("Installomator", installomatorVersionStr)
        default:
            return nil
        }
    }
}

struct WebhookLabelResult {
    let label: String
    let displayName: String
    let fromVersion: String?
    let toVersion: String?
    let failureReason: String?  // nil = success
}

// MARK: - Device Info Collection

func collectWebhookDeviceInfo() -> WebhookDeviceInfo {
    let serial = deviceSerialNumber
    let (mdmName, mdmURL) = detectMDM(serialNumber: serial)
    let v = ProcessInfo.processInfo.operatingSystemVersion
    let vStr = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    let build = osBuildVersion
    return WebhookDeviceInfo(
        computerName:          Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
        hostname:              ProcessInfo.processInfo.hostName,
        serialNumber:          serial,
        consoleUser:           consoleUserInfo.username,
        osVersionFull:         "\(vStr) (\(build))",
        osBuild:               build,
        osNameStr:             ProcessInfo.processInfo.osName,
        marketingModelStr:     marketingModel,
        hardwareModelStr:      deviceHardwareModel,
        patcherVersionStr:     AppConstants.patcherVersion,
        installomatorVersionStr: installomatorVersion,
        mdmName:               mdmName,
        mdmConsoleURL:         mdmURL
    )
}

// MARK: - MDM Detection

private func detectMDM(serialNumber: String) -> (name: String, consoleURL: String?) {
    // Jamf Pro — plist is present on every Jamf-enrolled Mac
    if let jamfPrefs = NSDictionary(contentsOfFile: "/Library/Preferences/com.jamfsoftware.jamf.plist"),
       var jssURL = jamfPrefs["jss_url"] as? String {
        if jssURL.hasSuffix("/") { jssURL = String(jssURL.dropLast()) }
        let link = "\(jssURL)/computers.html?query=\(serialNumber)&queryType=COMPUTERS"
        return ("Jamf Pro", link)
    }

    // Microsoft Intune — identified by the MDM profile identifier
    let profilesOutput = webhookShell("/usr/bin/profiles", ["show"])
    if profilesOutput.contains("Microsoft.Profiles.MDM") {
        let deviceID = findIntuneDeviceID()
        if !deviceID.isEmpty {
            // %7E encodes ~ — Teams strips bare ~ from action URLs, breaking the path
            let link = "https://intune.microsoft.com/#view/Microsoft_Intune_Devices/DeviceSettingsMenuBlade/%7E/overview/mdmDeviceId/\(deviceID)"
            return ("Microsoft Intune", link)
        }
        return ("Microsoft Intune",
                "https://intune.microsoft.com/#view/Microsoft_Intune_DeviceSettings/DevicesMacOsMenu/%7E/macOsDevices")
    }

    return ("Unknown MDM", nil)
}

private func findIntuneDeviceID() -> String {
    let logDir = URL(fileURLWithPath: "/Library/Logs/Microsoft/Intune")
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: logDir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
    ) else { return "" }

    // Search newest logs first to get the most current device ID
    let sorted = files.sorted {
        let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return d1 > d2
    }

    for file in sorted {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
        for line in content.components(separatedBy: .newlines) where line.contains("DeviceId:") {
            let parts = line.components(separatedBy: "DeviceId:")
            guard parts.count > 1 else { continue }
            // Trim whitespace, take first space-delimited token, then strip any trailing
            // punctuation (log lines often have a trailing comma: "DeviceId: UUID,")
            let uuidChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
            let token = parts[1].trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces).first?
                .trimmingCharacters(in: uuidChars.inverted) ?? ""
            if !token.isEmpty { return token }
        }
    }
    return ""
}

private func webhookShell(_ executable: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    // nullDevice, not Pipe(): an unread stderr pipe can fill and block the child just as
    // stdout can, and nothing here ever reads it.
    p.standardError  = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    // Drain BEFORE waiting. readDataToEndOfFile() returns at EOF and keeps the pipe empty
    // while the child runs; waiting first deadlocks as soon as the child writes more than
    // the ~64 KiB pipe buffer, because it blocks in write() and can then never exit.
    // Hit in the wild by `profiles show` on an Intune-managed Mac (~75 KB of output).
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: - Main Entry Point

func sendWebhooks(
    device: WebhookDeviceInfo,
    successful: [WebhookLabelResult],
    failed: [WebhookLabelResult],
    prefs: Preferences,
    title: String = "🔧 Third Party Patcher — Patch Report",
    forceTest: Bool = false
) {
    let featureLevel = WebhookFeatureLevel(prefs.webhookFeature)

    // Gate: forceTest bypasses the feature-level check entirely.
    // Using switch/pattern-matching avoids an Equatable requirement on the enum.
    if !forceTest {
        switch featureLevel {
        case .disabled:                                        return
        case .failuresOnly where failed.isEmpty:               return
        case .all where successful.isEmpty && failed.isEmpty:  return
        default: break
        }
    }

    let teamsURL = prefs.webhookURLTeams
    let slackURL = prefs.webhookURLSlack

    guard !teamsURL.isEmpty || !slackURL.isEmpty else {
        Logger.log("⚠️ Webhook: no URL configured — nothing sent.")
        return
    }

    // Resolve the ordered attribute list once; both builders share it
    let attrs = prefs.webhookAttributes.compactMap { device.attribute(for: $0) }

    if !teamsURL.isEmpty,
       let data = buildTeamsPayload(device: device, attrs: attrs,
                                    successful: successful, failed: failed,
                                    title: title, isTest: forceTest) {
        Logger.log("📣 Sending Teams webhook…")
        postWebhook(url: teamsURL, jsonData: data)
    }

    if !slackURL.isEmpty,
       let data = buildSlackPayload(device: device, attrs: attrs,
                                    successful: successful, failed: failed,
                                    title: title, isTest: forceTest) {
        Logger.log("📣 Sending Slack webhook…")
        postWebhook(url: slackURL, jsonData: data)
    }
}

// MARK: - Self-Service Install Notifications

/// Sends an immediate webhook for a single user-initiated install from Available Software.
/// Controlled by WebhookSelfServiceFeature, independent of WebhookSchedule/WebhookFeature.
func sendSelfServiceWebhook(label: String, prefs: Preferences) {
    let featureLevel = WebhookFeatureLevel(prefs.webhookSelfServiceFeature)
    switch featureLevel {
    case .disabled: return
    default: break
    }

    let teamsURL = prefs.webhookURLTeams
    let slackURL = prefs.webhookURLSlack
    guard !teamsURL.isEmpty || !slackURL.isEmpty else {
        Logger.log("⚠️ Self-service webhook: no URL configured — nothing sent.")
        return
    }

    // Find the most recent apply result written by `patcher ensure` for this label
    let log = loadWebhookReportLog()
    let entry = log.applyResults.last(where: { $0.label == label })

    let isSuccess: Bool
    let result: WebhookLabelResult

    if let entry {
        isSuccess = entry.success
        result = WebhookLabelResult(
            label: entry.label,
            displayName: entry.displayName,
            fromVersion: entry.fromVersion,
            toVersion: entry.toVersion,
            failureReason: entry.success ? nil : (entry.reason ?? "Installation failed")
        )
    } else {
        // No apply result — install failed before apply was reached (scan or download phase)
        isSuccess = false
        result = WebhookLabelResult(
            label: label,
            displayName: label,
            fromVersion: nil,
            toVersion: nil,
            failureReason: "Install failed at scan or download phase"
        )
    }

    switch featureLevel {
    case .failuresOnly where isSuccess: return
    default: break
    }

    Logger.log("📣 Self-service webhook for '\(label)': \(isSuccess ? "success" : "failure")")

    let successful = isSuccess ? [result] : []
    let failed     = isSuccess ? []       : [result]
    let device     = collectWebhookDeviceInfo()
    let attrs      = prefs.webhookAttributes.compactMap { device.attribute(for: $0) }
    let title      = "🔧 Third Party Patcher — User-Initiated Install"

    if !teamsURL.isEmpty,
       let data = buildTeamsPayload(device: device, attrs: attrs,
                                    successful: successful, failed: failed,
                                    title: title, isTest: false) {
        postWebhook(url: teamsURL, jsonData: data)
    }

    if !slackURL.isEmpty,
       let data = buildSlackPayload(device: device, attrs: attrs,
                                    successful: successful, failed: failed,
                                    title: title, isTest: false) {
        postWebhook(url: slackURL, jsonData: data)
    }
}

// MARK: - HTTP

/// Posts JSON to a webhook URL, retrying up to `maxAttempts` times with `retryDelay` seconds
/// between attempts. Returns true if any attempt succeeded.
@discardableResult
private func postWebhook(url urlString: String, jsonData: Data,
                         maxAttempts: Int = 3, retryDelay: TimeInterval = 10) -> Bool {
    guard let url = URL(string: urlString) else {
        Logger.log("❌ Webhook: invalid URL")
        return false
    }

    var request = URLRequest(url: url, timeoutInterval: 30)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = jsonData

    for attempt in 1...maxAttempts {
        if attempt > 1 {
            Logger.log("⏳ Webhook: waiting \(Int(retryDelay))s before retry \(attempt)/\(maxAttempts)…")
            Thread.sleep(forTimeInterval: retryDelay)
        }

        var succeeded = false
        var failureNote = ""
        let sema = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { _, response, error in
            defer { sema.signal() }
            if let error {
                failureNote = error.localizedDescription
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                failureNote = "HTTP \(http.statusCode)"
            } else {
                succeeded = true
            }
        }.resume()
        sema.wait()

        if succeeded {
            Logger.log("✅ Webhook delivered\(attempt > 1 ? " (attempt \(attempt)/\(maxAttempts))" : "").")
            return true
        }
        Logger.log("⚠️ Webhook attempt \(attempt)/\(maxAttempts) failed: \(failureNote)")
    }

    Logger.log("❌ Webhook: all \(maxAttempts) attempts failed — giving up.")
    return false
}

// MARK: - Teams Adaptive Card

private func buildTeamsPayload(
    device: WebhookDeviceInfo,
    attrs: [(title: String, value: String)],
    successful: [WebhookLabelResult],
    failed: [WebhookLabelResult],
    title: String,
    isTest: Bool
) -> Data? {
    var body: [[String: Any]] = []

    if isTest {
        body.append([
            "type": "Container",
            "style": "warning",
            "items": [[
                "type": "TextBlock",
                "text": "⚠️  TEST MESSAGE — Webhook Connectivity Test",
                "weight": "Bolder",
                "wrap": true,
            ]]
        ])
    }

    body.append([
        "type": "TextBlock",
        "text": title,
        "size": "Large",
        "weight": "Bolder",
        "wrap": true,
        "separator": isTest,
    ])

    // Configured attributes as FactSet facts, MDM always appended if detected
    var facts = attrs.map { ["title": $0.title, "value": $0.value] }
    facts.append(["title": "MDM", "value": device.mdmName])
    body.append([
        "type": "FactSet",
        "separator": true,
        "facts": facts,
    ])

    // MDM console link as a tappable action button (more reliable than markdown in FactSet)
    if let mdmURL = device.mdmConsoleURL, !mdmURL.isEmpty {
        body.append([
            "type": "ActionSet",
            "actions": [[
                "type": "Action.OpenUrl",
                "title": "View Device in \(device.mdmName)",
                "url": mdmURL,
            ]]
        ])
    }

    // Success section
    if !successful.isEmpty {
        let lines = successful.map {
            "• \($0.displayName): \($0.fromVersion.map { "v\($0)" } ?? "?") → \($0.toVersion.map { "v\($0)" } ?? "?")"
        }.joined(separator: "\n")

        body.append([
            "type": "Container",
            "style": "good",
            "separator": true,
            "items": [
                ["type": "TextBlock", "text": "✅  Applied Successfully (\(successful.count))",
                 "weight": "Bolder", "color": "Good"],
                ["type": "TextBlock", "text": lines, "wrap": true],
            ] as [[String: Any]]
        ])
    }

    // Failure section
    if !failed.isEmpty {
        let lines = failed.map {
            "• \($0.displayName): \($0.failureReason ?? "Unknown error")"
        }.joined(separator: "\n")

        body.append([
            "type": "Container",
            "style": "attention",
            "separator": !successful.isEmpty,
            "items": [
                ["type": "TextBlock", "text": "❌  Failed (\(failed.count))",
                 "weight": "Bolder", "color": "Attention"],
                ["type": "TextBlock", "text": lines, "wrap": true, "color": "Attention"],
            ] as [[String: Any]]
        ])
    }

    body.append([
        "type": "TextBlock",
        "text": "Sent: \(ISO8601DateFormatter().string(from: Date()))",
        "size": "Small",
        "isSubtle": true,
        "separator": true,
    ])

    let card: [String: Any] = [
        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        "type": "AdaptiveCard",
        "version": "1.4",
        "body": body,
    ]

    let payload: [String: Any] = [
        "type": "message",
        "attachments": [[
            "contentType": "application/vnd.microsoft.card.adaptive",
            "contentUrl": NSNull(),
            "content": card,
        ]]
    ]

    return try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
}

// MARK: - Slack Block Kit

private func buildSlackPayload(
    device: WebhookDeviceInfo,
    attrs: [(title: String, value: String)],
    successful: [WebhookLabelResult],
    failed: [WebhookLabelResult],
    title: String,
    isTest: Bool
) -> Data? {
    var blocks: [[String: Any]] = []

    if isTest {
        blocks.append([
            "type": "header",
            "text": ["type": "plain_text", "text": "⚠️ TEST MESSAGE — Webhook Connectivity Test", "emoji": true]
        ])
    }

    blocks.append([
        "type": "header",
        "text": ["type": "plain_text", "text": title, "emoji": true]
    ])

    // Build fields from ordered attrs; MDM always appended if detected.
    // Slack sections cap at 10 fields, so we chunk into multiple sections if needed.
    var mdmField = "*MDM:*\n\(device.mdmName)"
    if let url = device.mdmConsoleURL, !url.isEmpty {
        mdmField = "*MDM:*\n<\(url)|\(device.mdmName)>"
    }

    var allFields: [[String: Any]] = attrs.map {
        ["type": "mrkdwn", "text": "*\($0.title):*\n\($0.value)"]
    }
    allFields.append(["type": "mrkdwn", "text": mdmField])

    // Emit in chunks of 10 (Slack section field limit)
    for chunk in stride(from: 0, to: allFields.count, by: 10) {
        let slice = Array(allFields[chunk..<min(chunk + 10, allFields.count)])
        blocks.append(["type": "section", "fields": slice])
    }

    blocks.append(["type": "divider"])

    if !successful.isEmpty {
        let lines = successful.map {
            "• *\($0.displayName)*: \($0.fromVersion ?? "?") → \($0.toVersion ?? "?")"
        }.joined(separator: "\n")
        blocks.append([
            "type": "section",
            "text": ["type": "mrkdwn",
                     "text": "*✅ Applied Successfully (\(successful.count))*\n\(lines)"]
        ])
    }

    if !failed.isEmpty {
        let lines = failed.map {
            "• *\($0.displayName)*: \($0.failureReason ?? "Unknown error")"
        }.joined(separator: "\n")
        blocks.append([
            "type": "section",
            "text": ["type": "mrkdwn",
                     "text": "*❌ Failed (\(failed.count))*\n\(lines)"]
        ])
    }

    blocks.append(["type": "divider"])

    blocks.append([
        "type": "context",
        "elements": [["type": "mrkdwn",
                      "text": "Sent: \(ISO8601DateFormatter().string(from: Date()))"]]
    ])

    return try? JSONSerialization.data(withJSONObject: ["blocks": blocks],
                                       options: [.prettyPrinted, .sortedKeys])
}

// MARK: - Webhook Report Log

/// Accumulates stage failures and apply results between scheduled notification sends.
/// Persisted to webhookReportLogURL; cleared after each sendReport run.
struct WebhookReportLog: Codable {

    struct StageFailureEntry: Codable {
        let date: String
        let label: String
        let displayName: String
        let reason: String
        let consecutiveFailures: Int
    }

    struct ApplyResultEntry: Codable {
        let date: String
        let label: String
        let displayName: String
        let fromVersion: String?
        let toVersion: String?
        let success: Bool
        let reason: String?
    }

    var logVersion: Int = 1
    var periodStart: String
    var lastUpdated: String
    var stageFailures: [StageFailureEntry] = []
    var applyResults:  [ApplyResultEntry]  = []

    var isEmpty: Bool { stageFailures.isEmpty && applyResults.isEmpty }

    static func empty() -> WebhookReportLog {
        let now = ISO8601DateFormatter().string(from: Date())
        return WebhookReportLog(periodStart: now, lastUpdated: now)
    }
}

func loadWebhookReportLog() -> WebhookReportLog {
    guard let data = try? Data(contentsOf: AppConstants.webhookReportLogURL) else { return .empty() }
    let decoder = JSONDecoder()
    return (try? decoder.decode(WebhookReportLog.self, from: data)) ?? .empty()
}

private func saveWebhookReportLog(_ log: WebhookReportLog) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(log) else { return }
    try? data.write(to: AppConstants.webhookReportLogURL, options: .atomic)
}

func clearWebhookReportLog() {
    try? FileManager.default.removeItem(at: AppConstants.webhookReportLogURL)
    Logger.log("🗑️ Webhook report log cleared.")
}

/// Appends (or updates) a stage failure entry. Only called when consecutiveFailures >= threshold.
func appendWebhookStageFailure(label: String, displayName: String, reason: String, consecutiveFailures: Int) {
    var log = loadWebhookReportLog()
    let entry = WebhookReportLog.StageFailureEntry(
        date: ISO8601DateFormatter().string(from: Date()),
        label: label, displayName: displayName,
        reason: reason, consecutiveFailures: consecutiveFailures
    )
    // Replace existing entry for this label (keeps the most recent failure info)
    if let idx = log.stageFailures.firstIndex(where: { $0.label == label }) {
        log.stageFailures[idx] = entry
    } else {
        log.stageFailures.append(entry)
    }
    log.lastUpdated = ISO8601DateFormatter().string(from: Date())
    saveWebhookReportLog(log)
}

func appendWebhookApplyResult(label: String, displayName: String,
                               fromVersion: String?, toVersion: String?,
                               success: Bool, reason: String? = nil) {
    var log = loadWebhookReportLog()
    log.applyResults.append(WebhookReportLog.ApplyResultEntry(
        date: ISO8601DateFormatter().string(from: Date()),
        label: label, displayName: displayName,
        fromVersion: fromVersion, toVersion: toVersion,
        success: success, reason: reason
    ))
    log.lastUpdated = ISO8601DateFormatter().string(from: Date())
    saveWebhookReportLog(log)
}
