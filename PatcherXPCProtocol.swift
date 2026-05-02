//
//  PatcherXPCProtocol.swift
//
//  Shared XPC protocol between patcherscheduler (server) and PatcherMenu (client).
//  Add to both targets via target membership in Xcode.
//

import Foundation

@objc protocol PatcherXPCProtocol {
    /// Trigger a scheduler phase immediately, bypassing normal cadence.
    /// - Parameters:
    ///   - phase: One of "scan", "check", "stage", "apply"
    ///   - reply: Called with (true, "queued") on success, or (false, reason) on failure.
    ///            Called before the phase runs — use the ViewModel refresh to observe results.
    func triggerPhase(_ phase: String, reply: @escaping (Bool, String) -> Void)

    /// Install a single Installomator label via `patcher ensure <label>`.
    /// - Parameters:
    ///   - label: A valid Installomator label name (e.g. "microsoftword")
    ///   - reply: Called with (true, "installing") immediately; watch activeLabel via the
    ///            active_phase.json directory watcher for live progress.
    func installLabel(_ label: String, reply: @escaping (Bool, String) -> Void)
}
