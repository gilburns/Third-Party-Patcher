//
//  PatcherXPCDelegate.swift
//  patcherscheduler
//
//  NSXPCListenerDelegate that accepts connections from PatcherMenu, Available Software,
//  and PatcherNotifier, and dispatches phase requests onto the shared serial work queue.
//
//  Only those apps may connect: each must carry its expected bundle identifier and be
//  signed by the same Apple team as this daemon. The daemon runs as root and can install
//  software and quit apps, so arbitrary local processes must not be able to drive it.
//

import AppKit
import Foundation
import Security

// MARK: - Listener delegate

final class PatcherXPCDelegate: NSObject, NSXPCListenerDelegate {

    private let workQueue: DispatchQueue

    init(workQueue: DispatchQueue) {
        self.workQueue = workQueue
    }

    private static let clientBundleIDs = [
        "com.gilburns.PatcherMenu",
        AppConstants.availableSoftwareBundleID,
        "com.gilburns.PatcherNotifier"
    ]

    /// Code-signing requirement a client must satisfy, or nil when this daemon has no
    /// team identifier (unsigned or ad-hoc build) — in which case every client is refused.
    private static let clientRequirement: String? = {
        guard let teamID = ownTeamIdentifier() else {
            Logger.log("⚠️ XPC: patcherscheduler has no signing team identifier — all XPC clients will be refused.")
            return nil
        }
        let identifiers = clientBundleIDs.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and (\(identifiers))"
    }()

    private static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any]
        else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Up-front check by pid so a rejected client is refused (and logged) immediately.
    /// pid lookups can race with pid reuse, so `setCodeSigningRequirement` below is what
    /// actually enforces the requirement on every message.
    private static func client(pid: pid_t, satisfies requirement: String) -> Bool {
        var code: SecCode?
        var secRequirement: SecRequirement?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &secRequirement) == errSecSuccess,
              let secRequirement
        else { return false }
        return SecCodeCheckValidity(code, [], secRequirement) == errSecSuccess
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let pid = newConnection.processIdentifier
        guard let requirement = Self.clientRequirement,
              Self.client(pid: pid, satisfies: requirement) else {
            Logger.log("⛔️ XPC: rejected connection from pid \(pid) — client does not satisfy the code-signing requirement.")
            return false
        }
        newConnection.setCodeSigningRequirement(requirement)
        newConnection.exportedInterface = NSXPCInterface(with: PatcherXPCProtocol.self)
        newConnection.exportedObject = PatcherXPCHandler(workQueue: workQueue)
        newConnection.invalidationHandler = {
            Logger.log("ℹ️ XPC: connection from pid \(pid) invalidated.")
        }
        newConnection.resume()
        Logger.log("ℹ️ XPC: accepted connection from pid \(pid).")
        return true
    }
}

// MARK: - Protocol handler

final class PatcherXPCHandler: NSObject, PatcherXPCProtocol {

    private let workQueue: DispatchQueue

    init(workQueue: DispatchQueue) {
        self.workQueue = workQueue
    }

    func triggerPhase(_ phase: String, reply: @escaping (Bool, String) -> Void) {
        let valid = ["scan", "check", "stage", "apply", "metadata"]
        guard valid.contains(phase) else {
            reply(false, "Unknown phase '\(phase)'. Valid: \(valid.joined(separator: ", "))")
            return
        }
        Logger.log("▶️ XPC: phase '\(phase)' requested — queuing on work queue.")
        reply(true, "Phase '\(phase)' queued.")
        workQueue.async {
            PatcherScheduler(prefs: Preferences()).runOnDemand(phase: phase)
        }
    }

    func installLabel(_ label: String, reply: @escaping (Bool, String) -> Void) {
        let safe = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty,
              safe.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }),
              !safe.contains("..")
        else {
            reply(false, "Invalid label name: '\(label)'")
            return
        }
        Logger.log("▶️ XPC: self-service install for label '\(safe)' requested.")
        reply(true, "Installing '\(safe)'.")
        workQueue.async {
            PatcherScheduler(prefs: Preferences()).ensureLabel(safe)
        }
    }

    func setAppIcon(iconPath: String?, bundlePath: String, reply: @escaping (Bool, String) -> Void) {
        guard bundlePath.hasSuffix(".app"),
              FileManager.default.fileExists(atPath: bundlePath)
        else {
            reply(false, "Invalid bundle path: '\(bundlePath)'")
            return
        }

        if let iconPath {
            guard let image = NSImage(contentsOfFile: iconPath) else {
                reply(false, "Could not load icon from: '\(iconPath)'")
                return
            }
            NSWorkspace.shared.setIcon(image, forFile: bundlePath, options: [])
            Logger.log("ℹ️ XPC: applied custom app icon '\(iconPath)' on '\(bundlePath)'.")
        } else {
            NSWorkspace.shared.setIcon(nil, forFile: bundlePath, options: [])
            Logger.log("ℹ️ XPC: cleared custom app icon from '\(bundlePath)'.")
        }
        reply(true, "ok")
    }

    func respondToNotification(_ eventID: String, action: String, reply: @escaping (Bool, String) -> Void) {
        guard let parsed = NotificationResponseAction(rawValue: action) else {
            reply(false, "Unknown action '\(action)'.")
            return
        }
        // Only accept responses for a prompt that is still queued (and so still being
        // waited on) — this also validates the id before it is used as a filename.
        guard let event = UserNotificationQueue.event(withID: eventID), event.kind == .blockingPrompt else {
            reply(false, "No pending prompt with id '\(eventID)'.")
            return
        }
        let recorded = UserNotificationQueue.writeResponse(
            PatcherNotificationResponse(eventID: event.id, action: parsed, date: Date())
        )
        Logger.log("🔔 XPC: notification response '\(parsed.rawValue)' for \(event.label ?? event.id)\(recorded ? "" : " — failed to record").")
        reply(recorded, recorded ? "recorded" : "Failed to record response.")
    }
}
