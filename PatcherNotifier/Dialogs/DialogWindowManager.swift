//
//  DialogWindowManager.swift
//  PatcherNotifier
//
//  Keeps the open windows in step with the session files patcher writes. Called when
//  the queue folder changes, and once a second while any window is open (for auto-close
//  times and to notice a patcher that has exited mid-run).
//

import AppKit
import Foundation
import OSLog

final class DialogWindowManager {

    /// Sessions the user closed (Done, close button, quit key) or that auto-closed. Their
    /// files stay until patcher removes or the scheduler prunes them, so remember them
    /// across agent relaunches.
    private static let dismissedKey = "DismissedDialogSessionIDs"

    private var windows: [String: DialogWindow] = [:]
    private var dismissed: Set<String>
    /// Sessions whose `.displayed` acknowledgement has been sent by this agent process.
    private var acknowledged: Set<String> = []
    private var timer: Timer?

    var hasOpenWindows: Bool { !windows.isEmpty }

    init() {
        dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
    }

    func reconcile() {
        let uid      = getuid()
        // Typed text is worded here, in the user's language; an older patcher's English stays.
        let sessions = DialogSessionStore.activeSessions().filter { $0.consoleUID == uid }.map { $0.resolved() }
        let now      = Date()

        var live: [String: DialogSession] = [:]
        for session in sessions where !dismissed.contains(session.id) {
            if let closeAt = session.autoCloseAt, closeAt <= now {
                dismissed.insert(session.id)
                notifierLog.info("Dialog \(session.id, privacy: .public) auto-closed")
                continue
            }
            // A running session whose patcher has exited won't be updated or closed.
            if session.phase == .running, !Self.processExists(session.ownerPID) { continue }
            live[session.id] = session
        }

        for (id, window) in windows where live[id] == nil {
            window.close()
            windows[id] = nil
        }
        for session in live.values.sorted(by: { $0.created < $1.created }) {
            if let window = windows[session.id] {
                window.update(session)
            } else {
                let id = session.id
                let window = DialogWindow(session: session, onToggle: { checked in
                    SchedulerRelay.send(sessionID: id, response: .toggled,
                                        value: DialogSession.Checkbox.value(checked))
                }) { [weak self] action, value in
                    self?.handle(action, value: value, id: id)
                }
                windows[id] = window
                window.show()
                notifierLog.info("Dialog \(id, privacy: .public) opened (\(session.kind.rawValue, privacy: .public))")
                // patcher starts a prompt's countdown only once it knows the window is up.
                if session.awaitsResponse, acknowledged.insert(id).inserted {
                    SchedulerRelay.send(sessionID: id, response: .displayed)
                }
            }
        }

        // Forget dismissals whose files are gone so the set stays small.
        dismissed.formIntersection(sessions.map(\.id))
        acknowledged.formIntersection(sessions.map(\.id))
        UserDefaults.standard.set(Array(dismissed), forKey: Self.dismissedKey)
        updateTimer()
    }

    private func handle(_ action: DialogAction, value: String?, id: String) {
        guard let session = windows[id]?.session else { return }
        if session.awaitsResponse {
            switch action {
            case .primary:   SchedulerRelay.send(sessionID: id, response: .primary, value: value)
            case .secondary: SchedulerRelay.send(sessionID: id, response: .secondary, value: value)
            case .dismissed: SchedulerRelay.send(sessionID: id, response: .dismissed)
            }
            // Install keeps the apply window: patcher turns it into the progress window.
            if session.phase == .choosing, action == .primary { return }
        }
        userClosed(id)
    }

    private func userClosed(_ id: String) {
        notifierLog.info("Dialog \(id, privacy: .public) closed by the user")
        dismissed.insert(id)
        UserDefaults.standard.set(Array(dismissed), forKey: Self.dismissedKey)
        windows[id]?.close()
        windows[id] = nil
        updateTimer()
    }

    private func updateTimer() {
        if windows.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
        }
    }

    /// patcher runs as root, so signalling it fails with EPERM while it is alive.
    private static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
