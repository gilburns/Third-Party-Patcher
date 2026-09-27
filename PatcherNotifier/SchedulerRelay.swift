//
//  SchedulerRelay.swift
//  PatcherNotifier
//
//  Sends a user's response to an actionable notification to patcherscheduler, which
//  records it for the patcher process waiting on that prompt.
//

import Foundation
import OSLog

enum SchedulerRelay {

    /// Calls `completion` once the daemon has replied, or the connection failed.
    static func send(eventID: String, action: NotificationResponseAction,
                                 completion: @escaping @Sendable () -> Void) {
        let conn = NSXPCConnection(machServiceName: AppConstants.patcherXPCServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: PatcherXPCProtocol.self)
        conn.resume()

        let proxy = conn.remoteObjectProxyWithErrorHandler { error in
            notifierLog.error("XPC error relaying response for \(eventID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            conn.invalidate()
            completion()
        } as? PatcherXPCProtocol

        guard let proxy else {
            conn.invalidate()
            completion()
            return
        }
        proxy.respondToNotification(eventID, action: action.rawValue) { ok, message in
            if ok {
                notifierLog.info("Relayed '\(action.rawValue, privacy: .public)' for \(eventID, privacy: .public)")
            } else {
                notifierLog.error("Scheduler rejected response for \(eventID, privacy: .public): \(message, privacy: .public)")
            }
            conn.invalidate()
            completion()
        }
    }
}
